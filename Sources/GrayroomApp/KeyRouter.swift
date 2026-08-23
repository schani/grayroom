import AppKit
import GrayroomLibrary
import GrayroomUI

/// Every bare-key command in the app, decided in one place, at the window level.
///
/// # Why not SwiftUI focus
///
/// The obvious way to give a grid keyboard commands is `.focusable()` +
/// `.onKeyPress`, and it is wrong here: the moment the user touches the
/// thumbnail slider, the mode picker or any toolbar button, focus leaves the
/// grid and the arrow keys stop working until they click a cell again. A photo
/// grid whose arrows die because you dragged the size slider is broken, and no
/// amount of `@FocusState` shuffling fixes it — the keys do not belong to a
/// *view*, they belong to the window and the module it is showing.
///
/// So a single local `NSEvent` monitor sees every `keyDown` before the app
/// dispatches it, and this decides who it is for:
///
/// - a text field or field editor has the keyboard → nobody, always (the day
///   this app grows a text field, typing "g" into it must not change modules);
/// - a sheet, a panel or a modal is up → nobody;
/// - the Import window is key → the import grid;
/// - the main window is key → the library grid or the develop canvas, by mode.
///
/// # Menu key equivalents
///
/// Local monitors run *before* `NSApp.sendEvent`, and therefore before menu
/// key-equivalent matching. So when this consumes `g`, `d` or `6`–`9`, the
/// matching menu item does not also fire: the action runs exactly once. The
/// menu items still carry their key equivalents — they are how the keys are
/// discoverable, and they are what fires when this router stands aside.
final class KeyRouter {
    private unowned let model: AppModel
    private var monitor: Any?

    init(model: AppModel) {
        self.model = model
    }

    /// Installed once, at launch. Local (not global): it sees only this app's
    /// events and needs no accessibility permission.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// `true` when the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        // `keyWindow` first, but not only: an app launched from a terminal as a
        // bare Mach-O can be active with a *main* window and no key window at
        // all, and in that state a `keyWindow`-only router silently does
        // nothing while the menu's key equivalents keep working — which is
        // exactly the sort of half-working keyboard this class exists to
        // prevent (measured: the arrows and ⌘A died, `g`/`d`/`6`–`9` did not,
        // because those have menu items and the arrows do not).
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? KeyRouter.mainWindow(),
              KeyRouter.acceptsKeys(window)
        else { return false }
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Anything with Control or Option in it belongs to whatever else claims
        // it; Command survives only for the one shortcut below.
        guard !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)

        if window.title == "Import" {
            return handleImport(characters, shift: shift, command: command, window: window)
        }
        guard window == KeyRouter.mainWindow() else { return false }
        switch model.mode {
        case .library:
            return handleLibrary(characters, shift: shift, command: command)
        case .develop:
            return handleDevelop(characters, shift: shift, command: command)
        }
    }

    // MARK: - The grids

    private func handleLibrary(_ characters: String, shift: Bool, command: Bool) -> Bool {
        if command {
            // Lightroom's Select All. Not a menu item: SwiftUI drops a ⌘A
            // shortcut on the floor while AppKit's own (disabled, unhandled)
            // Edit › Select All sits in the menu bar.
            guard characters == "a" else { return false }
            model.selectAllPhotos()
            return true
        }
        if let (dx, dy) = KeyRouter.arrow(characters) {
            SelfTest.note("library arrow dx=\(dx) dy=\(dy) shift=\(shift) "
                + "anchor=\(String(describing: model.librarySelection.anchor)) "
                + "cursor=\(String(describing: model.librarySelection.cursor)) "
                + "count=\(model.librarySelection.count)")
            // Shift-arrow grows the range from the anchor, as in Lightroom and
            // the Finder; a bare arrow moves a one-cell highlight.
            if shift {
                model.extendLibraryHighlight(dx: dx, dy: dy)
            } else {
                model.moveLibraryHighlight(dx: dx, dy: dy)
            }
            return true
        }
        switch characters {
        case "g": return true                       // already here
        case "d": model.showDevelop()
        case "6": model.toggleColorLabel(.red)
        case "7": model.toggleColorLabel(.yellow)
        case "8": model.toggleColorLabel(.green)
        case "9": model.toggleColorLabel(.blue)
        case "+", "=": model.stepLibraryThumbnailSize(1)
        case "-", "_": model.stepLibraryThumbnailSize(-1)
        default: return false
        }
        return true
    }

    private func handleDevelop(_ characters: String, shift: Bool, command: Bool) -> Bool {
        guard !command else { return false }
        switch characters {
        case "g": model.showLibrary()
        case "d": return true                       // already here
        case "6": model.toggleColorLabel(.red)
        case "7": model.toggleColorLabel(.yellow)
        case "8": model.toggleColorLabel(.green)
        case "9": model.toggleColorLabel(.blue)
        // The canvas's own commands, routed here so they keep working when the
        // sidebar — not the canvas — has the keyboard. `\` is deliberately not
        // here: it is a *held* key, and holding needs the key-up the canvas
        // already tracks.
        case "b": model.canvasKeyCommand(.toggleBrush)
        case "t": model.canvasKeyCommand(.toggleTargeted)
        case "e": model.canvasKeyCommand(.toggleEraser)
        case "[", "{": model.canvasKeyCommand(shift ? .featherStep(-1) : .sizeStep(-1))
        case "]", "}": model.canvasKeyCommand(shift ? .featherStep(1) : .sizeStep(1))
        case "0": model.canvasKeyCommand(.fit)
        case "1": model.canvasKeyCommand(.actualSize)
        default: return false
        }
        return true
    }

    private func handleImport(_ characters: String, shift: Bool, command: Bool,
                              window: NSWindow) -> Bool {
        guard !command else { return false }
        let model = self.model.importModel
        if let (dx, dy) = KeyRouter.arrow(characters) {
            if shift {
                model.extendHighlight(dx: dx, dy: dy, columns: model.columns)
            } else {
                model.moveHighlight(dx: dx, dy: dy, columns: model.columns)
            }
            return true
        }
        switch characters {
        case " ": model.toggleHighlighted()
        case "p": model.setCheckedForHighlighted(true)
        case "u": model.setCheckedForHighlighted(false)
        case "+", "=": model.stepThumbnailSize(1)
        case "-", "_": model.stepThumbnailSize(-1)
        case "\u{1b}":
            model.stopScanning()
            window.performClose(nil)
        default: return false
        }
        return true
    }

    // MARK: - Who gets the key

    private static func arrow(_ characters: String) -> (dx: Int, dy: Int)? {
        switch characters.unicodeScalars.first?.value {
        case UInt32(NSLeftArrowFunctionKey): return (-1, 0)
        case UInt32(NSRightArrowFunctionKey): return (1, 0)
        case UInt32(NSUpArrowFunctionKey): return (0, -1)
        case UInt32(NSDownArrowFunctionKey): return (0, 1)
        default: return nil
        }
    }

    /// The editor window. Not by title — it renames itself to the open file —
    /// but by being the one window that is neither the import window nor a
    /// panel.
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.title != "Import" && !($0 is NSPanel) && !$0.isSheet
        }
    }

    /// Whether a bare key means a command at all right now.
    static func acceptsKeys(_ window: NSWindow) -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        guard !window.isSheet, !(window is NSPanel), window.attachedSheet == nil else {
            return false
        }
        return !isEditingText(window)
    }

    /// A text field, a text view, or the field editor standing in for one.
    static func isEditingText(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if let text = responder as? NSText, text.isEditable { return true }
        return false
    }
}
