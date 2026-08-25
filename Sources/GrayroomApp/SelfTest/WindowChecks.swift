import AppKit
import GrayroomLibrary
import GrayroomUI
import ImageIO

/// The rest of the window, in the `library` self-test: the activity centre,
/// the window's own chrome, the Photo menu, and File › Open… / Export….
extension SelfTest {
    // MARK: - The window itself

    /// Everything in the window that is neither the grid nor the Folders panel:
    /// the activity centre, the window's chrome, the colour-label menu, the
    /// Open panel's aftermath, the export sheet — and, running through all of
    /// it, the rule that a background task must not move anything.
    static func runWindowChecks(app: AppModel, window: NSWindow,
                                check: @escaping (Bool, String) -> Void,
                                failures: @escaping () -> [String]) {
        phase("window")
        var idleSlot: NSRect?
        var idleWindowFrame = window.frame
        var taskID: TaskCenter.BackgroundTask.ID?

        let steps: [() -> Void] = [
            {
                // 26. The icon the Dock tile shows. There is no `.app` bundle
                //     when SwiftPM builds a bare Mach-O, so the app ships the
                //     icon as a resource and hands it to `NSApp` itself; the
                //     failure mode is silent (a generic tile), so the check is
                //     that the resource is there, that it decodes, and that it
                //     is not the generic one.
                let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
                check(url != nil, "AppIcon.icns ships in the app's resource bundle")
                let icon = url.flatMap { NSImage(contentsOf: $0) }
                check(icon != nil, "…and decodes to an image")
                check((icon?.size.width ?? 0) > 0 && (icon?.size.height ?? 0) > 0,
                      "…with a size (\(icon.map { "\($0.size)" } ?? "none"))")
                check((icon?.representations.count ?? 0) > 1,
                      "…at several sizes, as an .icns is "
                          + "(\(icon?.representations.count ?? 0) representations)")
                let generic = NSImage(named: NSImage.applicationIconName)
                let genericBytes = generic?.tiffRepresentation?.count ?? 0
                let iconBytes = icon?.tiffRepresentation?.count ?? 0
                check(iconBytes > 0 && iconBytes != genericBytes,
                      "…and it is not the generic application icon "
                          + "(\(iconBytes) bytes vs \(genericBytes))")
                // The assignment itself, on the object the delegate assigns to.
                // A self-test is an accessory app and has no Dock tile, so this
                // is the closest the harness can get to the tile.
                if let icon {
                    NSApp.applicationIconImage = icon
                    let taken = NSApp.applicationIconImage
                    check((taken?.size.width ?? 0) > 0,
                          "NSApp took the icon (\(taken?.size.width ?? 0) pt)")
                    check(taken?.size == icon.size,
                          "…at the size it came in at (\(taken.map { "\($0.size)" } ?? "none"))")
                    check((taken?.tiffRepresentation?.count ?? 0) != genericBytes,
                          "…and the app is not left on the generic icon")
                }

                // 27. The title bar is a plain one: traffic lights, no title
                //     text, and nothing of the app's own in it. The window
                //     keeps its `title` string all the same —
                //     `applicationDidFinishLaunching` and `KeyRouter` find the
                //     window by it, and accessibility reads it out.
                check(window.titleVisibility == .hidden,
                      "the window's title text is hidden "
                          + "(\(window.titleVisibility == .hidden ? "hidden" : "visible"))")
                check(window.title.hasPrefix("Grayroom"),
                      "…while the window keeps its title string, which is what "
                          + "the delegate and accessibility find it by "
                          + "(got '\(window.title)')")
                check(window.standardWindowButton(.closeButton)?.isHidden == false,
                      "…and the traffic lights are on the bar")
                // Import, the modules, the tools, Before, the zoom buttons and
                // Export are menu commands and keys now; nothing of the app's
                // sits in the title bar duplicating them.
                for name in ["toolbar-import", "toolbar-open", "toolbar-export", "mode-picker"] {
                    check(probeView(name) == nil, "there is no '\(name)' in the title bar")
                }

                // 28. Nothing is running, so the activity centre draws nothing —
                //     but its slot is there all the same.
                check(app.tasks.tasks.isEmpty,
                      "the activity centre is empty to start with "
                          + "(\(app.tasks.tasks.map(\.title)))")
                check(probeView(ActivityIndicator.probeName) == nil,
                      "…so there is no indicator in the status bar")
                idleSlot = controlFrame(named: "activity-slot")
                idleWindowFrame = window.frame
                check(idleSlot != nil,
                      "the status bar's activity slot is on screen "
                          + "(\(idleSlot.map { "\($0)" } ?? "gone"))")
                // 29. Start something. The indicator must appear *into* the
                //     slot without moving anything around it.
                taskID = app.tasks.begin(title: "Self-test task", total: 10, cancellable: true)
                app.tasks.update(taskID!, completed: 3, detail: "a file")
            },
            {
                check(probeView(ActivityIndicator.probeName) != nil,
                      "a running task put the indicator in the status bar")
                check(controlFrame(named: "activity-slot") == idleSlot,
                      "…without moving its slot: idle \(idleSlot.map { "\($0)" } ?? "gone") "
                          + "vs busy \(controlFrame(named: "activity-slot").map { "\($0)" } ?? "gone")")
                check(window.frame == idleWindowFrame,
                      "…and without resizing the window "
                          + "(\(window.frame) vs \(idleWindowFrame))")
                writeScreenshot(of: window, named: "selftest-activity-busy.png")
                // 30. The popover: every task in it, each with a live ⓧ.
                check(clickControl(named: ActivityIndicator.probeName),
                      "clicked the activity indicator")
            },
        ]

        runSteps(steps, model: app) {
            runActivityPopoverChecks(app: app, window: window, taskID: taskID,
                                     idleSlot: idleSlot,
                                     idleWindowFrame: idleWindowFrame,
                                     check: check, failures: failures)
        }
    }

