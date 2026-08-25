import AppKit
import GrayroomLibrary
import GrayroomUI
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
        // A self-test must never take the screen away from whoever is using the
        // machine: it runs as an accessory (no Dock tile, no menu bar of its
        // own), never activates, and puts its windows below the desktop — see
        // `SelfTest.stayOutOfTheWay()`.
        if SelfTest.isRequested {
            NSApp.setActivationPolicy(.accessory)
            SelfTest.stayOutOfTheWay()
        } else {
            NSApp.setActivationPolicy(.regular)
            // After the policy call, not before: `.prohibited` has no Dock tile
            // to put a picture on, and the assignment is silently dropped.
            // SPM builds a bare Mach-O, so there is no `.app` bundle for the
            // Finder to read an icon out of — the app has to set its own.
            if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = image
            } else {
                NSLog("Grayroom: AppIcon.icns not found in bundle")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        // By title, not `.first`: there is a second `Window` scene now, and
        // whichever one AppKit happens to have created first is not necessarily
        // the editor.
        if let window = NSApp.windows.first(where: { $0.title == "Grayroom" })
            ?? NSApp.windows.first {
            if SelfTest.isRequested {
                // `orderFront`, not `makeKeyAndOrderFront`: the window has to be
                // laid out and drawn (the tests click what they see) without the
                // app coming forward.
                window.orderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
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
        // The controls live *in* the title bar (see `RootView.toolbar`), so the
        // title text is off: one bar across the top rather than a line of text
        // with a row of buttons under it. The window keeps its `title` string —
        // that is what `applicationDidFinishLaunching` and `KeyRouter` find it
        // by, and what accessibility reads out — only the drawn text goes.
        .windowToolbarStyle(.unified(showsTitle: false))
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
                // Lightroom's third view key, and the Library module's other
                // view: `e` for the loupe, from the grid or from Develop.
                Button("Loupe") { model.showLoupe() }
                    .keyboardShortcut("e", modifiers: [])
                Button("Develop") { model.showDevelop() }
                    .keyboardShortcut("d", modifiers: [])
                Divider()
                // macOS's own shortcut for a sidebar. In *this* group and not
                // `CommandGroup(replacing: .sidebar)`: replacing that group
                // takes the anchor this one is positioned against with it, and
                // Library and Develop then vanish from the menu bar along with
                // their bare keys (measured — the library self-test caught it).
                //
                // The title does not flip between "Show" and "Hide" because
                // this builder runs once, at launch (see the undo note above),
                // so a title read off the model would freeze at what it said
                // then.
                Button("Show/Hide Folders") { model.toggleFolderSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
            }
            // Lightroom Classic keeps the Sort control in the grid's toolbar
            // and its keys under View › Sort; this app has neither yet, so both
            // halves of the control live here, in the module's own menu, next
            // to the other command that works on a whole selection.
            //
            // No checkmarks and no `.disabled(…)`: this builder runs once, at
            // launch (see the undo note above), so a state read here would
            // freeze at what it said then.
            CommandMenu("Library") {
                Menu("Sort By") {
                    ForEach(PhotoSortKey.allCases, id: \.self) { key in
                        Button(key.title) { model.setSortKey(key) }
                    }
                    Divider()
                    Button("Ascending") { model.setSortAscending(true) }
                    Button("Descending") { model.setSortAscending(false) }
                }
                Divider()
                Button("Select Similar Photos") { model.selectSimilarPhotos() }
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
