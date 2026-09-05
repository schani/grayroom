import AppKit
import GrayroomCore
import GrayroomLibrary

extension SelfTest {
    @MainActor
    static func runComparisonChecks() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            log("comparison self-test: \(condition ? "PASS" : "FAIL") — \(message)")
            if !condition { failures += 1 }
        }
        do {
            let url = outputDirectory.appendingPathComponent("comparison-\(UUID().uuidString).png")
            try ImageWriter.write(image: FloatImage(width: 8, height: 8,
                                                    pixels: Array(repeating: [Float(0.9), 0.02, 0.1, 1], count: 64).flatMap { $0 }),
                                  to: url, format: .png)
            let library = try Library.openDefault()
            defer { try? library.close() }
            let photoID = try Importer(library: library).importFile(at: url).photoID
            let app = AppModel.shared
            app.openChosenFile(url)
            await waitForLoading { app.currentPhotoID == photoID && !app.isDecoding && !app.isRendering }
            let canvas = app.makeCanvas()
            app.showBeforeAfter = true
            guard let texture = canvas.imageTexture else { fail("missing before texture") }
            let original = try TextureReadback.read(texture).pixels
            app.store.perform("White Balance") { $0.whiteBalance.temperature = 9000 }
            await waitForLoading { !app.isDecoding && !app.isRendering }
            check(try TextureReadback.read(canvas.imageTexture!).pixels == original,
                  "white-balance changes leave Before unchanged")
            app.saveNow()
            app.open(url: url, knownPhotoID: photoID)
            await waitForLoading {
                app.store.edit.whiteBalance.temperature == 9000 && !app.isDecoding && !app.isRendering
            }
            check(try TextureReadback.read(canvas.imageTexture!).pixels == original,
                  "opening a saved white-balance edit still shows the default Before")
            app.showBeforeAfter = false
            check(try TextureReadback.read(canvas.imageTexture!).pixels != original,
                  "the edited white balance still appears in After")
            guard let window = KeyRouter.mainWindow() else { fail("missing editor window") }
            let router = KeyRouter(model: app)
            router.install()
            func key(_ type: NSEvent.EventType, _ chars: String, _ code: UInt16,
                     modifiers: NSEvent.ModifierFlags = []) -> Bool {
                router.handle(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: code)!)
            }
            check(key(.keyDown, "\\", 42) && app.showBeforeAfter, "holding backslash shows Before")
            _ = key(.keyDown, "g", 5)
            _ = key(.keyUp, "\\", 42)
            _ = key(.keyDown, "d", 2)
            check(!app.showBeforeAfter, "releasing in Library clears the hold before returning to Develop")
            app.showBeforeAfter = false
            _ = key(.keyDown, "\\", 42)
            _ = key(.keyUp, "|", 42, modifiers: .shift)
            check(!app.showBeforeAfter, "changing modifiers does not lose the release")
            app.showBeforeAfter = false
            _ = key(.keyDown, "\\", 42)
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
            let responder = window.firstResponder
            window.contentView?.addSubview(field)
            window.makeFirstResponder(field)
            _ = key(.keyUp, "\\", 42)
            check(!app.showBeforeAfter, "moving focus into text does not lose the release")
            window.makeFirstResponder(responder)
            field.removeFromSuperview()
            app.showBeforeAfter = false
            _ = key(.keyDown, "\\", 42)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            check(!app.showBeforeAfter, "leaving the app clears a held comparison")
            app.showBeforeAfter = true
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            check(app.showBeforeAfter, "leaving the app preserves a comparison latched through the menu")
            app.showBeforeAfter = false
            check(everyWindowIsOutOfTheWay(), "test windows remain below the desktop")
        } catch {
            check(false, "\(error)")
        }
        exit(failures == 0 ? 0 : 2)
    }
}
