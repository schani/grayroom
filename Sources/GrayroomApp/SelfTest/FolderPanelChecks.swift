import AppKit
import GrayroomLibrary
import GrayroomUI

/// The Folders panel, in the `library` self-test: the tree the import
/// produced, a real click on a row filtering the grid, and the Missing row.
extension SelfTest {
    // MARK: - The Folders panel

    /// The subfolder the staged source gets, and the one photo in it.
    static let folderSubfolderName = "Subfolder"
    /// Where the import came from — what the Folders panel must be showing.
    static var stagedSource: URL?

    /// Lightroom's left panel, end to end: the tree the import produced, a real
    /// click on a folder row filtering the grid, the arrows still belonging to
    /// the *grid* after that click, and the Missing row counting a photo whose
    /// last location was taken away underneath the app.
    ///
    /// The click is a real `NSEvent` into the list, not a write to
    /// `folderSelection`: what is under test is that a row is where it looks
    /// like it is and that clicking it selects that source.
    static func runFolderChecks(app: AppModel, window: NSWindow,
                                        check: @escaping (Bool, String) -> Void,
                                        failures: @escaping () -> [String]) {
        phase("folders")
        let sourcePath = (stagedSource ?? URL(fileURLWithPath: "/nowhere"))
            .standardizedFileURL.path
        let subPath = sourcePath + "/" + folderSubfolderName

        /// The catalog's own answer to "what is under this directory", computed
        /// without the tree — the tree is what is being checked.
        func photosUnder(_ directory: String) -> [Int64] {
            app.catalog.photos.filter { photo in
                photo.locations.contains {
                    FolderTree.directory(FolderTree.directory(ofPath: $0), isWithin: directory)
                }
            }.map(\.id)
        }

        // 16. The tree the import produced.
        let underSource = photosUnder(sourcePath)
        let parent = app.folders.node(at: sourcePath)
        log("library self-test: folders = "
            + app.folders.allNodes.map { "\($0.name)(\($0.count))" }.joined(separator: " "))
        check(parent != nil, "the Folders panel lists the imported folder (\(sourcePath))")
        check(parent?.count == underSource.count,
              "…counting the \(underSource.count) photo(s) under it "
                  + "(got \(parent.map { String($0.count) } ?? "no row"))")
        let sub = app.folders.node(at: subPath)
        check(sub?.name == folderSubfolderName,
              "…with its subfolder as a child row (got \(sub?.name ?? "no row"))")
        check(parent?.children.contains { $0.id == subPath } == true,
              "…which hangs off the imported folder itself")
        check(sub?.count == 1 && sub?.directCount == 1,
              "…and counts the one photo staged into it "
                  + "(got \(sub.map { "\($0.count)/\($0.directCount)" } ?? "no row"))")
        check(app.folders.totalCount == app.catalog.count,
              "All Photographs counts the whole catalog "
                  + "(\(app.folders.totalCount) of \(app.catalog.count))")
        check(app.folders.missingCount == 0,
              "nothing is missing yet (\(app.folders.missingCount))")

        guard let victim = app.catalog.photos.first(where: { photo in
            photo.locations.contains { FolderTree.directory(ofPath: $0) == subPath }
        })?.id else {
            check(false, "a photo in the subfolder to drive the rest with")
            finishLibrary(failures())
        }

        // The rows the panel should be drawing right now: the catalog row,
        // every folder whose ancestors are all open, and Missing at the bottom.
        func expectedRowIdentifiers() -> [String] {
            var paths = ["all"]
            func walk(_ node: FolderNode) {
                paths.append(node.id)
                guard app.expandedFolders.contains(node.id) else { return }
                node.children.forEach(walk)
            }
            app.folders.roots.forEach(walk)
            paths.append("missing")
            return paths.map(FolderSidebar.rowIdentifier)
        }
        let volume = app.folders.roots.first { FolderTree.directory(sourcePath, isWithin: $0.id) }
        /// A row's accessibility value: the folder's **full path**, which the
        /// two-line label no longer spells out.
        func rowValue(_ path: String) -> String {
            sidebarRow(FolderSidebar.rowIdentifier(path), in: window)?.value ?? "no row"
        }
        /// A row's accessibility label: the folder itself, without the parents
        /// folded into its row.
        func rowLabel(_ path: String) -> String {
            sidebarRow(FolderSidebar.rowIdentifier(path), in: window)?.label ?? "no row"
        }
        /// A row's count, as accessibility reads it out.
        func rowHelp(_ path: String) -> String {
            sidebarRow(FolderSidebar.rowIdentifier(path), in: window)?.help ?? "no row"
        }
        /// What the pointer resting on a row says.
        func rowTooltip(_ path: String) -> String {
            sidebarRow(FolderSidebar.rowIdentifier(path), in: window)?.tooltip ?? "no tooltip"
        }
        var afterFirstArrow: [Int64] = []

        let steps: [() -> Void] = [
            {
                // 17. Open the volume down to the subfolder, which is what
                //     clicking each disclosure triangle in turn does.
                app.browser.expandAncestors(of: subPath)
            },
            {
                // 18. What the panel is actually drawing, read back through
                //     the accessibility tree — the same tree a screen reader
                //     walks, so a row this sees is a row a user can reach.
                let rows = sidebarRows(in: window)
                log("library self-test: panel rows = "
                    + rows.map { "\($0.label) [\($0.help)] \($0.value)" }
                        .joined(separator: " | "))
                check(rows.map(\.identifier) == expectedRowIdentifiers(),
                      "the panel draws the catalog row, the open folders and Missing, "
                          + "in that order (\(rows.count) rows)")
                check(rowLabel("all") == "All Photographs"
                          && rowHelp("all") == FolderSidebar.countDescription(app.catalog.count),
                      "the Catalog row reads All Photographs, \(app.catalog.count) photos "
                          + "(got \(rowLabel("all")), \(rowHelp("all")))")
                // 18a. The row's label is the **leaf** folder, not the whole
                //      collapsed chain: Lightroom puts the folder you are
                //      looking for in the primary line and the parents folded
                //      into the row underneath it, because one long truncated
                //      path ("…mp.94AllfRlhp") hides exactly the word that
                //      identifies the row.
                check(rowLabel(sourcePath) == parent?.leafName,
                      "the imported folder's row reads its own name, not its whole chain "
                          + "(got '\(rowLabel(sourcePath))', leaf is "
                          + "'\(parent?.leafName ?? "?")', chain is "
                          + "'\(parent?.parentChain ?? "none")')")
                check(!rowLabel(sourcePath).contains("/"),
                      "…and it is one path component, not several")
                check(parent?.parentChain != nil,
                      "…while the folded-away parents are there to be drawn "
                          + "(\(parent?.parentChain ?? "none"))")
                check(rowHelp(sourcePath)
                          == FolderSidebar.countDescription(underSource.count),
                      "…and the row counts the \(underSource.count) photo(s) under it "
                          + "(got \(rowHelp(sourcePath)))")
                // 18b. The whole path is still reachable: as the row's
                //      accessibility value and as its tooltip.
                check(rowValue(sourcePath) == sourcePath,
                      "…with the full path as the row's value "
                          + "(got \(rowValue(sourcePath)))")
                check(rowTooltip(sourcePath) == sourcePath,
                      "…and as its tooltip (got \(rowTooltip(sourcePath)))")
                check(rowLabel(subPath) == folderSubfolderName
                          && rowHelp(subPath) == FolderSidebar.countDescription(1),
                      "the subfolder's row reads \(folderSubfolderName), 1 photo "
                          + "(got \(rowLabel(subPath)), \(rowHelp(subPath)))")
                check(app.folders.node(at: subPath)?.parentChain == nil,
                      "…and it folds nothing away, so it is a single line")
                check(rowValue(subPath) == subPath,
                      "…with its own full path as its value (got \(rowValue(subPath)))")
                let volumeRow = volume.map { rowLabel($0.id) } ?? "no volume"
                check(volumeRow == volume?.leafName && volume?.parentChain == nil,
                      "a volume's row is unchanged — its name, one line "
                          + "(got \(volumeRow))")
                check(rowLabel("missing") == "Missing"
                          && rowHelp("missing") == FolderSidebar.countDescription(0),
                      "the Missing row is drawn at zero, greyed rather than absent "
                          + "(got \(rowLabel("missing")), \(rowHelp("missing")))")
                check(sidebarRows(in: window).last?.identifier
                          == FolderSidebar.rowIdentifier("missing"),
                      "…at the very bottom of the panel")
                check(clickRow(FolderSidebar.rowIdentifier(subPath), in: window),
                      "clicked the subfolder's row in the Folders panel")
            },
            {
                // 19. Selecting a folder filters the grid to it.
                check(app.folderSelection == .folder(path: subPath),
                      "the click selected that folder (\(app.folderSelection))")
                check(app.visiblePhotoIDs == [victim],
                      "…and the grid is showing the one photo in it "
                          + "(\(app.visiblePhotoIDs.count))")
                check(app.libraryCountLabel.hasPrefix("1 photo"),
                      "…and the status bar says so (\(app.libraryCountLabel))")
                check(app.visiblePhotos.map(\.id) == [victim],
                      "…and so does the cell list the grid draws")
                check(app.highlightedPhotoIDs.allSatisfy { $0 == victim },
                      "…with nothing highlighted that is no longer on screen")
                check(clickRow(FolderSidebar.rowIdentifier(sourcePath), in: window),
                      "clicked the parent folder's row")
            },
            {
                // 20. Its parent shows everything under it, subfolder included.
                check(app.folderSelection == .folder(path: sourcePath),
                      "the parent folder is selected (\(app.folderSelection))")
                check(app.visiblePhotoIDs == underSource,
                      "…and the grid is showing everything under it "
                          + "(\(app.visiblePhotoIDs.count) of \(underSource.count))")
                check(app.visiblePhotoIDs.contains(victim),
                      "…the subfolder's photo among them")
                // 21. The arrows still belong to the grid after a click in the
                //     panel — the panel is mouse-driven, as in Lightroom.
                sendKey("", modifiers: [], window: window, virtualKey: 124)   // ->
            },
            {
                afterFirstArrow = app.highlightedPhotoIDs
                check(afterFirstArrow.count == 1,
                      "the right arrow moved the grid's ring after a click in the panel "
                          + "(\(afterFirstArrow.count) highlighted)")
                sendKey("", modifiers: [], window: window, virtualKey: 124)
            },
            {
                let now = app.highlightedPhotoIDs
                check(now.count == 1 && now != afterFirstArrow,
                      "…and the next arrow moved it on again (\(now) after \(afterFirstArrow))")
                check(now.allSatisfy { app.visiblePhotoIDs.contains($0) },
                      "…without leaving the folder that is showing")
                // 22. The selected source is the module's state, not the
                //     photo's: it survives a trip to Develop, as in Lightroom.
                sendKey("d", modifiers: [], window: window, virtualKey: 2)
            },
            {
                check(app.mode == .develop, "d left the filtered grid for Develop")
                check(app.folderSelection == .folder(path: sourcePath),
                      "…without disturbing the selected folder (\(app.folderSelection))")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                check(app.mode == .library, "g came back to the grid")
                check(app.folderSelection == .folder(path: sourcePath),
                      "…with the same folder still selected (\(app.folderSelection))")
                check(app.visiblePhotoIDs == underSource,
                      "…and the same photos in it (\(app.visiblePhotoIDs.count))")
                // 23. Take the subfolder photo's last location away through the
                //     library's own API, behind the app's back, and reload.
                removeLocations(of: victim)
                app.reloadCatalog()
            },
            {
                check(app.folders.missingCount == 1,
                      "Missing counts the photo whose file the library lost "
                          + "(\(app.folders.missingCount))")
                check(app.folders.photoIDs(for: .missing) == [victim],
                      "…and it is that photo")
                check(app.folders.node(at: subPath) == nil,
                      "…and the emptied subfolder is gone from the tree")
                check(app.folders.totalCount == app.catalog.count,
                      "…while All Photographs still counts it (\(app.folders.totalCount))")
                check(rowHelp("missing") == FolderSidebar.countDescription(1),
                      "…and the panel's Missing row says so (got \(rowHelp("missing")))")
                check(sidebarRow(FolderSidebar.rowIdentifier(subPath), in: window) == nil,
                      "…and the subfolder's row is gone from the panel")
                check(clickRow(FolderSidebar.rowIdentifier("missing"), in: window),
                      "clicked the Missing row")
            },
            {
                check(app.folderSelection == .missing,
                      "Missing is selected (\(app.folderSelection))")
                check(app.visiblePhotoIDs == [victim],
                      "…and the grid lists that photo alone (\(app.visiblePhotoIDs.count))")
                check(app.libraryCountLabel.hasPrefix("1 photo"),
                      "…and the status bar says one photo (\(app.libraryCountLabel))")
                check(app.visiblePhotos.first?.locations.isEmpty == true,
                      "…and it is the photo with no file")
                // 23a. The loupe on a photo whose file the library has lost.
                //      There is nothing to draw, so it says so rather than
                //      showing an empty frame.
                check(clickCell(cellID(victim)), "clicked the missing photo's cell")
                sendKey("e", modifiers: [], window: window, virtualKey: 14)
            },
            {
                check(app.libraryViewMode == .loupe && app.loupePhotoID == victim,
                      "e opened the loupe on the photo with no file")
                check(app.loupeTexture == nil, "…and there is no picture in it")
                check(findLoupeCanvas() == nil,
                      "…and no canvas either, so the backdrop is not mistakable "
                          + "for a black photo")
                check(app.loupeMessage != nil,
                      "…so it says what is wrong instead "
                          + "(\(app.loupeMessage ?? "nothing"))")
                check(probeView("loupe-missing") != nil,
                      "…and the placeholder is drawn in the window")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                check(app.libraryViewMode == .grid, "g came back to the grid")
                check(clickRow(FolderSidebar.rowIdentifier("all"), in: window),
                      "clicked All Photographs")
            },
            {
                check(app.folderSelection == .all,
                      "All Photographs is selected again (\(app.folderSelection))")
                check(app.visiblePhotoIDs.count == app.catalog.count,
                      "…and the grid is showing the whole catalog "
                          + "(\(app.visiblePhotoIDs.count) of \(app.catalog.count))")
                check(app.libraryCountLabel.hasPrefix("\(app.catalog.count) photos"),
                      "…and the status bar counts them all (\(app.libraryCountLabel))")
                // 24. A disclosure triangle: closing the volume takes its
                //     subtree out of the panel, opening it puts it back.
                app.browser.setExpanded(volume?.id ?? "/", false)
            },
            {
                check(sidebarRow(FolderSidebar.rowIdentifier(sourcePath), in: window) == nil,
                      "closing the volume's triangle took its folders out of the panel")
                check(sidebarRow(FolderSidebar.rowIdentifier(volume?.id ?? "/"),
                                 in: window) != nil,
                      "…while the volume's own row stayed")
                app.browser.setExpanded(volume?.id ?? "/", true)
            },
            {
                check(sidebarRow(FolderSidebar.rowIdentifier(sourcePath), in: window) != nil,
                      "opening it again brought them back")
                // 25. The panel itself hides and shows: macOS's own shortcut
                //     from the keyboard, the standard title-bar button with the
                //     mouse. The keystroke goes through the *queue*, because
                //     `KeyRouter` is what claims Opt-Cmd-S and a local monitor
                //     only ever sees a dequeued event.
                let item = findMenuItemDeep(titled: "Show/Hide Folders")
                check(item?.keyEquivalent == "s"
                          && item?.keyEquivalentModifierMask == [.command, .option],
                      "View › Show/Hide Folders carries Opt-Cmd-S "
                          + "(got '\(item?.keyEquivalent ?? "missing")')")
                check(item?.isEnabled == true, "…and is enabled")
                sendKey("s", modifiers: [.command, .option], window: window,
                        virtualKey: 1, viaQueue: true)
            },
            {
                check(!app.isFolderSidebarVisible, "Opt-Cmd-S hid the Folders panel")
                check(sidebarWidth(in: window) == 0,
                      "…and it is off the window (\(sidebarWidth(in: window)) pt wide)")
                check(app.visiblePhotoIDs.count == app.catalog.count,
                      "…without changing what the grid shows "
                          + "(\(app.visiblePhotoIDs.count) of \(app.catalog.count))")
                // The standard sidebar button `NavigationSplitView` puts in
                // the title bar: that it is there, and that clicking it shows
                // the panel again.
                let toggle = window.toolbar?.items.first {
                    $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar")
                }
                check(toggle != nil, "the window has the standard sidebar button")
                check(toggle?.label == "Show Sidebar",
                      "…reading 'Show Sidebar' while the panel is hidden "
                          + "(got '\(toggle?.label ?? "no item")')")
                sendKey("s", modifiers: [.command, .option], window: window,
                        virtualKey: 1, viaQueue: true)
            },
            {
                check(app.isFolderSidebarVisible, "Opt-Cmd-S brought the panel back")
                check(window.toolbar?.items.first {
                    $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar")
                }?.label == "Hide Sidebar",
                      "…and the standard button reads 'Hide Sidebar' again")
                check(sidebarWidth(in: window) > 0,
                      "…to its own width again (\(sidebarWidth(in: window)) pt)")
                check(sidebarRows(in: window).map(\.identifier) == expectedRowIdentifiers(),
                      "…with the same rows on it (\(sidebarRows(in: window).count))")
            },
        ]

        // Not `runSteps`: a step here has to wait for the *panel* to stop
        // moving as well as for the renderer to go quiet. A list whose rows are
        // still animating into place after a catalog reload hands out row
        // rectangles that are about to be wrong, and a click aimed at one of
        // them lands on the row above or below (measured — the Missing row,
        // right after the subfolder disappeared from under it, one run in two).
        func run(_ remaining: ArraySlice<() -> Void>) {
            guard let first = remaining.first else {
                try? FileManager.default.createDirectory(at: outputDirectory,
                                                         withIntermediateDirectories: true)
                writeScreenshot(of: window, named: "selftest-library.png")
                runWindowChecks(app: app, window: window, check: check, failures: failures)
                return
            }
            first()
            settle(app) {
                waitForStablePanel(window) { run(remaining.dropFirst()) }
            }
        }
        run(steps[...])
    }

