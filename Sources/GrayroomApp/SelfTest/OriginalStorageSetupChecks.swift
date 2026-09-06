import AppKit
import GrayroomLibrary

extension SelfTest {
    static func runOriginalStorageSetup() {
        let app = AppModel.shared
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                log("storage setup self-test: PASS — \(message)")
            } else {
                failures.append(message)
                log("storage setup self-test: FAIL — \(message)")
            }
        }

        check(app.isOriginalStorageSetupPresented, "missing configuration presents setup")
        check(NSApp.windows.contains { $0.sheetParent != nil }, "setup is a modal sheet")
        for name in ["storage-endpoint", "storage-region", "storage-bucket", "storage-prefix",
                     "storage-cache-directory", "storage-access-key", "storage-secret-key",
                     "storage-session-token", "storage-save"] {
            check(controlFrame(named: name) != nil, "\(name) is present")
        }

        guard let libraryURL = try? Library.defaultURL() else {
            fail("could not resolve the self-test library")
        }
        let root = libraryURL.deletingLastPathComponent()
        let photo = root.appendingPathComponent("before-setup.jpg")
        guard writeSyntheticJPEG(to: photo) else { fail("could not create the setup test photo") }
        app.open(url: photo)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            check(app.errorMessage?.contains("missing configuration") == true,
                  "a pre-setup read reports its storage failure")
            app.originalStorageSetup.endpoint = root.appendingPathComponent("objects").absoluteString
            app.originalStorageSetup.region = "test"
            app.originalStorageSetup.bucket = "photos"
            app.originalStorageSetup.prefix = "originals"
            app.originalStorageSetup.cacheDirectory = root.appendingPathComponent("cache").path
            app.originalStorageSetup.accessKeyID = "test-key"
            app.originalStorageSetup.secretAccessKey = "test-secret"
            check(clickControl(named: "storage-save"), "Save is clickable")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                check(!app.isOriginalStorageSetupPresented, "Save dismisses setup")
                check(app.errorMessage == nil, "Save clears the earlier storage error")
                let stored = try? Library.openDefault().configuration()
                check(stored?["storage.endpoint"] == app.originalStorageSetup.endpoint,
                      "Save persists the endpoint")
                check(stored?["storage.region"] == "test", "Save persists the region")
                check(stored?["storage.bucket"] == "photos", "Save persists the bucket")
                check(stored?["storage.prefix"] == "originals", "Save persists the prefix")
                check(stored?["cache.directory"] == app.originalStorageSetup.cacheDirectory,
                      "Save persists the cache directory")
                app.restoreLastOpenedFile(at: photo)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let restoredLibrary = try? Library.openDefault()
                    check((try? restoredLibrary?.photos().isEmpty) == true,
                          "restoring the last photo does not add a catalog row")
                    check(!FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("objects/photos/originals").path),
                          "restoring the last photo does not upload it")
                    if failures.isEmpty {
                        log("storage setup self-test: PASS")
                        exit(0)
                    }
                    log("storage setup self-test: FAILED — " + failures.joined(separator: "; "))
                    exit(7)
                }
            }
        }
    }
}
