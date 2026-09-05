import AppKit
import GrayroomCore
import GrayroomLibrary

extension SelfTest {
    @MainActor
    static func runTerminationChecks() async {
        do {
            let scenario = ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_TERMINATION"] ?? "saved"
            let url = outputDirectory.appendingPathComponent("termination-\(UUID().uuidString).png")
            try ImageWriter.write(image: FloatImage(width: 8, height: 8,
                                                    pixels: Array(repeating: 0.4, count: 8 * 8 * 4)),
                                  to: url, format: .png)
            let library = try Library.openDefault()
            let photoID = try Importer(library: library).importFile(at: url).photoID
            var edit = EditState()
            edit.tone.exposure = 1
            let development = try library.addDevelopment(photoID: photoID, edit: edit)
            let app = AppModel.shared
            app.open(url: url, knownPhotoID: photoID)
            if scenario != "lookup" {
                let deadline = Date().addingTimeInterval(5)
                while app.store.edit != edit, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard app.store.edit == edit else { fail("stored edit did not load") }
            }
            if scenario == "failure" { try library.deleteDevelopment(id: development.id!) }
            app.store.perform("Exposure") { $0.tone.exposure = 2 }
            _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                       object: nil, queue: .main) { _ in
                guard scenario != "failure" else { fail("termination discarded an unsaved edit") }
                do {
                    guard try library.development(id: development.id!)?.edit.tone.exposure == 2 else {
                        fail("termination did not save exposure 2 (\(scenario))")
                    }
                    log("termination self-test: PASS — saved before quitting (\(scenario))")
                } catch { fail("termination readback: \(error)") }
            }
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            try await Task.sleep(for: .milliseconds(200))
            guard scenario == "failure" else { fail("termination did not complete") }
            guard app.store.isDirty, app.store.edit.tone.exposure == 2, app.errorMessage != nil else {
                fail("failed termination did not preserve the edit and report the error")
            }
            log("termination self-test: PASS — save failure cancelled quitting")
            exit(0)
        } catch { fail("termination self-test: \(error)") }
    }
}