    /// The activity centre's popover, and what happens after the task it lists
    /// is cancelled and finished.
    static func runActivityPopoverChecks(app: AppModel, window: NSWindow,
                                         taskID: TaskCenter.BackgroundTask.ID?,
                                         idleSlot: NSRect?,
                                         idleWindowFrame: NSRect,
                                         check: @escaping (Bool, String) -> Void,
                                         failures: @escaping () -> [String]) {
        guard let taskID, let task = app.tasks.task(taskID) else {
            check(false, "a task to drive the activity centre with")
            finishLibrary(failures())
        }
        let rowProbe = ActivityList.rowProbeName(task)
        let cancelProbe = ActivityList.cancelProbeName(task)

        let steps: [() -> Void] = [
            {
                check(!views(identified: ControlProbe.identifier(rowProbe)).isEmpty,
                      "the popover lists the running task")
                // A popover is a window of its own, and a self-test's windows
                // stay below the desktop — including the ones it opens by
                // clicking something.
                check(everyWindowIsOutOfTheWay(),
                      "…in a window that is still out of the user's way "
                          + "(\(NSApp.windows.map { "\($0.title):\($0.level.rawValue)" }))")
                check(probeView(cancelProbe) != nil,
                      "…with a cancel button on its row")
                check(clickControl(named: cancelProbe), "pressed the task's ⓧ")
            },
            {
                check(app.tasks.task(taskID)?.isCancelled == true,
                      "…and the task is cancelled")
                check(app.tasks.isCancelled(taskID),
                      "…as the worker's own poll sees it, not just the UI's copy")
                check(app.tasks.tasks.contains { $0.id == taskID },
                      "…while the row stays until the worker calls finish, "
                          + "so the cancellation is visibly being acted on")
                // 31. The worker notices and finishes: the indicator goes away
                //     and, again, nothing moves.
                app.tasks.finish(taskID)
            },
            {
                check(app.tasks.tasks.isEmpty,
                      "the finished task left the activity centre "
                          + "(\(app.tasks.tasks.map(\.title)))")
                check(probeView(ActivityIndicator.probeName) == nil,
                      "…and the indicator is gone from the status bar")
                check(probeView(ActivityIndicator.slotProbeName) != nil,
                      "…while its slot stayed")
                check(controlFrame(named: "activity-slot") == idleSlot,
                      "…and nothing moved back, because nothing had moved")
                check(window.frame == idleWindowFrame,
                      "…and the window is the size it was (\(window.frame))")
                writeScreenshot(of: window, named: "selftest-activity-idle.png")
            },
        ]
        runSteps(steps, model: app) {
            runModuleAndMenuChecks(app: app, window: window, check: check, failures: failures)
        }
    }