    /// Polls until the Folders panel's rows have stopped moving: the same rows,
    /// at the same places, twice in a row.
    static func waitForStablePanel(_ window: NSWindow, then body: @escaping () -> Void) {
        let before = sidebarRows(in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let after = sidebarRows(in: window)
            let same = before.count == after.count
                && !zip(before, after).contains { $0.identifier != $1.identifier
                    || $0.frame != $1.frame }
            if Date() < deadline, !same {
                waitForStablePanel(window, then: body)
            } else {
                body()
            }
        }
    }

    /// One row of the Folders panel, as accessibility sees it: what a screen
    /// reader would read out, and where on screen it is.
    struct AccessibleRow {
        let identifier: String
        /// The folder itself, without the parents folded into its row.
        let label: String
        /// Its full path.
        let value: String
        /// Its count, spelled out.
        let help: String
        /// What the pointer resting on it says.
        let tooltip: String?
        /// Where the row is on screen, in screen coordinates.
        let frame: NSRect
    }

    /// The Folders panel's rows, top to bottom, as accessibility sees them.
    ///
    /// They are found as the `NSView`s the rows put behind themselves — see
    /// `FolderSidebarRow` — and read through the accessibility methods those
    /// views answer: identifier, label (the folder's name) and value (its
    /// count). The `List`'s own SwiftUI accessibility nodes are not usable
    /// here: it only builds them for a window the user can see, and this test
    /// runs with its windows below the desktop so it never interrupts anyone.
    static func sidebarRows(in window: NSWindow) -> [AccessibleRow] {
        guard let root = window.contentView else { return [] }
        var views: [NSView] = []
        func search(_ view: NSView) {
            if view is SidebarRowTargetView, view.identifier != nil { views.append(view) }
            view.subviews.forEach(search)
        }
        search(root)
        return views.compactMap { view -> AccessibleRow? in
            guard let identifier = view.identifier?.rawValue,
                  identifier.hasPrefix("folder-row-"),
                  let frame = screenFrame(of: view), frame.height > 0
            else { return nil }
            return AccessibleRow(identifier: identifier,
                                 label: view.accessibilityLabel() ?? "",
                                 value: (view.accessibilityValue() as? String) ?? "",
                                 help: view.accessibilityHelp() ?? "",
                                 tooltip: view.toolTip,
                                 frame: frame)
        }
        // Top to bottom on screen, which is the order they are drawn in.
        .sorted { $0.frame.maxY > $1.frame.maxY }
    }

