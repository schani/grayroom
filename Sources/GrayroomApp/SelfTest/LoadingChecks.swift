import AppKit
import GrayroomCore
import GrayroomLibrary
import GrayroomUI

extension SelfTest {
    @MainActor
    static func runLoadingChecks() async {
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) {
            log("loading self-test: \(ok ? "PASS" : "FAIL") — \(message)")
            if !ok { failures.append(message) }
        }
        do {
            let source = outputDirectory.appendingPathComponent("loading-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let a = source.appendingPathComponent("a.png")
            let b = source.appendingPathComponent("b.png")
            let bad = source.appendingPathComponent("bad.png")
            let pixels = FloatImage(width: 32, height: 32,
                                    pixels: Array(repeating: 0.4, count: 32 * 32 * 4))
            try ImageWriter.write(image: pixels, to: a, format: .png)
            try ImageWriter.write(image: FloatImage(width: 16, height: 16,
                                                    pixels: Array(repeating: 0.7, count: 16 * 16 * 4)),
                                  to: b, format: .png)
            try Data("not an image".utf8).write(to: bad)
            let library = try Library.openDefault()
            defer { try? library.close() }
            let importer = Importer(library: library)
            let aID = try importer.importFile(at: a).photoID
            let bID = try importer.importFile(at: b).photoID
            let badID = try Importer(library: library, probe: { _ in PhotoMetadata() })
                .importFile(at: bad).photoID
            var edit = EditState()
            edit.tone.exposure = 1
            let development = try library.addDevelopment(photoID: aID, edit: edit)
            guard let developmentID = development.id else { fail("missing development id") }

            let app = AppModel.shared
            app.openChosenFile(a)
            await waitForLoading { app.store.edit.tone.exposure == 1 && !app.isDecoding && !app.isRendering }
            check(app.store.edit.tone.exposure == 1, "loaded the stored edit")
            app.store.perform("Exposure") { $0.tone.exposure = 2 }
            app.open(url: b, knownPhotoID: bID)
            await waitForLoading { app.imageURL == b && !app.isDecoding && !app.isRendering }
            check(try library.development(id: developmentID)?.edit.tone.exposure == 2,
                  "switching photos flushes the pending autosave")
            check(try library.developments(for: bID).isEmpty, "switching does not save the outgoing edit to B")

            for knownID in [aID, nil] as [Int64?] {
                app.open(url: a, knownPhotoID: knownID)
                app.store.perform("Exposure") { $0.tone.exposure = 3 }
                app.open(url: b, knownPhotoID: bID)
                await waitForLoading { app.imageURL == b && !app.isDecoding && !app.isRendering }
                let stored = try library.developments(for: aID)
                check(stored.count == 1 && stored.first?.edit.tone.exposure == 3,
                      "switching during lookup saves to the existing development (known id: \(knownID != nil))")
                check(app.imageURL == b, "the requested photo opens after saving")
                _ = try library.updateDevelopment(id: developmentID, edit: edit)
            }

            app.open(url: bad, knownPhotoID: badID)
            app.open(url: b, knownPhotoID: bID)
            await waitForLoading { !app.isDecoding && !app.isRendering }
            check(app.imageURL == b && app.previewSize == CGSize(width: 16, height: 16)
                    && app.errorMessage == nil,
                  "an old decode failure cannot cancel the next photo")

            app.open(url: bad, knownPhotoID: badID)
            await waitForLoading { !app.isDecoding && !app.isRendering }
            check(app.errorMessage != nil, "a current decode failure leaves the render loop idle")
            app.open(url: b, knownPhotoID: bID)
            await waitForLoading { app.previewSize == CGSize(width: 16, height: 16) && !app.isDecoding && !app.isRendering }
            let canvas = app.makeCanvas()
            guard let initialTexture = canvas.imageTexture else { fail("missing initial render") }
            let initialLuminance = try TextureReadback.read(initialTexture).meanLuminance
            app.store.perform("Exposure") { $0.tone.exposure = 1 }
            check(app.isRendering && !app.isDecoding, "tone changes render without decoding")
            app.store.perform("Exposure") { $0.tone.exposure = -2 }
            app.store.perform("Exposure") { $0.tone.exposure = 2 }
            await waitForLoading { !app.isDecoding && !app.isRendering }
            check(try TextureReadback.read(canvas.imageTexture!).meanLuminance > initialLuminance,
                  "queued edits finish on the newest exposure")
            app.store.perform("White Balance") { $0.whiteBalance.temperature = 9000 }
            check(app.isDecoding && !app.isRendering, "white balance starts a decode")
            await waitForLoading { !app.isDecoding && !app.isRendering }
            let finished = try TextureReadback.read(canvas.imageTexture!).pixels
            app.requestRender()
            check(app.isRendering && !app.isDecoding, "an unchanged edit reuses the decode")
            await waitForLoading { !app.isDecoding && !app.isRendering }
            check(try TextureReadback.read(canvas.imageTexture!).pixels == finished,
                  "re-rendering the same edit preserves the pixels")

            let catalog = PhotoCatalog()
            try catalog.load(from: library)
            guard let stalePhoto = catalog.photo(id: aID) else { fail("missing catalog photo") }
            edit.tone.exposure = 4
            _ = try library.updateDevelopment(id: developmentID, edit: edit)
            let builder = PreviewBuilder()
            builder.library = library
            builder.previews = try PreviewStore.open(for: library)
            let image = try ImageWriter.makeCGImage(pixels, bitsPerComponent: 8)
            var renderCount = 0
            var delivered = 0
            builder.render = { _, _, done in
                renderCount += 1
                if renderCount <= 4 { done(image) }
            }
            builder.image(for: stalePhoto) { result in
                if result != nil { delivered += 1 }
            }
            await waitForLoading { delivered > 0 || renderCount > 4 }
            check(renderCount == 1 && delivered == 1,
                  "a stale catalog request finishes once (renders: \(renderCount), deliveries: \(delivered))")
            check(try builder.previews?.preview(for: stalePhoto.hash)?.fingerprint == edit.fingerprint,
                  "the stored preview identifies the edit actually rendered")
            check(builder.tasks.tasks.isEmpty, "the completed preview leaves no running task")

            let coalescing = PreviewBuilder()
            coalescing.library = library
            var completions: [(CGImage?) -> Void] = []
            var renderedEdits: [EditState] = []
            var newest = stalePhoto
            newest.developmentFingerprint = edit.fingerprint
            var latestDeliveries = 0
            coalescing.render = { _, edit, done in
                renderedEdits.append(edit)
                completions.append(done)
            }
            coalescing.image(for: newest) { _ in latestDeliveries += 1 }
            await waitForLoading { completions.count == 1 }
            edit.tone.exposure = -1
            _ = try library.updateDevelopment(id: developmentID, edit: edit)
            newest.developmentFingerprint = edit.fingerprint
            coalescing.image(for: newest) { _ in latestDeliveries += 1 }
            completions.first?(image)
            await waitForLoading { completions.count == 2 }
            check(latestDeliveries == 0, "a newer request prevents delivery of the old render")
            if completions.count == 2 { completions[1](image) }
            await waitForLoading { latestDeliveries == 2 }
            check(latestDeliveries == 2 && renderedEdits.last == edit,
                  "coalesced requests receive the newest edit")
            check(coalescing.cached(newest) != nil, "the newest render is cached under its fingerprint")

            app.open(url: a, knownPhotoID: aID)
            await waitForLoading { app.store.edit == edit && !app.isDecoding && !app.isRendering }
            try library.deleteDevelopment(id: developmentID)
            app.store.perform("Exposure") { $0.tone.exposure = 2 }
            app.open(url: b, knownPhotoID: bID)
            check(app.imageURL == a && app.store.isDirty && app.store.edit.tone.exposure == 2
                    && app.errorMessage != nil,
                  "a failed save keeps the outgoing photo and its unsaved edit")
            check(everyWindowIsOutOfTheWay(), "test windows remain below the desktop")
        } catch {
            check(false, "\(error)")
        }
        log("loading self-test: \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 2)
    }

    @MainActor
    static func waitForLoading(_ ready: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !ready(), Date() < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