    // MARK: - The modules, the menus and the sheet

    /// The status bar across a `d`/`g` round trip, the develop view's own
    /// readouts, the Photo menu's items, the Open panel's aftermath and the
    /// export sheet.
    static func runModuleAndMenuChecks(app: AppModel, window: NSWindow,
                                       check: @escaping (Bool, String) -> Void,
                                       failures: @escaping () -> [String]) {
        phase("modules and menus")
        let ids = app.catalog.ids
        guard ids.count >= 2 else {
            check(false, "two photos to label from the menu")
            finishLibrary(failures())
        }

        // The status bar's own rectangle, taken from the one thing that is in
        // it in both modules. The two modules fill the bar differently — the
        // grid's count and size slider, develop's filename and camera — and if
        // that changed its height the whole window below the title bar would
        // shift by a couple of points on every `g`/`d`.
        var activitySlotInLibrary: NSRect = .zero

        let steps: [() -> Void] = [
            {
                // 32. The status bar across a module switch: each module fills
                //     its own end of the one bar, and the bar itself must not
                //     move a point.
                activitySlotInLibrary = controlFrame(named: "activity-slot") ?? .zero
                // The grid's own furniture is in the window's one status bar,
                // not in a second strip above it.
                check(controlFrame(named: "library-count") != nil,
                      "the library's photo count is in the status bar")
                check(!isInTitleBar(probeView("library-count")),
                      "…in the window's content, not up in the title bar")
                if let count = controlFrame(named: "library-count") {
                    check(abs(count.midY - activitySlotInLibrary.midY) < 6,
                          "…on the same line as the activity indicator "
                              + "(count at \(count.midY), slot at "
                              + "\(activitySlotInLibrary.midY))")
                    check(count.minX < activitySlotInLibrary.minX,
                          "…at the leading end of it")
                }
                let sizeSlider = controlFrame(named: "library-thumbnail-size")
                check(sizeSlider != nil, "…and so is the thumbnail-size slider")
                if let sizeSlider {
                    check(abs(sizeSlider.midY - activitySlotInLibrary.midY) < 6,
                          "…on that same line (\(sizeSlider.midY) vs "
                              + "\(activitySlotInLibrary.midY))")
                    check(sizeSlider.minX > activitySlotInLibrary.minX,
                          "…at the trailing end")
                }
                // A photo whose file is still there: `showDevelop` refuses a
                // frame the library has lost, and one of these has had its
                // location taken away on purpose a few steps back.
                let openable = app.visiblePhotos.first { $0.firstLocation != nil }
                check(openable != nil, "a photo with a file to develop")
                if let openable { _ = clickCell(cellID(openable.id)) }
                sendKey("d", modifiers: [], window: window, virtualKey: 2)
            },
            {
                check(app.mode == .develop, "d switched to Develop (got \(app.mode.rawValue))")
                check(findCanvas() != nil, "…and the canvas is in the window")
                // The status bar swaps its ends over — and does not move.
                check(controlFrame(named: "library-count") == nil,
                      "the grid's photo count left the status bar with the grid")
                check(controlFrame(named: "library-thumbnail-size") == nil,
                      "…and so did the thumbnail-size slider")
                let slotInDevelop = controlFrame(named: "activity-slot")
                check(slotInDevelop.map { sameLine($0, activitySlotInLibrary) } == true,
                      "…while the status bar is on exactly the same line, so the "
                          + "module switch moves nothing vertically "
                          + "(\(slotInDevelop.map { "\($0)" } ?? "gone") vs "
                          + "\(activitySlotInLibrary))")
                // 32a. The zoom readout the title bar used to carry, now at the
                //      develop end of the same bar the loupe puts it in.
                let zoom = controlFrame(named: "develop-zoom")
                check(zoom != nil, "the develop view's zoom % is in the status bar")
                check(!isInTitleBar(probeView("develop-zoom")),
                      "…in the window's content, not up in the title bar")
                if let zoom, let lens = controlFrame(named: "develop-camera") {
                    check(abs(zoom.midY - activitySlotInLibrary.midY) < 6,
                          "…on the bar's own line (\(zoom.midY) vs "
                              + "\(activitySlotInLibrary.midY))")
                    check(zoom.minX > lens.minX,
                          "…after the camera and lens (\(zoom.minX) vs \(lens.minX))")
                }
                zoomBefore = app.zoomPercent
                // The other half of the pair the library screenshots show: the
                // same window, the same status bar, the other module.
                writeScreenshot(of: window, named: "selftest-develop.png")
                check(sendMenuItem(titled: "Zoom to 100%"), "sent Image › Zoom to 100%")
            },
            {
                check(app.zoomPercent != zoomBefore,
                      "Image › Zoom to 100% zoomed (\(app.zoomPercent) %, was "
                          + "\(zoomBefore) %)")
                check(controlFrame(named: "develop-zoom") != nil,
                      "…and the readout is still in the bar")
                check(sendMenuItem(titled: "Zoom to Fit"), "sent Image › Zoom to Fit")
            },
            {
                // 32b. Before/After: the View menu's item latches it, and `\`
                //      — Lightroom's key — holds it. `KeyRouter` takes both
                //      halves of that key, so the press and the release are
                //      posted separately.
                check(abs(app.zoomPercent - zoomBefore) < 0.5,
                      "Image › Zoom to Fit put it back (\(app.zoomPercent) %)")
                let item = findMenuItemDeep(titled: "Before / After")
                check(item?.keyEquivalent == "\\",
                      "View › Before / After carries \\ "
                          + "(got '\(item?.keyEquivalent ?? "missing")')")
                check(item?.keyEquivalentModifierMask.isEmpty == true,
                      "…bare, as in Lightroom")
                check(!app.showBeforeAfter, "…and we are looking at the edit")
                check(sendMenuItem(titled: "Before / After"), "sent View › Before / After")
            },
            {
                check(app.showBeforeAfter, "…which showed the unedited decode")
                check(sendMenuItem(titled: "Before / After"), "sent it again")
            },
            {
                check(!app.showBeforeAfter, "…and it toggled back to the edit")
                sendKeyHalf(virtualKey: 42, down: true)
            },
            {
                check(app.showBeforeAfter, "holding \\ shows the unedited decode")
                sendKeyHalf(virtualKey: 42, down: false)
            },
            {
                check(!app.showBeforeAfter, "…and letting go comes back to the edit")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                check(app.mode == .library, "g came back to Library (got \(app.mode.rawValue))")
                check(findCanvas() == nil, "…and the canvas is gone")
                check(controlFrame(named: "develop-zoom") == nil,
                      "…and the zoom readout left the status bar with it")
                check(controlFrame(named: "activity-slot")
                          .map { sameLine($0, activitySlotInLibrary) } == true,
                      "…and so is the status bar, after the round trip "
                          + "(\(controlFrame(named: "activity-slot").map { "\($0)" } ?? "gone"))")
                check(controlFrame(named: "library-thumbnail-size") != nil,
                      "…with the grid's size slider back in it")
                // 33. Photo › Set Color Label, sent the way the menu sends it.
                //     Purple has no key equivalent — Lightroom does not give it
                //     one — so the menu item is the *only* way to reach it, and
                //     nothing else in this test would notice if it stopped
                //     working.
                _ = clickCell(cellID(ids[0]))
                _ = clickCell(cellID(ids[1]), modifiers: .shift)
                check(app.highlightedPhotoIDs.count >= 2,
                      "two photos highlighted for the menu "
                          + "(\(app.highlightedPhotoIDs.count))")
                check(sendMenuItem(titled: "Purple"), "sent Photo › Set Color Label › Purple")
            },
            {
                let labelled = app.highlightedPhotoIDs
                check(labelled.allSatisfy { app.catalog.photo(id: $0)?.color == .purple },
                      "…and the menu item labelled the whole selection purple")
                check(labelled.allSatisfy { storedColor($0) == .purple },
                      "…in the database too (got "
                          + "\(labelled.map { describe(storedColor($0)) }))")
                // 34. The status bar's line, which is the only feedback a
                //     colour label gives outside the grid.
                check(app.statusMessage == "Labelled \(labelled.count) photos purple",
                      "…and the status bar says what happened "
                          + "(got \(app.statusMessage ?? "nil"))")
                check(sendMenuItem(titled: "None"), "sent Photo › Set Color Label › None")
            },
            {
                let cleared = app.highlightedPhotoIDs
                check(cleared.allSatisfy { app.catalog.photo(id: $0)?.color == .unlabeled },
                      "…and None cleared them")
                check(cleared.allSatisfy { storedColor($0) == .unlabeled },
                      "…in the database too")
                check(app.statusMessage?.hasPrefix("Cleared the colour label on") == true,
                      "…and the status bar says so (got \(app.statusMessage ?? "nil"))")
                // 35. The grid's size slider, from the keyboard. `+`/`-` are
                //     `KeyRouter`'s, not the menu's, so they go through the
                //     queue like ⌥⌘S does.
                sizeBefore = app.libraryThumbnailSize
                cellWidthBefore = libraryCellWidth(app)
                check(cellWidthBefore > 0, "a cell to measure (\(cellWidthBefore) pt)")
                sendKey("=", modifiers: [], window: window, virtualKey: 24, viaQueue: true)
            },
            {
                check(app.libraryThumbnailSize > sizeBefore,
                      "+ made the grid's thumbnails bigger "
                          + "(\(app.libraryThumbnailSize), was \(sizeBefore))")
                check(libraryCellWidth(app) > cellWidthBefore,
                      "…and the cells on screen grew with it "
                          + "(\(libraryCellWidth(app)) pt, was \(cellWidthBefore) pt)")
                sendKey("-", modifiers: [], window: window, virtualKey: 27, viaQueue: true)
            },
            {
                check(app.libraryThumbnailSize == sizeBefore,
                      "- put it back (\(app.libraryThumbnailSize))")
                check(libraryCellWidth(app) == cellWidthBefore,
                      "…and so did the cells (\(libraryCellWidth(app)) pt)")
                // …and the same size, dragged. The slider moved out of the
                // grid's own strip and into the status bar; this is what says
                // it is still wired to the model there.
                check(setSliderFraction(named: "library-thumbnail-size", to: 1),
                      "dragged the status bar's size slider to its far end")
            },
            {
                check(abs(app.libraryThumbnailSize - ImportModel.maximumThumbnailSize) < 0.5,
                      "…and the grid took the new size "
                          + "(\(app.libraryThumbnailSize), max is "
                          + "\(ImportModel.maximumThumbnailSize))")
                check(libraryCellWidth(app) > cellWidthBefore,
                      "…and the cells on screen grew with it "
                          + "(\(libraryCellWidth(app)) pt, was \(cellWidthBefore) pt)")
                // Back to where the rest of the run found it, so the
                // screenshots that follow are of the default grid.
                let range = ImportModel.maximumThumbnailSize - ImportModel.minimumThumbnailSize
                _ = setSliderFraction(named: "library-thumbnail-size",
                                      to: (sizeBefore - ImportModel.minimumThumbnailSize) / range)
            },
        ]

        runSteps(steps, model: app) {
            runOpenAndExportChecks(app: app, window: window, check: check, failures: failures)
        }
    }

