import AppKit

/// Finding an item AppKit has, wherever SwiftUI put it.
enum MenuBar {
    /// The item carrying a given key equivalent, anywhere in the menu bar.
    /// Matched on the shortcut rather than the title so it survives a renamed or
    /// localized menu item.
    static func item(key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
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
}

/// Gives File › Export… live enablement, for the same reason Undo and Redo have
/// an owner of their own: the `.commands` builder runs once, at launch, so a
/// `.disabled(…)` in there would freeze at its launch value and — worse — take
/// ⌘E with it for the session. See `UndoMenuController` for the measurements.
///
/// Export is enabled when there is something to export: a photo highlighted in
/// the Library (in the loupe, the one on screen), or an image open in Develop.
@MainActor
final class ExportMenuController: NSObject, NSMenuItemValidation {
    static let shared = ExportMenuController()

    private var model: AppModel?

    func adoptMenuItem(model: AppModel) {
        self.model = model
        NotificationCenter.default.addObserver(self, selector: #selector(menuItemAdded(_:)),
                                               name: NSMenu.didAddItemNotification, object: nil)
        adopt()
    }

    @objc private func menuItemAdded(_ notification: Notification) { adopt() }

    private func adopt() {
        guard model != nil,
              let export = MenuBar.item(key: "e", modifiers: [.command]),
              export.target !== self else { return }
        export.target = self
        export.action = #selector(exportAction(_:))
        SelfTest.note("ExportMenuController: adopted '\(export.title)'")
    }

    @objc private func exportAction(_ sender: Any?) {
        SelfTest.note("ExportMenuController.exportAction")
        model?.presentExportSheet()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let model else { return false }
        return menuItem.action == #selector(exportAction(_:)) ? model.canExport : true
    }
}
