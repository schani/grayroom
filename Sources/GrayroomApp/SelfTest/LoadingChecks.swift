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
    private static func waitForLoading(_ ready: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !ready(), Date() < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