    static var sizeBefore = 0.0
    static var cellWidthBefore = 0.0
    static var zoomBefore = 0.0

    /// Whether two rectangles sit on the same line of the window.
    ///
    /// Only the vertical half: the status bar's contents slide left and right
    /// as the status message and the module's own end-pieces change width, and
    /// that is what the bar is for. What must never move is the *line* — a bar
    /// that grew or shrank would push everything above it.
    static func sameLine(_ a: NSRect, _ b: NSRect) -> Bool {
        a.minY == b.minY && a.height == b.height
    }

    /// How wide the grid is drawing its cells right now.
    static func libraryCellWidth(_ app: AppModel) -> Double {
        app.visiblePhotoIDs.first.flatMap { cellView(cellID($0)) }
            .flatMap(screenFrame(of:)).map { Double($0.width) } ?? 0
    }

    /// Sends a menu item's action the way AppKit does when it is picked.
    static func sendMenuItem(titled title: String) -> Bool {
        guard let item = findMenuItemDeep(titled: title), let action = item.action,
              item.isEnabled else {
            log("self-test: no live menu item '\(title)'")
            return false
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: - Open and Export

    /// File › Open… and File › Export…: the two commands whose middle is an
    /// `NSPanel` that runs modally and cannot be answered from inside this
    /// process. Both are split in `AppModel` so the panel's *result* can be
    /// supplied here and everything after it is the production path — the same
    /// arrangement the Import window's source panel has.
    static func runOpenAndExportChecks(app: AppModel, window: NSWindow,
                                       check: @escaping (Bool, String) -> Void,
                                       failures: @escaping () -> [String]) {
        phase("open and export")
        // The synthetic JPEG: the export renders at full resolution from a
        // fresh decode, and 64x48 keeps that a fraction of a second rather
        // than the two minutes a hundred-megapixel frame costs — most of it
        // in the PNG encoder, which is not what this checks.
        //
        // Addressed by *path*, not through the catalog: the Folders checks
        // take this photo's location away on purpose, and File › Open… does
        // not care — it is a file the user picked, which the library then
        // recognises by its hash. Any photo on disk stands in when there is no
        // staged source (a run pointed at someone else's folder).
        let staged = stagedSource?
            .appendingPathComponent(folderSubfolderName, isDirectory: true)
            .appendingPathComponent("standard.jpg")
        let photos = app.catalog.photos.filter { $0.firstLocation != nil }
        let fallback = photos.min { $0.byteSize < $1.byteSize }?.firstLocation
            .map { URL(fileURLWithPath: $0) }
        guard let url = staged.flatMap({
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }) ?? fallback else {
            check(false, "a photo on disk to open")
            finishLibrary(failures())
        }
        log("library self-test: exporting \(url.lastPathComponent)")
        let exported = outputDirectory.appendingPathComponent("selftest-export.png")
        try? FileManager.default.removeItem(at: exported)

        let steps: [() -> Void] = [
            {
                // 36. Open… — choosing a file by hand is a request to develop
                //     it, whatever module you were in.
                check(app.mode == .library, "we are in the library to start with")
                // Not *sent*: the item runs an `NSOpenPanel` modally, which
                // nothing inside this process can answer. What is checked is
                // that it is there and live, and then the work it does once the
                // panel has answered.
                let item = findMenuItemDeep(titled: "Open…")
                check(item?.isEnabled == true, "File › Open… is live")
                check(item?.keyEquivalent == "o" && item?.keyEquivalentModifierMask == [.command],
                      "File › Open… carries ⌘O (got '\(item?.keyEquivalent ?? "missing")')")
                app.openChosenFile(url)
            },
            {
                check(app.mode == .develop,
                      "opening a file went to Develop (got \(app.mode.rawValue))")
                check(app.imageURL?.path == url.path,
                      "…on the file that was chosen (\(app.imageURL?.lastPathComponent ?? "none"))")
            },
            {
                check(app.previewSize != .zero,
                      "…and it decoded (\(app.previewSize))")
                let export = findMenuItemDeep(titled: "Export…")
                check(export?.isEnabled == true, "File › Export… is live with an image open")
                check(export?.keyEquivalent == "e"
                          && export?.keyEquivalentModifierMask == [.command],
                      "…carrying ⌘E (got '\(export?.keyEquivalent ?? "missing")')")
                // 37. ⌘E, as a real keystroke through the menu's key
                //     equivalent, opens the export sheet.
                sendKey("e", modifiers: .command, window: window, virtualKey: 14)
            },
            {
                check(app.isExportSheetPresented, "⌘E asked for the export sheet")
                check(window.attachedSheet != nil,
                      "…and AppKit put a real sheet on the window")
                check(!KeyRouter.acceptsKeys(window),
                      "…and the bare-key router stands aside while it is up")
                check(control(named: "export-format") is NSPopUpButton,
                      "the sheet has a format pop-up")
                check(isEnabled(named: "export-choose") == true,
                      "…and a live Choose File… button")
                check(role(named: "export-cancel") == .button, "…and a Cancel button")
                check(selectPopUpItem(named: "export-format", titled: "PNG (8-bit)"),
                      "picked PNG (8-bit) out of the format pop-up")
            },
            {
                check(app.exportFormat == .png,
                      "the pop-up set the format (got \(app.exportFormat))")
                // 38. Esc closes the sheet, which is the Cancel button's
                //     `.cancelAction` and the only way out that is not a save
                //     panel.
                sendKey("escape", modifiers: [], window: window, virtualKey: 53)
            },
            {
                check(!app.isExportSheetPresented,
                      "Esc dismissed the export sheet, so Cancel is its .cancelAction")
                check(window.attachedSheet == nil, "…and the sheet is off the window")
                check(KeyRouter.acceptsKeys(window), "…and the keys are the router's again")
                // 39. And now the export itself. `runExport` runs an
                //     `NSSavePanel` modally; `export(to:)` is everything after
                //     it answers.
                app.presentExportSheet()
            },
            {
                check(app.isExportSheetPresented, "the Export button's sheet came up")
                // 40. Return runs Choose File…, which is `.defaultAction`. The
                //     assertion is the save panel it opens, because the binding
                //     itself is not readable any more (see `AXElement`).
                check(returnOpensTheSavePanel(in: window),
                      "Return opened the save panel, so Choose File… is the "
                          + "sheet's default button")
                check(!app.isExportSheetPresented, "…and running it took the sheet down")
                app.export(to: exported)
                check(app.tasks.tasks.contains { $0.title.hasPrefix("Exporting ") },
                      "the export registered a task in the activity centre "
                          + "(\(app.tasks.tasks.map(\.title)))")
            },
        ]

        runSteps(steps, model: app) {
            waitForExport(app) {
                let attributes = try? FileManager.default
                    .attributesOfItem(atPath: exported.path)
                let size = (attributes?[.size] as? Int) ?? 0
                check(FileManager.default.fileExists(atPath: exported.path),
                      "the export wrote \(exported.lastPathComponent)")
                check(size > 1024, "…and it is a real file (\(size) bytes)")
                let decoded = CGImageSourceCreateWithURL(exported as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                check(decoded != nil, "…that decodes as an image")
                check(Double(decoded?.width ?? 0) == app.fullSize.width
                          && Double(decoded?.height ?? 0) == app.fullSize.height,
                      "…at the file's full resolution "
                          + "(\(decoded?.width ?? 0)x\(decoded?.height ?? 0) vs "
                          + "\(app.fullSize))")
                check(app.statusMessage?.hasPrefix("Exported ") == true,
                      "…and the status bar says so (got \(app.statusMessage ?? "nil"))")
                check(app.errorMessage == nil,
                      "…with no error on the bar (\(app.errorMessage ?? "none"))")
                check(!app.tasks.tasks.contains { $0.title.hasPrefix("Exporting ") },
                      "…and the export's task went away")
                runBatchExportChecks(app: app, window: window, check: check, failures: failures)
            }
        }
    }

    /// Presses Return on the export sheet and answers whether that opened the
    /// save panel — the observable half of `.keyboardShortcut(.defaultAction)`.
    ///
    /// There is no readable half left. A SwiftUI `Button` has no `NSButton` and
    /// so no `keyEquivalent`, and the sheet's window answers `nil` for
    /// `defaultButtonCell`, `accessibilityDefaultButton()` and
    /// `accessibilityCancelButton()` (measured; see `AXElement`). So the check
    /// is the behaviour instead, which asserts more than the binding did: the
    /// key really does run Choose File…, whose `NSSavePanel` comes up.
    ///
    /// The panel is aborted from a run-loop timer in `.modalPanel` mode.
    /// `runModal` blocks inside `sendKey` and starves the main queue, so a
    /// dispatched block never runs — measured, the run hung until its deadline.
    static func returnOpensTheSavePanel(in window: NSWindow) -> Bool {
        var opened = false
        let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
            guard NSApp.modalWindow is NSSavePanel else { return }
            opened = true
            NSApp.abortModal()
            timer.invalidate()
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        sendKey("\r", modifiers: [], window: window, virtualKey: 36)
        timer.invalidate()
        return opened
    }

    static func waitForExport(_ app: AppModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if Date() < deadline, app.isExporting {
                waitForExport(app, then: body)
            } else {
                settle(app, then: body)
            }
        }
    }
}
