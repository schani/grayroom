import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomLibrary
import GrayroomUI

/// `GRAYROOM_SELFTEST=previews` — see `SelfTest.Mode.previews`.
extension SelfTest {
    static func runPreviews() {
        var failures: [String] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            fail("preview self-test timed out; the preview queue did not drain")
        }
        func check(_ ok: Bool, _ what: String) {
            log("preview self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grayroom-preview-selftest-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let library = try Library(url: directory.appendingPathComponent("library.sqlite"))
            let configuration = OriginalStorageConfiguration(
                endpoint: directory.appendingPathComponent("objects").absoluteString,
                region: "test", bucket: "photos",
                cacheDirectory: directory.appendingPathComponent("cache").path)
            let originals = try configuration.makeStorage(credentials: nil)
            library.originalStorage = originals
            let source = directory.appendingPathComponent("source.raw")
            try Data("preview source".utf8).write(to: source)
            let importer = Importer(library: library, originals: originals) { _ in
                PhotoMetadata(width: 2, height: 2)
            }
            let photoID = try importer.importFile(at: source).photoID
            _ = try library.addDevelopment(photoID: photoID, edit: EditState())

            let legacyJSON = #"{"style":"softColor","treatment":"color","bwMix":{"red":0}}"#
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [library.url.path,
                                 "UPDATE developments SET edit_json = '\(legacyJSON)' "
                                     + "WHERE photo_id = \(photoID) AND ordinal = 1"]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PreviewSelfTestError.couldNotWriteLegacyJSON
            }

            let snapshot = try library.catalogSnapshot()
            let photo = try library.photo(id: photoID)!
            let catalogPhoto = CatalogPhoto(
                photo: photo, summary: snapshot.summaries[photoID] ?? PhotoSummary())!
            let legacyFingerprint = EditState.fingerprint(ofEditJSON: Data(legacyJSON.utf8))
            check(catalogPhoto.developmentFingerprint == legacyFingerprint,
                  "the catalog carries the legacy JSON fingerprint")
            check(catalogPhoto.developmentFingerprint != EditState().fingerprint,
                  "the fixture reproduces the decoded/re-encoded mismatch")

            let previewStore = try PreviewStore.open(for: library)
            let tasks = TaskCenter()
            let builder = PreviewBuilder()
            builder.library = library
            builder.originals = originals
            builder.previews = previewStore
            builder.tasks = tasks
            var renderCount = 0
            builder.render = { _, _, done in
                renderCount += 1
                done(previewSelfTestImage())
            }

            builder.image(for: catalogPhoto) { image in
                check(image != nil, "legacy JSON produces a preview")
                check(renderCount == 1, "legacy JSON renders once")
                check(!tasks.tasks.contains { $0.title == "Building previews" },
                      "the preview task drains")
                let row = try? previewStore.preview(for: photo.hash)
                check(row?.fingerprint == legacyFingerprint,
                      "the preview keeps the stored JSON fingerprint")

                // Start the second request after the first delivery has fully
                // unwound; a cell asks on a later SwiftUI update the same way.
                DispatchQueue.main.async {
                    let developmentID: Int64
                    var changed = EditState()
                    changed.tone.exposure = 1
                    do {
                        _ = try previewStore.delete(hash: photo.hash)
                        developmentID = try library.developments(for: photoID).first!.id!
                        _ = try library.updateDevelopment(id: developmentID, edit: changed)
                    } catch {
                        fail("preview stale-request setup: \(error)")
                    }
                    builder.invalidate(photoID: photoID)
                    builder.image(for: catalogPhoto) { staleImage in
                        check(staleImage == nil, "a stale catalog request is discarded")
                        check(renderCount == 1,
                              "a stale request without a replacement is not rendered")
                        check(!tasks.tasks.contains { $0.title == "Building previews" },
                              "the stale request also drains")

                        do {
                            let summary = try library.catalogSnapshot().summaries[photoID]
                                ?? PhotoSummary()
                            let current = CatalogPhoto(photo: photo, summary: summary)!
                            var newer: CatalogPhoto?
                            var replacementRenders = 0
                            var completionCount = 0
                            var nonnilResults = 0

                            func finishIfComplete() {
                                guard completionCount == 2, let newer else { return }
                                check(replacementRenders == 2,
                                      "a queued newer request renders after the old one")
                                check(nonnilResults == 2,
                                      "both waiters receive the newer request's result")
                                check(builder.cached(newer) != nil,
                                      "the memory cache holds the newer result")
                                let latest = try? previewStore.preview(for: photo.hash)
                                check(latest?.fingerprint == newer.developmentFingerprint,
                                      "the stored preview matches the newer request")
                                check(!tasks.tasks.contains { $0.title == "Building previews" },
                                      "the replacement request drains")
                                try? previewStore.close()
                                try? library.close()
                                try? FileManager.default.removeItem(at: directory)
                                if failures.isEmpty {
                                    log("preview self-test: PASS")
                                    exit(0)
                                }
                                log("preview self-test: FAILED — "
                                    + failures.joined(separator: "; "))
                                exit(4)
                            }

                            builder.render = { _, _, done in
                                replacementRenders += 1
                                if replacementRenders == 1 {
                                    DispatchQueue.main.async {
                                        var newestEdit = changed
                                        newestEdit.tone.exposure = 2
                                        do {
                                            _ = try library.updateDevelopment(
                                                id: developmentID, edit: newestEdit)
                                            let newestSummary = try library.catalogSnapshot()
                                                .summaries[photoID] ?? PhotoSummary()
                                            newer = CatalogPhoto(photo: photo,
                                                                 summary: newestSummary)!
                                        } catch {
                                            fail("preview replacement setup: \(error)")
                                        }
                                        builder.image(for: newer!) { result in
                                            completionCount += 1
                                            if result != nil { nonnilResults += 1 }
                                            finishIfComplete()
                                        }
                                        done(previewSelfTestImage())
                                    }
                                } else {
                                    done(previewSelfTestImage())
                                }
                            }
                            builder.image(for: current) { result in
                                completionCount += 1
                                if result != nil { nonnilResults += 1 }
                                finishIfComplete()
                            }
                        } catch {
                            fail("preview replacement setup: \(error)")
                        }
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            fail("preview self-test setup: \(error)")
        }
    }

    static func previewSelfTestImage() -> CGImage {
        let bytes = Data([20, 40, 60, 255, 80, 100, 120, 255,
                          140, 160, 180, 255, 200, 220, 240, 255])
        let provider = CGDataProvider(data: bytes as CFData)!
        return CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(
                           rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}

private enum PreviewSelfTestError: Error {
    case couldNotWriteLegacyJSON
}
