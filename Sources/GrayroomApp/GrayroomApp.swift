import AppKit
import GrayroomLibrary
import SwiftUI

/// `swift run GrayroomApp [file.DNG]`.
///
/// SPM builds a bare Mach-O, not an `.app` bundle, so the process starts as a
/// background ("prohibited") application: no menu bar, no Dock tile, and the
/// window opens behind whatever has focus. Promoting it to `.regular` and
/// activating in `applicationDidFinishLaunching` is the standard fix and is what
/// makes the app usable straight from the terminal without an Xcode project.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Window-level keyboard routing for both grids and the canvas. Held here
    /// because it lives exactly as long as the application does — see
    /// `KeyRouter` for why the keys are not a view's business.
    private var keyRouter: KeyRouter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // By title, not `.first`: there is a second `Window` scene now, and
        // whichever one AppKit happens to have created first is not necessarily
        // the editor.
        if let window = NSApp.windows.first(where: { $0.title == "Grayroom" })
            ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: 1440, height: 900))
            window.center()
        }
        AppModel.shared.openInitialDocument()
        keyRouter = KeyRouter(model: AppModel.shared)
        keyRouter?.install()
        // The menu bar exists by now; take over Undo/Redo (see UndoMenu.swift).
        UndoMenuController.shared.adoptMenuItems(store: AppModel.shared.store)
        SelfTest.startIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Double-clicking a RAW in the Finder (or `open -a`) lands here. Being
    /// handed a file is a request to develop it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppModel.shared.open(url: url)
        AppModel.shared.mode = .develop
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
                // A separate `View` so it can hold `@Environment(\.openWindow)`;
                // the commands builder itself is not a view and has no
                // environment to read it from.
                ImportCommand()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveNow() }
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
            // Into SwiftUI's own View menu, which is why this is a
            // `CommandGroup` and not a `CommandMenu("View")`: a second menu
            // with that name would be unaddressable.
            //
            // Bare `g` and `d`, as in Lightroom. A menu key equivalent is
            // matched by AppKit before the event reaches any view, so this is
            // what actually makes the two keys work everywhere; the views
            // handle them too, for the case the menu does not take them.
            CommandGroup(before: .sidebar) {
                Button("Library") { model.showLibrary() }
                    .keyboardShortcut("g", modifiers: [])
                Button("Develop") { model.showDevelop() }
                    .keyboardShortcut("d", modifiers: [])
                Divider()
            }
            // Lightroom's colour labels, on Lightroom's keys: 6/7/8/9 for
            // red/yellow/green/blue, and purple with no key at all (Lightroom
            // does not give it one). 1-5 are deliberately left alone — they are
            // Lightroom's star ratings, which this app does not have yet.
            //
            // No `.disabled(…)` anywhere: this builder runs once, at launch, so
            // a disabled item would stay disabled for the session and its key
            // equivalent would be swallowed (see the undo note above).
            // `AppModel` simply does nothing when nothing is selected.
            CommandMenu("Photo") {
                Menu("Set Color Label") {
                    Button("Red") { model.toggleColorLabel(.red) }
                        .keyboardShortcut("6", modifiers: [])
                    Button("Yellow") { model.toggleColorLabel(.yellow) }
                        .keyboardShortcut("7", modifiers: [])
                    Button("Green") { model.toggleColorLabel(.green) }
                        .keyboardShortcut("8", modifiers: [])
                    Button("Blue") { model.toggleColorLabel(.blue) }
                        .keyboardShortcut("9", modifiers: [])
                    Button("Purple") { model.toggleColorLabel(.purple) }
                    Divider()
                    Button("None") { model.setColorLabel(.unlabeled) }
                }
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

        Window("Import", id: "import") {
            ImportWindow(model: model.importModel)
        }
        .defaultSize(width: 1100, height: 750)
    }
}

/// File › Import… — the panel first, the window second, so the window never
/// opens on an empty source.
private struct ImportCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Import…") {
            guard let url = ImportModel.presentSourcePanel() else { return }
            AppModel.shared.importModel.setSource(url)
            openWindow(id: "import")
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}