    static func sidebarRow(_ identifier: String, in window: NSWindow) -> AccessibleRow? {
        sidebarRows(in: window).first { $0.identifier == identifier }
    }

    /// A click on a row of the Folders panel, with a real mouse event, exactly
    /// as the grid's cells are clicked: the row's own `NSView` takes it (and
    /// accepts first mouse), so no window has to be key and nothing has to be
    /// in front of the user's work.
    @discardableResult
    static func clickRow(_ identifier: String, in window: NSWindow) -> Bool {
        guard let row = sidebarRow(identifier, in: window) else {
            log("self-test: no row \(identifier) in the Folders panel")
            return false
        }
        let point = window.convertPoint(fromScreen: CGPoint(x: row.frame.midX,
                                                            y: row.frame.midY))
        clickCounter += 1
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: clickCounter, clickCount: 1, pressure: 1)
            else { return false }
            window.sendEvent(event)
        }
        return true
    }

    /// How wide the Folders panel is on screen right now — zero when it is
    /// collapsed. The list's views stay in the hierarchy while the panel is
    /// hidden, so "are there rows" is not the question; "is any of it visible"
    /// is.
    static func sidebarWidth(in window: NSWindow) -> Double {
        guard let scroll = sidebarTable(in: window)?.enclosingScrollView,
              !scroll.isHiddenOrHasHiddenAncestor
        else { return 0 }
        return Double(scroll.convert(scroll.bounds, to: nil).width)
    }

    /// The panel's list. The Library window has exactly one table view in it.
    static func sidebarTable(in window: NSWindow) -> NSTableView? {
        func search(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return window.contentView.flatMap(search)
    }
}
