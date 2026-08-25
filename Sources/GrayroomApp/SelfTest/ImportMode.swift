import AppKit
import CoreGraphics
import GrayroomLibrary
import GrayroomUI

/// `GRAYROOM_SELFTEST=import` — see `SelfTest.Mode.importWindow`.
extension SelfTest {
    // MARK: - The import-window test

    static func runImportWindow() {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            log("import self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }

        dumpMenus()

        // 1. The menu item exists, is live and carries Shift-Cmd-I. A disabled
        //    item would swallow the shortcut silently (see UndoMenu.swift).
        let item = findMenuItem(titled: "Import…")
        check(item != nil, "File › Import… exists")
        check(item?.isEnabled == true, "File › Import… is enabled")
        check(item?.keyEquivalent == "i", "File › Import… key equivalent is 'i'")
        check(item?.keyEquivalentModifierMask == [.command, .shift],
              "File › Import… modifiers are Shift-Cmd")

        // 2. A photo the library knows by hash but has no location for. Its
        //    files are all gone, so offering to add one back is correct — this
        //    is the case a path check and a naive hash check both get wrong.
        let path = ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_IMPORT_DIR"] ?? "testdata"
        // A JPEG alongside the RAWs: standard formats go through a different
        // decode path, and the grid has to treat them identically.
        let source = stageSourceWithAJPEG(URL(fileURLWithPath: path, isDirectory: true))
        let orphaned = makeHashKnownButUnlocated(in: source)
        if let orphaned { log("import self-test: orphaned by hash: \(orphaned.lastPathComponent)") }
        // …and one that really *is* in the library, file and all: the case the
        // grid greys out, the case "Hide already imported" hides, and the only
        // one of the three that must arrive unchecked.
        let alreadyThere = makeAlreadyImported(in: source, avoiding: orphaned)
        if let alreadyThere {
            log("import self-test: already imported: \(alreadyThere.lastPathComponent)")
        }

        // 3. Scan the folder. The real menu item runs an NSOpenPanel first,
        //    which is modal and cannot be answered from inside the process, so
        //    the panel's *result* is supplied here and everything after it is
        //    the production path.
        let model = AppModel.shared.importModel
        let tasks = AppModel.shared.tasks
        model.setSource(source)
        log("import self-test: scanning \(source.path)")
        check(tasks.tasks.contains { $0.title.hasPrefix("Scanning ") },
              "a scan task appeared in the activity centre")
        // The indicator only exists while something is running, so this is the
        // one moment it can be photographed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // Not by title: the editor window renames itself to the open
            // file. It is simply the visible window that is not the import one.
            if let main = NSApp.windows.first(where: { $0.isVisible && $0.title != "Import" }) {
                try? FileManager.default.createDirectory(at: outputDirectory,
                                                         withIntermediateDirectories: true)
                writeScreenshot(of: main, named: "selftest-activity.png")
            }
        }

        // 4. Open the window the same way the Window menu does.
        openImportWindow()
        // Its bottom bar carries the same indicator; catch it before the scan
        // of a small folder finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if let window = importWindow(), tasks.isBusy {
                try? FileManager.default.createDirectory(at: outputDirectory,
                                                         withIntermediateDirectories: true)
                writeScreenshot(of: window, named: "selftest-import-scanning.png")
            }
        }

        waitForImportGrid(model: model) { window in
            check(window != nil, "the Import window opened")
            check(!tasks.tasks.contains { $0.title.hasPrefix("Scanning ") },
                  "the scan task went away when the scan finished")
            check(!model.isScanning, "the model stopped reporting a scan")
            if let orphaned,
               let item = model.items.first(where: { $0.url.lastPathComponent
                   == orphaned.lastPathComponent }) {
                check(item.status == .new,
                      "a hash the library knows with zero locations counts as NEW "
                          + "(got \(item.status))")
                check(item.checked, "…and it arrived checked")
            } else if orphaned != nil {
                check(false, "the orphaned file is in the grid")
            }
            check(model.items.allSatisfy { $0.status != .pending },
                  "every entry resolved out of .pending")
            if let jpeg = model.items.first(where: { $0.filename == "standard.jpg" }) {
                check(jpeg.thumbnail != nil, "the JPEG got a thumbnail")
                check(jpeg.status == .new, "the JPEG is new to the library")
                check(jpeg.checked, "the JPEG arrived checked")
                check(jpeg.captureDate != nil, "the JPEG's EXIF date was read")
            } else {
                check(false, "the JPEG is in the grid")
            }
            if ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_DUMP_VIEWS"] != nil,
               let window {
                dumpViews(in: window)
                dumpAX(in: window)
            }
            check(model.totalCount > 0, "the scan found importable images (\(model.totalCount))")
            check(model.checkedCount > 0, "new files arrived checked (\(model.checkedCount))")
            let withThumbnails = model.items.filter { $0.thumbnail != nil }.count
            check(withThumbnails == model.totalCount,
                  "every cell got a thumbnail (\(withThumbnails)/\(model.totalCount))")
            for item in model.items {
                let size = item.thumbnail.map { "\($0.width)x\($0.height)" } ?? "none"
                log("import self-test:   \(item.filename) thumb=\(size) "
                    + "date=\(item.captureDate.map(String.init(describing:)) ?? "nil") "
                    + "checked=\(item.checked) already=\(item.alreadyImported)")
            }
            // 5. The commands the keyboard and the mouse drive, run through the
            //    live model so the ring, the greying and the counter are what
            //    the screenshot shows.
            let visible = model.visibleItems
            if visible.count >= 4 {
                model.click(visible[1].url, modifiers: [])
                model.click(visible[2].url, modifiers: .shift)
                check(model.highlighted == [visible[1].url, visible[2].url],
                      "shift-click highlighted a range of two")
                let before = model.checkedCount
                model.setCheckedForHighlighted(false)
                check(model.checkedCount == before - 2, "U unchecked the highlighted range")
                model.setCheckedForHighlighted(true)
                check(model.checkedCount == before, "P rechecked it")
                model.click(visible[1].url, modifiers: [])
                model.moveHighlight(dx: 1, dy: 0, columns: 4)
                check(model.highlighted == [visible[2].url], "the right arrow moved the highlight")
                model.click(visible[1].url, modifiers: .command)
                check(model.highlighted == [visible[1].url, visible[2].url],
                      "cmd-click added to the highlight")

                // The mouse, for real. The grid puts a click catcher *behind*
                // each cell and leaves the checkbox in front of it, and the two
                // halves of that arrangement are exactly what can break: a
                // catcher that gets nothing, or a catcher that swallows the
                // checkbox.
                let target = visible[0]
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                model.click(visible[3].url, modifiers: [])
                if clickCell(cellID(target.url)) {
                    check(model.highlighted == [target.url],
                          "a real click on a cell moved the ring")
                } else {
                    check(false, "the import grid has a click target behind its cells")
                }
                model.click(visible[3].url, modifiers: [])

                // The checkbox has to stay *in front of* the catcher. That is a
                // hit-testing fact, and asking AppKit directly is the
                // deterministic way to establish it: the click below only acts
                // when the window is key, which AppKit decides and a test
                // process cannot always arrange (measured — one run in three).
                let checkbox = CGPoint(x: 11, y: 11)
                let hit = cellView(cellID(target.url)).flatMap { view -> NSView? in
                    let point = view.convert(CGPoint(x: view.bounds.minX + checkbox.x,
                                                     y: view.bounds.maxY - checkbox.y), to: nil)
                    return view.window?.contentView?.hitTest(point)
                }
                log("import self-test: the checkbox point hits "
                    + (hit.map { String(describing: type(of: $0)) } ?? "nothing"))
                check(hit != nil && !(hit is ClickCatcherView),
                      "a click at the checkbox reaches the checkbox, not the catcher behind it")

                let checkedBefore = model.checkedCount
                _ = clickCell(cellID(target.url), fromTopLeft: checkbox)
                if window?.isKeyWindow == true {
                    check(model.checkedCount != checkedBefore,
                          "a click on the checkbox ticked it (\(checkedBefore) -> "
                              + "\(model.checkedCount))")
                    check(model.highlighted == [visible[3].url],
                          "…and did not fall through to the click catcher underneath")
                    // Put it back, so the import below takes what it would have.
                    _ = clickCell(cellID(target.url), fromTopLeft: checkbox)
                    check(model.checkedCount == checkedBefore, "clicking it again put it back")
                } else {
                    // AppKit does not hand a control the click that makes its
                    // window key; it activates the window with it instead. In
                    // that state there is nothing to assert about the toggle.
                    log("import self-test: the import window is not key — skipped the "
                        + "checkbox *click* (the hit test above still ran)")
                }
            } else {
                check(false, "at least four files to drive the commands with")
            }

            if let alreadyThere,
               let item = model.items.first(where: { $0.url == alreadyThere }) {
                check(item.status == .alreadyImported,
                      "a file the library has, path and all, reads as already imported "
                          + "(got \(item.status))")
                check(!item.checked, "…and arrives unchecked, so Import does not re-add it")
            } else if alreadyThere != nil {
                check(false, "the already-imported file is in the grid")
            }

            runImportControls(model: model, window: window, alreadyImported: alreadyThere,
                              check: check) {

            // 6. Let SwiftUI draw the result of all that, then photograph it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let window {
                    try? FileManager.default.createDirectory(at: outputDirectory,
                                                             withIntermediateDirectories: true)
                    writeImportScreenshot(window: window)
                }
                // 7. Esc closes the window. This is the one bit of the window's
                //    dismissal that is not obvious: a secondary `Window` scene
                //    is closed through `@Environment(\.dismiss)`, and whether
                //    that reaches AppKit is exactly the kind of thing a unit
                //    test cannot say.
                if let window {
                    sendKey("escape", modifiers: [], window: window, virtualKey: 53)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    check(importWindow() == nil, "Esc closed the Import window")

                    // 8. Pressing Import writes to the library, so it happens
                    //    only on request — run it against a throwaway
                    //    CFFIXED_USER_HOME.
                    guard ProcessInfo.processInfo
                        .environment["GRAYROOM_SELFTEST_IMPORT_RUN"] == "1"
                    else { finishImport(failures) }
                    runTheImport(model: model, check: check, failures: { failures })
                }
            }
            }
        }
    }

    /// The Import window's own controls, driven as controls: the two bulk
    /// buttons, the "hide already imported" checkbox, the sort pop-up and the
    /// size slider.
    ///
    /// Each one is found through the `ControlProbe` behind it and pressed by
    /// target/action, and what is asserted afterwards is the **grid** — which
    /// cells are on screen, in what order, at what size — read back out of the
    /// window's own views. A button that stops being wired to the model, or a
    /// sort order the grid does not act on, fails here.
    static func runImportControls(model: ImportModel, window: NSWindow?,
                                  alreadyImported: URL?,
                                  check: @escaping (Bool, String) -> Void,
                                  then done: @escaping () -> Void) {
        guard window != nil else {
            check(false, "an Import window to drive the controls in")
            done()
            return
        }
        /// The cells the grid is actually drawing, top-left to bottom-right.
        func cellsOnScreen() -> [URL] {
            model.items.compactMap { item -> (URL, NSRect)? in
                guard let view = cellView(cellID(item.url)),
                      let frame = screenFrame(of: view), frame.height > 0 else { return nil }
                return (item.url, frame)
            }
            .sorted {
                $0.1.maxY == $1.1.maxY ? $0.1.minX < $1.1.minX : $0.1.maxY > $1.1.maxY
            }
            .map(\.0)
        }
        func cellWidth() -> Double {
            model.visibleItems.first.flatMap { cellView(cellID($0.url)) }
                .flatMap(screenFrame(of:)).map { Double($0.width) } ?? 0
        }

        var orderBefore: [URL] = []
        var widthBefore = 0.0
        var sortBefore = model.sort

        let steps: [() -> Void] = [
            {
                // "Hide already imported" starts ticked, which is what a card
                // that is half in the library should look like on arrival.
                check(model.hideImported,
                      "the window opens with already-imported files hidden")
                if let alreadyImported {
                    check(!model.visibleItems.contains { $0.url == alreadyImported },
                          "…so the file the library already has is not in the grid's model")
                    check(cellView(cellID(alreadyImported)) == nil,
                          "…and has no cell in the window")
                }
                check(model.visibleItems.count == model.totalCount - 1,
                      "…and the grid is one shorter than the scan "
                          + "(\(model.visibleItems.count) of \(model.totalCount))")
                // What the checkbox's binding writes. The checkbox itself
                // cannot be pressed from inside this process: SwiftUI's
                // controls carry no target and no action (measured — every one
                // answers `action=nil target=nil`), its bordered `Button`
                // subclass hooks `performClick` but its checkbox does not, and
                // a real mouse event only reaches a control in a **key**
                // window, which an accessory app whose windows sit below the
                // desktop cannot reliably make itself. So the write goes
                // through the binding and what is asserted is everything on
                // the other side of it — the grid, and the checkbox's own
                // state, which is the half of the wiring that *can* be read.
                check(checkboxState(named: "import-hide-imported") == .on,
                      "the checkbox is drawn ticked, as the model says "
                          + "(\(checkboxState(named: "import-hide-imported")?.rawValue ?? -99))")
                model.hideImported = false
            },
            {
                check(!model.hideImported, "clearing the filter took")
                check(checkboxState(named: "import-hide-imported") == .off,
                      "…and the checkbox followed it, so the two are bound "
                          + "(\(checkboxState(named: "import-hide-imported")?.rawValue ?? -99))")
                if let alreadyImported {
                    check(model.visibleItems.contains { $0.url == alreadyImported },
                          "…and the hidden file came back to the grid's model")
                    check(cellView(cellID(alreadyImported)) != nil,
                          "…and got a cell in the window")
                }
                check(model.visibleItems.count == model.totalCount,
                      "…so the grid now draws the whole scan "
                          + "(\(model.visibleItems.count) of \(model.totalCount))")
                check(role(named: "import-check-all") == .button,
                      "the Import window has a Check All button")
                check(clickControl(named: "import-uncheck-all"), "pressed Uncheck All")
            },
            {
                check(model.checkedCount == 0,
                      "Uncheck All cleared every tick (\(model.checkedCount))")
                // The one `.disabled` in this app that is allowed to be live,
                // because a view's body re-evaluates and a menu command's
                // builder does not (see GrayroomApp.swift).
                check(isEnabled(named: "import-run") == false,
                      "…and the Import button went dead with nothing to import")
                check(clickControl(named: "import-check-all"), "pressed Check All")
            },
            {
                check(model.checkedCount == model.totalCount,
                      "Check All ticked all \(model.totalCount) "
                          + "(\(model.checkedCount); unticked: "
                          + "\(model.items.filter { !$0.checked }.map(\.filename)))")
                check(isEnabled(named: "import-run") == true,
                      "…and the Import button came back to life")
                orderBefore = cellsOnScreen()
                check(orderBefore == model.visibleItems.map(\.url),
                      "the grid draws the model's order (\(orderBefore.count) cells)")
                sortBefore = model.sort
                let other = ImportSortOrder.allCases.first { $0 != model.sort }
                check(selectPopUpItem(named: "import-sort", titled: other?.title ?? ""),
                      "picked '\(other?.title ?? "?")' out of the Sort pop-up")
            },
            {
                check(model.sort != sortBefore,
                      "the pop-up changed the sort order (\(model.sort.title))")
                let after = cellsOnScreen()
                check(after == model.visibleItems.map(\.url),
                      "…and the grid re-laid itself out in the new order")
                check(Set(after) == Set(orderBefore),
                      "…with the same files in it (\(after.count) of \(orderBefore.count))")
                widthBefore = cellWidth()
                check(widthBefore > 0, "a cell to measure (\(widthBefore) pt)")
                check(setSliderFraction(named: "import-thumbnail-size", to: 1),
                      "dragged the size slider to its maximum")
            },
            {
                check(model.thumbnailSize == ImportModel.maximumThumbnailSize,
                      "the slider set the thumbnail size (\(model.thumbnailSize))")
                check(cellWidth() > widthBefore,
                      "…and the cells on screen got bigger "
                          + "(\(cellWidth()) pt, was \(widthBefore) pt)")
                check(setSliderFraction(named: "import-thumbnail-size", to: 0),
                      "dragged it back to its minimum")
            },
            {
                check(model.thumbnailSize == ImportModel.minimumThumbnailSize,
                      "the slider set it back (\(model.thumbnailSize))")
                check(cellWidth() < widthBefore,
                      "…and the cells shrank (\(cellWidth()) pt)")
                model.hideImported = true
            },
            {
                check(model.hideImported, "the filter went back on")
                check(checkboxState(named: "import-hide-imported") == .on,
                      "…and the checkbox with it")
                if let alreadyImported {
                    check(cellView(cellID(alreadyImported)) == nil,
                          "…and the already-imported file's cell left the window again")
                }
                check(cellsOnScreen().count == model.visibleItems.count,
                      "…while every remaining file still has a cell "
                          + "(\(cellsOnScreen().count) of \(model.visibleItems.count))")
            },
        ]
        runImportSteps(steps[...], model: model, then: done)
    }

    /// Each step, then a pause long enough for SwiftUI to re-lay the grid out —
    /// the assertions read cell rectangles, and a rectangle read while the grid
    /// is still reflowing is about to be wrong. "Stopped moving" is the same
    /// rows in the same places twice in a row, as in `waitForStablePanel`.
    static func runImportSteps(_ remaining: ArraySlice<() -> Void>, model: ImportModel,
                               then done: @escaping () -> Void) {
        guard let first = remaining.first else { done(); return }
        first()
        waitForStableGrid(model) { runImportSteps(remaining.dropFirst(), model: model, then: done) }
    }

    static func waitForStableGrid(_ model: ImportModel, polls: Int = 0,
                                  then body: @escaping () -> Void) {
        let before = cellRectangles(model)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // At least three turns even when nothing has moved yet: SwiftUI has
            // not necessarily *started* re-laying the grid out one poll after
            // the control was pressed, and "unchanged" then means "too early",
            // not "settled" (measured — the size slider's second move).
            if Date() < deadline, polls < 3 || cellRectangles(model) != before {
                waitForStableGrid(model, polls: polls + 1, then: body)
            } else {
                body()
            }
        }
    }

    static func cellRectangles(_ model: ImportModel) -> [String: NSRect] {
        var frames: [String: NSRect] = [:]
        for item in model.items {
            let id = cellID(item.url)
            if let view = cellView(id), let frame = screenFrame(of: view) { frames[id] = frame }
        }
        return frames
    }

    static func runTheImport(model: ImportModel,
                                     check: @escaping (Bool, String) -> Void,
                                     failures: @escaping () -> [String]) {
        let expected = model.checkedCount
        let app = AppModel.shared
        app.importModel.runImport()
        let importTask = app.tasks.tasks.first { $0.title == "Importing photos" }
        check(importTask != nil, "pressing Import registered an import task")
        check(importTask?.total == expected,
              "the import task's total is the checked count (\(expected))")
        waitForImportToFinish(app) { peak in
            check(peak > 0, "the import task reported progress (reached \(peak))")
            check(!app.tasks.tasks.contains { $0.title == "Importing photos" },
                  "the import task went away when it finished")
            // Not `isBusy`: the main window is the library grid now, and its
            // cells build previews. That task is expected to be there (or
            // not, if it has already drained); what must be gone is the import.
            check(!app.tasks.tasks.contains { $0.title != "Building previews" },
                  "the activity centre has nothing but previews left "
                      + "(\(app.tasks.tasks.map(\.title)))")
            // Not an exact string: the file the app reopened at launch is in
            // the library by hash already, so the summary's "already in
            // library" clause may or may not be there.
            let status = app.statusMessage ?? "nil"
            check(status.hasPrefix("Imported "),
                  "the final status reports the import (got \(status))")
            // A file the decoder cannot read at all (a camera Apple's RAW
            // support does not know yet) fails the import legitimately, and
            // `testdata` is a personal folder that grows. So the assertion is
            // not "nothing failed" but "nothing failed that could have worked".
            let undecodable = model.items.filter { !canDecode($0.url) }
            if !undecodable.isEmpty {
                log("import self-test: the decoder cannot read "
                    + undecodable.map(\.filename).joined(separator: ", "))
            }
            check(status.contains("failed") == !undecodable.isEmpty,
                  "the only import failures are the \(undecodable.count) file(s) the "
                      + "decoder cannot read (got \(status))")
            log("import self-test: imported \(expected) checked file(s) -> \(status)")
            // The editor's own decode path, on a standard image rather than a
            // RAW: dispatch reaches the window, not just the grid.
            guard let jpeg = model.items.first(where: { $0.filename == "standard.jpg" })?.url
            else {
                check(false, "a JPEG to open in the editor")
                finishImport(failures())
            }
            app.open(url: jpeg)
            waitForDecode(app) { size in
                check(size == CGSize(width: 64, height: 48),
                      "the editor decoded the JPEG (got \(size))")
                finishImport(failures())
            }
        }
    }

    /// Imports a *copy* of one of the source files and then removes the copy's
    /// location row, leaving the library with a photo it knows by hash and has
    /// no file for. Returns the original in `directory` that shares those bytes.
    static func makeHashKnownButUnlocated(in directory: URL) -> URL? {
        guard let library = try? Library.openDefault(),
              let urls = try? ImportScanner.scan(directory: directory, recursive: true),
              let original = urls.first else { return nil }
        let copy = outputDirectory.appendingPathComponent("orphan-" + original.lastPathComponent)
        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: original, to: copy)) != nil,
              let result = try? Importer(library: library).importFile(at: copy)
        else { return nil }
        for location in (try? library.locations(for: result.photoID)) ?? [] {
            if let id = location.id { _ = try? library.removeLocation(id: id) }
        }
        try? FileManager.default.removeItem(at: copy)
        try? library.close()
        return original
    }

    /// Imports one of the source files **where it is**, so the library has its
    /// hash *and* its path. The scan must then call it `.alreadyImported`.
    ///
    /// A different file from the orphan's: a photo cannot be both the one the
    /// library has lost and the one it still has.
    static func makeAlreadyImported(in directory: URL, avoiding other: URL?) -> URL? {
        guard let library = try? Library.openDefault(),
              let urls = try? ImportScanner.scan(directory: directory, recursive: true)
        else { return nil }
        defer { try? library.close() }
        // Not the synthetic JPEG either — the existing checks below expect that
        // one to be new to the library.
        guard let subject = urls.first(where: {
            $0 != other && $0.lastPathComponent != "standard.jpg" && canDecode($0)
        }) else { return nil }
        guard (try? Importer(library: library).importFile(at: subject)) != nil else { return nil }
        return subject
    }

    static func finishImport(_ failures: [String]) -> Never {
        if failures.isEmpty {
            log("import self-test: PASS")
            exit(0)
        }
        log("import self-test: FAILED — " + failures.joined(separator: "; "))
        exit(5)
    }

    /// SwiftUI puts one item per `Window` scene in the Window menu; sending its
    /// action is what `openWindow(id:)` does from inside a view.
    static func openImportWindow() {
        if let item = findMenuItem(titled: "Import"), let action = item.action {
            log("import self-test: opening via Window › Import")
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            log("import self-test: no Window › Import menu item to open")
        }
    }

    static func importWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Import" && $0.isVisible }
    }

    static func waitForImportGrid(model: ImportModel,
                                          then body: @escaping (NSWindow?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let done = !model.isScanning && model.totalCount > 0
                && model.items.allSatisfy { $0.thumbnail != nil && $0.status != .pending }
            if Date() < deadline, !(done && importWindow() != nil) {
                waitForImportGrid(model: model, then: body)
            } else {
                body(importWindow())
            }
        }
    }

    static func writeImportScreenshot(window: NSWindow) {
        writeScreenshot(of: window, named: "selftest-import.png")
    }
}
