import AppKit
import GrayroomLibrary
import GrayroomUI

/// Every bare-key command in the app, decided in one place, at the window level.
///
/// # Why not SwiftUI focus
///
/// The obvious way to give a grid keyboard commands is `.focusable()` +
/// `.onKeyPress`, and it is wrong here: the moment the user touches the
/// thumbnail slider or a row of the Folders panel, focus leaves the grid and
/// the arrow keys stop working until they click a cell again. A photo
/// grid whose arrows die because you dragged the size slider is broken, and no
/// amount of `@FocusState` shuffling fixes it — the keys do not belong to a
/// *view*, they belong to the window and the module it is showing.
///
/// So a single local `NSEvent` monitor sees every key event before the app
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
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
        // Lightroom's before/after key, and the only key this router takes a
        // `keyUp` for: `\` is *held*, and the canvas that tracks the hold is
        // not always the first responder — with the sidebar focused the key did
        // nothing at all. View › Before / After keeps `\` for discoverability,
        // exactly as `g` and `d` do, and latches the comparison when picked.
        //
        // Named modifiers rather than `modifiers.isEmpty`: an event carries
        // bits of its own inside the device-independent mask (a `CGEvent` sets
        // the non-coalesced one), and an emptiness test throws the key away.
        if characters == "\\", modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
           window == KeyRouter.mainWindow(), model.mode == .develop {
            if event.type == .keyUp {
                model.canvasBeforeAfterHeld(false)
            } else if !event.isARepeat {
                model.canvasBeforeAfterHeld(true)
            }
            return true
        }
        guard event.type == .keyDown else { return false }
        // ⌥⌘S — macOS's shortcut for a sidebar, and the one Option key this
        // router claims. It has to be claimed here: AppKit answers ⌥⌘S itself,
        // out of the window's own toolbar, and its answer for a SwiftUI
        // `NavigationSplitView` is to do nothing at all — so View › Show/Hide
        // Folders never sees the key (measured: the menu item fires from the
        // menu and never from the keyboard). The item keeps the shortcut for
        // discoverability, exactly as `g` and `d` do.
        if modifiers == [.command, .option], characters == "s" {
            guard window == KeyRouter.mainWindow(), model.mode == .library,
                  model.libraryViewMode == .grid else { return false }
            model.toggleFolderSidebar()
            return true
        }
        // Anything else with Control or Option in it belongs to whatever else
        // claims it; Command survives only for the one shortcut below.
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
        // The loupe is a *view* of the Library module, not a module of its own —
        // Lightroom's G/E pair — so it is routed from inside the library rather
        // than beside it.
        if model.libraryViewMode == .loupe {
            return handleLoupe(characters, shift: shift, command: command)
        }
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
        // Lightroom's two ways into the loupe from the grid.
        case "e", "\r", "\u{3}": model.showLoupe()
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

    /// The Library module's loupe. One photo, so the arrows walk the filtered
    /// list instead of the grid: left and right by one, stopping at the ends,
    /// and up and down mean nothing at all.
    ///
    /// The table itself is `LoupeKeys`, in `GrayroomUI`, so that "0 zooms to fit
    /// in the loupe" is a claim a test can make without a window.
    private func handleLoupe(_ characters: String, shift: Bool, command: Bool) -> Bool {
        guard !command else { return false }
        let action: LoupeCommand
        if let (dx, dy) = KeyRouter.arrow(characters) {
            SelfTest.note("loupe arrow dx=\(dx) dy=\(dy) "
                + "photo=\(String(describing: model.loupePhotoID))")
            action = LoupeKeys.command(forArrow: dx, dy)
        } else if let command = LoupeKeys.command(for: characters) {
            action = command
        } else {
            return false
        }
        switch action {
        case .step(let delta): model.stepLoupe(delta)
        case .grid: model.showGrid()
        case .develop: model.showDevelop()
        case .colorLabel(let raw):
            if let color = ColorLabel(rawValue: raw) { model.toggleColorLabel(color) }
        case .zoomToFit: model.zoomToFit()
        case .zoomToActualSize: model.zoomToActualSize()
        case .nothing: break
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
        // sidebar — not the canvas — has the keyboard. `\` is above, with the
        // key-up it needs.
        case "b": model.canvasKeyCommand(.toggleBrush)
        case "t": model.canvasKeyCommand(.toggleTargeted)
        // Lightroom's `e`: back to the Library, in the loupe, on this photo.
        // The brush's eraser is Option-drag (and the sidebar's own toggle),
        // which is where Lightroom keeps it too.
        case "e": model.showLoupe()
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
