import AppKit
import GrayroomUI

/// Gives the Edit menu's Undo and Redo items an owner that is still awake after
/// launch.
///
/// # Why this exists
///
/// `App.body` — and with it the `.commands { }` builder and every view inside it
/// — is evaluated **once**, at launch. Reads of `@Observable` state in there are
/// not tracked, so the builder's `.disabled(…)` is frozen at its launch value
/// for the life of the process. (Measured: `UndoRedoCommands.body` logs exactly
/// one evaluation, `canUndo=false`, no matter how much the store changes.)
///
/// That would be merely cosmetic if a disabled command were just greyed out. It
/// is not: SwiftUI builds a disabled command as an `NSMenuItem` with **no action
/// and no target**, and AppKit's key-equivalent matching skips items it cannot
/// send. A command that was disabled at launch therefore swallows its keyboard
/// shortcut forever — which is exactly how Cmd-Z came to do nothing at all.
///
/// So SwiftUI keeps what it is good at (declaring the item, its title, its
/// position and its key equivalent) and AppKit takes back what it is good at:
/// the target/action and `validateMenuItem`, which AppKit re-asks on *every*
/// menu update and every key equivalent. Enablement is then read from the store
/// at the moment it matters instead of being cached at launch.
///
/// The SwiftUI buttons deliberately carry no `.disabled(…)`, so if a future
/// SwiftUI ever does rebuild the menu, the items fall back to SwiftUI's own
/// always-live action: the worst case is losing the grey-out, never the command.
@MainActor
final class UndoMenuController: NSObject, NSMenuItemValidation {
    static let shared = UndoMenuController()

    private var store: EditStateStore?

    /// Adopts the Undo/Redo items SwiftUI put in the menu bar. Call after the
    /// menu exists, i.e. from `applicationDidFinishLaunching`.
    ///
    /// SwiftUI rebuilds its menu items from scratch every so often (measured:
    /// once, some time after the first key equivalent is dispatched), which
    /// throws away whatever was set on the old ones. So adoption re-runs
    /// whenever anything is added to a menu; otherwise enablement silently
    /// reverts to SwiftUI's frozen launch-time answer.
    func adoptMenuItems(store: EditStateStore) {
        self.store = store
        NotificationCenter.default.addObserver(self, selector: #selector(menuItemAdded(_:)),
                                               name: NSMenu.didAddItemNotification, object: nil)
        adopt()
    }

    @objc private func menuItemAdded(_ notification: Notification) { adopt() }

    private func adopt() {
        guard store != nil,
              let undo = UndoMenuController.item(key: "z", modifiers: [.command]),
              let redo = UndoMenuController.item(key: "z", modifiers: [.command, .shift]) else {
            return
        }
        guard undo.target !== self || redo.target !== self else { return }
        undo.target = self
        undo.action = #selector(undoAction(_:))
        redo.target = self
        redo.action = #selector(redoAction(_:))
        SelfTest.note("UndoMenuController: adopted '\(undo.title)' and '\(redo.title)'")
    }

    /// The item carrying a given key equivalent, anywhere in the menu bar.
    /// Matched on the shortcut rather than the title so it survives a renamed or
    /// localized menu item.
    private static func item(key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        guard let main = NSApp.mainMenu else { return nil }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            if let found = submenu.items.first(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers
            }) {
                return found
            }
        }
        return nil
    }

    @objc private func undoAction(_ sender: Any?) {
        SelfTest.note("UndoMenuController.undoAction")
        store?.undo()
    }

    @objc private func redoAction(_ sender: Any?) {
        SelfTest.note("UndoMenuController.redoAction")
        store?.redo()
    }

    /// The live enablement AppKit asks for on every menu update and before every
    /// key equivalent — the answer SwiftUI's frozen `.disabled(…)` could not give.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let store else { return false }
        switch menuItem.action {
        case #selector(undoAction(_:)): return store.canUndo
        case #selector(redoAction(_:)): return store.canRedo
        default: return true
        }
    }
}
