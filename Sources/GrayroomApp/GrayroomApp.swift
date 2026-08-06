import AppKit
import SwiftUI

/// `swift run GrayroomApp [file.DNG]`.
///
/// SPM builds a bare Mach-O, not an `.app` bundle, so the process starts as a
/// background ("prohibited") application: no menu bar, no Dock tile, and the
/// window opens behind whatever has focus. Promoting it to `.regular` and
/// activating in `applicationDidFinishLaunching` is the standard fix and is what
/// makes the app usable straight from the terminal without an Xcode project.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: 1440, height: 900))
            window.center()
        }
        AppModel.shared.openInitialDocument()
        // The menu bar exists by now; take over Undo/Redo (see UndoMenu.swift).
        UndoMenuController.shared.adoptMenuItems(store: AppModel.shared.store)
        SelfTest.startIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Double-clicking a RAW in the Finder (or `open -a`) lands here.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppModel.shared.open(url: url) }
    }
}

@main
struct GrayroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model = AppModel.shared

    var body: some Scene {
        Window("Grayroom", id: "main") {
            RootView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Sidecar") { model.saveSidecarNow() }
                    .keyboardShortcut("s", modifiers: .command)
                // No `.disabled(model.imageURL == nil)`: see the note below.
                // `presentExportSheet()` already ignores the request when there
                // is no image, and a disabled-at-launch item would kill Cmd-E
                // for the whole session.
                Button("Export…") { model.presentExportSheet() }
                    .keyboardShortcut("e", modifiers: .command)
            }
            // The app owns its UndoManager (there is no document), so the menu
            // items are wired straight to it rather than to the responder chain.
            //
            // Deliberately *not* `.disabled(!model.store.canUndo)`. This builder
            // runs exactly once, at launch (measured — see UndoMenu.swift), so a
            // `.disabled` here freezes at its launch value, and SwiftUI compiles
            // a disabled command into an `NSMenuItem` with a nil action, which
            // AppKit's key-equivalent matching skips. That combination is what
            // made Cmd-Z do nothing at all. `UndoMenuController` adopts these two
            // items after launch and supplies live enablement via
            // `validateMenuItem`; the actions below remain as a fallback.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { model.store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // Not "View": SwiftUI already installs a View menu (Enter Full
            // Screen) and a second one with the same name is unaddressable.
            CommandMenu("Image") {
                Button("Zoom to Fit") { model.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Zoom to 100%") { model.zoomToActualSize() }
                    .keyboardShortcut("1", modifiers: .command)
                Divider()
                Toggle("Before / After", isOn: Binding(get: { model.showBeforeAfter },
                                                       set: { model.showBeforeAfter = $0 }))
                Toggle("Mask Overlay", isOn: Binding(get: { model.showMaskOverlay },
                                                     set: { model.showMaskOverlay = $0 }))
                Divider()
                Button("Brush Tool") { model.tool = model.tool == .brush ? .pan : .brush }
                Button("Targeted Adjustment Tool") {
                    model.tool = model.tool == .targeted ? .pan : .targeted
                }
                Button("New Mask") { model.store.addMask(); model.tool = .brush }
            }
        }
    }
}
