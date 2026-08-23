import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomCore
import GrayroomLibrary
import GrayroomUI
import ImageIO
import Metal
import Observation
import UniformTypeIdentifiers

/// `GRAYROOM_SELFTEST=paint|undo|import|library swift run GrayroomApp <file.DNG>`
///
/// Whole-app checks, each in its own process: `paint` (a stroke drawn with real
/// mouse events), `undo` (Cmd-Z / Cmd-Shift-Z pushed through the real menu-bar
/// key-equivalent path), `import` (the second window scene, its menu item, its
/// grid and its selection commands) and `library` (the grid, the g/d module
/// keys and the colour-label keys, all as real keystrokes). All print PASS/FAIL
/// lines and exit non-zero on failure.
///
/// Repro (c): the whole app, in its own process, painting a stroke with real
/// `NSEvent`s and then telling you — on stdout, in the library and in a
/// screenshot of its own window — where that stroke went.
///
/// It exists because the unit tests can only prove that the canvas's *own* math
/// is self-consistent. This is the only check that runs the real SwiftUI window,
/// the real toolbar/sidebar layout, the real decode and the real presented
/// drawable, i.e. the thing the user actually reported on.
///
/// Nothing here is reachable without the environment variable, and it writes a
/// development into the real library for whatever RAW it was pointed at.
enum SelfTest {
    enum Mode: String {
        /// Repro (c): a stroke painted with real `NSEvent`s.
        case paint
        /// Repro (d): Cmd-Z / Cmd-Shift-Z pushed through the real menu-bar key
        /// equivalent path, which is where the undo bug actually lived.
        case undo
        /// The import window: the File › Import… item as AppKit sees it, the
        /// second `Window` scene actually opening, thumbnails arriving in the
        /// grid, and the selection commands moving the ring and the checkboxes.
        ///
        /// `GRAYROOM_SELFTEST_IMPORT_DIR` names the folder to scan (default
        /// `testdata`). `GRAYROOM_SELFTEST_IMPORT_RUN=1` additionally presses
        /// Import — which *writes to the library*, so run it with
        /// `CFFIXED_USER_HOME` pointed at a throwaway directory:
        ///
        /// ```
        /// CFFIXED_USER_HOME=$(mktemp -d) GRAYROOM_SELFTEST=import \
        ///     GRAYROOM_SELFTEST_IMPORT_RUN=1 swift run GrayroomApp
        /// ```
        ///
        /// `HOME` alone is not enough: Foundation resolves Application Support
        /// from `CFFIXED_USER_HOME` or the passwd entry, not from `HOME`.
        case importWindow = "import"
        /// The Library module: that the app starts there, that the grid has a
        /// cell per photo, that clicks and arrows move the ring, and that
        /// Lightroom's keys — `8` for green, `6` for red, `d` and `g` for the
        /// two modules — do what they do in Lightroom, pushed in as real
        /// keystrokes through the menu-bar key-equivalent path.
        ///
        /// It imports into the library, so run it against a throwaway home:
        ///
        /// ```
        /// CFFIXED_USER_HOME=$(mktemp -d) GRAYROOM_SELFTEST=library \
        ///     swift run GrayroomApp
        /// ```
        case library
    }

    static var mode: Mode? {
        ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST"].flatMap(Mode.init(rawValue:))
    }

    static var isRequested: Bool { mode != nil }

    private static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_OUT"] ?? "out"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static var deadline = Date().addingTimeInterval(120)

    static func startIfRequested() {
        guard isRequested else { return }
        // These tests open photos, and opening a photo is what the app reopens
        // at the next launch — a preference `CFFIXED_USER_HOME` does *not*
        // redirect, because cfprefsd keys off the real user. Left alone it
        // leaks into the next self-test's library (measured: it made the import
        // test's "the JPEG is new to the library" fail on every second run), so
        // the grid tests put it back before they exit.
        previousLastFile = UserDefaults.standard.string(forKey: AppModel.lastFileDefaultsKey)
        // The import window does not need a document, so it does not wait for
        // one — pointing this mode at a RAW file just to get past the poll
        // would be a decode the test has no use for.
        if mode == .importWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runImportWindow() }
            return
        }
        // Same reason: the library test starts from an empty library and no
        // document at all — waiting for a first render would wait forever.
        if mode == .library {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runLibrary() }
            return
        }
        log("self-test: waiting for the first render")
        poll()
    }

    // MARK: - The import-window test

    private static func runImportWindow() {
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

    private static func runTheImport(model: ImportModel,
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
            // cells build thumbnails. That task is expected to be there (or
            // not, if it has already drained); what must be gone is the import.
            check(!app.tasks.tasks.contains { $0.title != "Building thumbnails" },
                  "the activity centre has nothing but thumbnails left "
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

    private static func waitForDecode(_ app: AppModel, then body: @escaping (CGSize) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if app.previewSize == .zero, Date() < deadline {
                waitForDecode(app, then: body)
            } else {
                body(app.previewSize)
            }
        }
    }

    /// Copies the source folder into the output directory and drops a
    /// synthetic JPEG in, so the run exercises both decode paths without
    /// writing into `testdata/`.
    private static func stageSourceWithAJPEG(_ original: URL) -> URL {
        let staged = outputDirectory.appendingPathComponent("import-source", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: staged)
        guard (try? FileManager.default.copyItem(at: original, to: staged)) != nil else {
            log("import self-test: could not stage \(original.path); using it directly")
            return original
        }
        let jpeg = staged.appendingPathComponent("standard.jpg")
        let width = 64, height = 48
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let value = UInt8((i * 7) % 256)
            bytes[i * 4] = value
            bytes[i * 4 + 1] = value
            bytes[i * 4 + 2] = UInt8(255 - Int(value))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(
                                      rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                  jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            log("import self-test: could not build the synthetic JPEG")
            return staged
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal as String: "2021:03:09 08:15:00",
                kCGImagePropertyExifOffsetTimeOriginal as String: "+00:00",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            log("import self-test: could not write the synthetic JPEG")
        }
        return staged
    }

    /// Imports a *copy* of one of the source files and then removes the copy's
    /// location row, leaving the library with a photo it knows by hash and has
    /// no file for. Returns the original in `directory` that shares those bytes.
    private static func makeHashKnownButUnlocated(in directory: URL) -> URL? {
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

    /// Polls until the import task leaves the activity centre, reporting the
    /// highest `completed` it ever saw — which is how the test knows progress
    /// was reported rather than the task simply appearing and vanishing.
    private static func waitForImportToFinish(_ app: AppModel, peak: Int = 0,
                                              then body: @escaping (Int) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let task = app.tasks.tasks.first { $0.title == "Importing photos" }
            let peak = max(peak, task?.completed ?? 0)
            if task != nil, Date() < deadline {
                waitForImportToFinish(app, peak: peak, then: body)
            } else {
                body(peak)
            }
        }
    }

    private static func finishImport(_ failures: [String]) -> Never {
        restoreLastOpenedFile()
        if failures.isEmpty {
            log("import self-test: PASS")
            exit(0)
        }
        log("import self-test: FAILED — " + failures.joined(separator: "; "))
        exit(5)
    }

    /// SwiftUI puts one item per `Window` scene in the Window menu; sending its
    /// action is what `openWindow(id:)` does from inside a view.
    private static func openImportWindow() {
        if let item = findMenuItem(titled: "Import"), let action = item.action {
            log("import self-test: opening via Window › Import")
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            log("import self-test: no Window › Import menu item to open")
        }
    }

    private static func importWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Import" && $0.isVisible }
    }

    private static func waitForImportGrid(model: ImportModel,
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

    private static func findMenuItem(titled title: String) -> NSMenuItem? {
        guard let main = NSApp.mainMenu else { return nil }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            if let item = submenu.items.first(where: { $0.title == title }) { return item }
        }
        return nil
    }

    private static func writeImportScreenshot(window: NSWindow) {
        writeScreenshot(of: window, named: "selftest-import.png")
    }

    private static func writeScreenshot(of window: NSWindow, named name: String) {
        let url = outputDirectory.appendingPathComponent(name)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            log("self-test: CGWindowListCreateImage returned nil "
                + "(screen-recording permission?)")
            return
        }
        write(image, to: url)
        log("self-test: wrote \(url.path) (\(image.width)x\(image.height))")
    }

    // MARK: - The library test

    /// Imports `testdata` into a throwaway library and then drives the grid the
    /// way a user does: a click, an arrow, a shift-click, and Lightroom's keys
    /// as **real keystrokes** through `NSApp.sendEvent`.
    ///
    /// The keystrokes are the point. `6`–`9`, `g` and `d` are bare-key menu
    /// equivalents, which AppKit matches before the event reaches any view — so
    /// the only way to know they work is to push a real key event in and see
    /// what the library and the database say afterwards. A unit test on
    /// `AppModel` would prove nothing about the menu.
    private static func runLibrary() {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            log("library self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }
        let app = AppModel.shared

        dumpMenus()

        // 1. No file argument: the app comes up in the Library, on an empty
        //    throwaway library, with no develop canvas in the window at all.
        check(app.mode == .library, "the app started in the library (got \(app.mode.rawValue))")
        // Both things that can put it in develop instead, on the record: a file
        // named on the command line, and a library that would not open.
        log("library self-test: args=\(Array(CommandLine.arguments.dropFirst())) "
            + "keyWindow=\(NSApp.keyWindow?.title ?? "nil") "
            + "mainWindow=\(NSApp.mainWindow?.title ?? "nil") "
            + "error=\(app.errorMessage ?? "none")")
        check(findCanvas() == nil, "the develop canvas is not in the window in library mode")
        // Not asserted to be empty: `CFFIXED_USER_HOME` moves the library but
        // not `cfprefsd`, so the app may still reopen — and therefore import —
        // the file the *real* user last had open, on a background queue whose
        // timing this test does not control. The import below is checked by
        // hash instead of by count.
        log("library self-test: the library starts with \(app.catalog.count) photo(s)")

        // 2. Lightroom's keys, as AppKit sees them. A disabled item would
        //    swallow its key equivalent silently (see UndoMenu.swift).
        for (title, key) in [("Library", "g"), ("Develop", "d"), ("Red", "6"),
                             ("Yellow", "7"), ("Green", "8"), ("Blue", "9")] {
            let item = findMenuItemDeep(titled: title)
            check(item?.keyEquivalent == key,
                  "'\(title)' carries the bare key '\(key)' (got '\(item?.keyEquivalent ?? "missing")')")
            check(item?.keyEquivalentModifierMask.isEmpty == true, "'\(title)' has no modifiers")
            check(item?.isEnabled == true, "'\(title)' is enabled")
        }
        // Lightroom gives purple no key; neither do we.
        let purple = findMenuItemDeep(titled: "Purple")
        check(purple != nil, "Purple is in the menu")
        check(purple?.keyEquivalent.isEmpty == true, "Purple has no key equivalent, as in Lightroom")

        // 3. Fill the library through the real import path.
        let path = ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_IMPORT_DIR"] ?? "testdata"
        let source = stageSourceWithAJPEG(URL(fileURLWithPath: path, isDirectory: true))
        log("library self-test: importing \(source.path)")
        app.importModel.setSource(source)
        waitForScan(app.importModel) {
            // By hash, not by count: the reopened last file (see above) may be
            // importing itself in the background while this runs, so "how many
            // photos" is not a number this test can pin down. "Every file I
            // imported has a cell" is.
            let expected = Set(app.importModel.checkedEntries.compactMap(\.hash)
                .map { $0.lowercased() })
            app.importModel.runImport()
            waitForImportToFinish(app) { _ in
                check(app.mode == .library, "the import did not change modules")
                let inCatalog = Set(app.catalog.photos.map { $0.hashHexString.lowercased() })
                // Missing is only allowed for a file the decoder cannot read —
                // `testdata` is a personal folder and may hold a camera Apple's
                // RAW support does not know.
                let missing = expected.subtracting(inCatalog)
                let undecodable = missing.filter { hash in
                    guard let url = app.importModel.checkedEntries
                        .first(where: { $0.hash?.lowercased() == hash })?.url
                    else { return false }
                    log("library self-test: no cell for \(url.lastPathComponent)")
                    return !canDecode(url)
                }
                check(missing.count == undecodable.count,
                      "every importable photo has a cell in the grid "
                          + "(\(missing.count - undecodable.count) unexplained, "
                          + "\(undecodable.count) undecodable, of \(expected.count))")
                check(app.catalog.count >= expected.count,
                      "the grid has at least the imported photos "
                          + "(\(app.catalog.count) cells, \(expected.count) imported)")
                check(app.catalog.photos.allSatisfy { $0.firstLocation != nil },
                      "every catalogued photo has a file on disk")
                runLibraryKeys(app: app, check: check, failures: { failures })
            }
        }
    }

    private static func runLibraryKeys(app: AppModel,
                                       check: @escaping (Bool, String) -> Void,
                                       failures: @escaping () -> [String]) {
        let ids = app.catalog.ids
        guard ids.count >= 4, let window = KeyRouter.mainWindow() else {
            check(false, "four photos and a window to drive the grid with")
            finishLibrary(failures())
        }
        let subject = ids[1]
        var subjectName = app.catalog.photo(id: subject)?.originalName ?? "?"

        let steps: [() -> Void] = [
            {
                // 4. Multi-select, driven by **real mouse events** carrying
                //    real modifier flags. Not `NSEvent.modifierFlags` and not a
                //    tap gesture: see `ThumbnailGrid`.
                check(cellView(cellID(ids[0])) != nil,
                      "the grid put a click target behind every cell")
                check(clickCell(cellID(ids[0])), "clicked the first cell")
                check(app.highlightedPhotoIDs == [ids[0]],
                      "a plain click selects one (\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· 1 selected"),
                      "the bottom bar says so (\(app.libraryCountLabel))")

                check(clickCell(cellID(ids[2]), modifiers: .shift), "shift-clicked the third cell")
                check(app.highlightedPhotoIDs == [ids[0], ids[1], ids[2]],
                      "shift-click selects the range of three "
                          + "(\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· 3 selected"),
                      "the bottom bar says three (\(app.libraryCountLabel))")

                check(clickCell(cellID(ids[1]), modifiers: .command), "cmd-clicked the middle cell")
                check(app.highlightedPhotoIDs == [ids[0], ids[2]],
                      "cmd-click toggles one out of the selection "
                          + "(\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· 2 selected"),
                      "the bottom bar says two (\(app.libraryCountLabel))")

                // ⌘A is a key, and it is *not* a menu item — the router owns it.
                sendKey("a", modifiers: .command, window: window, virtualKey: 0)
            },
            {
                check(app.librarySelection.count == ids.count,
                      "cmd-A selected all \(ids.count) (\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· \(ids.count) selected"),
                      "the bottom bar says all of them (\(app.libraryCountLabel))")

                // 5. Arrows, bare and with shift, after a click somewhere else
                //    in the window — the case SwiftUI focus got wrong.
                _ = clickCell(cellID(ids[0]))
                sendKey("", modifiers: [], window: window, virtualKey: 124)   // →
            },
            {
                check(app.highlightedPhotoIDs == [ids[1]],
                      "the right arrow moved the highlight by one")
                sendKey("", modifiers: .shift, window: window, virtualKey: 124)
            },
            {
                check(app.highlightedPhotoIDs == [ids[1], ids[2]],
                      "shift-right extended the range from the anchor "
                          + "(\(app.librarySelection.count))")
                sendKey("", modifiers: .shift, window: window, virtualKey: 123)   // ←
            },
            {
                check(app.highlightedPhotoIDs == [ids[1]],
                      "shift-left shrank it back to the anchor "
                          + "(\(app.librarySelection.count))")
                // 6. Return does *not* open the develop view. Only d and a
                //    double-click do.
                sendKey("", modifiers: [], window: window, virtualKey: 36)
            },
            {
                check(app.mode == .library, "Return does not leave the library")
                _ = clickCell(cellID(ids[1]))
                _ = clickCell(cellID(ids[2]), modifiers: .shift)
                check(app.highlightedPhotoIDs == [ids[1], ids[2]],
                      "two photos highlighted for the colour keys")
                // 7. `8` is green in Lightroom, and it labels the whole
                //    highlight — in RAM and in the database. Exactly once: a
                //    second application would toggle it straight back off, so
                //    "still green" is the proof that the local monitor did not
                //    double-fire with the menu's key equivalent.
                sendKey("8", modifiers: [], window: window, virtualKey: 28)
            },
            {
                check(app.catalog.photo(id: ids[1])?.color == .green
                          && app.catalog.photo(id: ids[2])?.color == .green,
                      "8 turned both highlighted photos green, exactly once")
                check(storedColor(ids[1]) == .green && storedColor(ids[2]) == .green,
                      "…and in the database (got \(describe(storedColor(ids[1]))), "
                          + "\(describe(storedColor(ids[2]))))")
                // 8. Lightroom's toggle: the same key again clears it.
                sendKey("8", modifiers: [], window: window, virtualKey: 28)
            },
            {
                check(app.catalog.photo(id: ids[1])?.color == .unlabeled
                          && app.catalog.photo(id: ids[2])?.color == .unlabeled,
                      "8 again cleared the label in the catalog")
                check(storedColor(ids[1]) == .unlabeled && storedColor(ids[2]) == .unlabeled,
                      "…and in the database")
                // 9. `d` opens the highlighted photo in the develop view.
                sendKey("d", modifiers: [], window: window, virtualKey: 2)
            },
            {
                check(app.mode == .develop, "d switched to the develop view")
                check(app.currentPhotoID == subject,
                      "…on the highlighted photo (\(subjectName))")
                subjectName = app.imageURL?.lastPathComponent ?? subjectName
                check(app.imageURL?.path == app.catalog.photo(id: subject)?.firstLocation,
                      "…opened from the catalog's own path (\(subjectName))")
                check(findCanvas() != nil, "the develop canvas is in the window")
            },
            {
                check(app.previewSize != .zero,
                      "the photo decoded in the develop view (\(app.previewSize))")
                // 10. `6` is red, and in the develop view it labels the open
                //     photo rather than a grid selection.
                sendKey("6", modifiers: [], window: window, virtualKey: 22)
            },
            {
                check(app.currentColorLabel == .red, "6 labelled the open photo red")
                check(app.catalog.photo(id: subject)?.color == .red, "…in the catalog")
                check(storedColor(subject) == .red,
                      "…and in the database (got \(describe(storedColor(subject))))")
                // 11. `g` goes back to the grid.
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                check(app.mode == .library, "g came back to the library")
                check(app.highlightedPhotoIDs == [subject],
                      "…with the photo that was being developed highlighted")
                check(findCanvas() == nil, "…and the develop canvas gone again")
                // 12. A double-click opens too.
                check(clickCell(cellID(ids[0]), clickCount: 2), "double-clicked the first cell")
            },
            {
                check(app.mode == .develop && app.currentPhotoID == ids[0],
                      "a double-click opened that photo in develop "
                          + "(mode \(app.mode.rawValue))")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
        ]

        runSteps(steps, model: app) {
            // 13. The cells built their thumbnails — in RAM, and on disk where
            //     the next launch will find them.
            let inMemory = ids.filter { app.thumbnails.cached($0) != nil }.count
            check(inMemory > 0,
                  "the grid built thumbnails in memory (\(inMemory) of \(ids.count))")
            let directory = ThumbnailCache.defaultDirectory()
            let onDisk = ((try? FileManager.default
                .contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".jpg") }
            check(onDisk.count >= inMemory,
                  "…and wrote them to \(directory.path) (\(onDisk.count) files)")

            // 14. What all of that looks like: one red cell, the ring on it.
            try? FileManager.default.createDirectory(at: outputDirectory,
                                                     withIntermediateDirectories: true)
            writeScreenshot(of: window, named: "selftest-library.png")
            finishLibrary(failures())
        }
    }

    /// The transparent `NSView` `ThumbnailGrid` puts behind each cell to catch
    /// clicks. Finding it is how this test can click a *cell* without knowing
    /// anything about the grid's geometry.
    private static func cellView(_ identifier: String) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView, let found = search(root) { return found }
        }
        return nil
    }

    /// Whether this app can read the file at all — the same probe the importer
    /// uses, so a file that fails here is one the import was always going to
    /// reject.
    private static func canDecode(_ url: URL) -> Bool {
        (try? ImageDecoder.probe(url: url)) != nil
    }

    private static func cellID(_ id: Int64) -> String { "grid-cell-\(id)" }
    private static func cellID(_ url: URL) -> String { "grid-cell-\(url)" }

    /// A real click on a cell, with real modifier flags on the event — the
    /// thing a tap gesture cannot see.
    ///
    /// `fromTopLeft`, when given, aims at a point inside the cell instead of
    /// its centre: that is how the import window's checkbox gets clicked, and
    /// therefore how this test knows the checkbox still takes its own clicks
    /// rather than the click catcher swallowing them.
    @discardableResult
    private static func clickCell(_ identifier: String,
                                  modifiers: NSEvent.ModifierFlags = [],
                                  clickCount: Int = 1,
                                  fromTopLeft: CGPoint? = nil) -> Bool {
        guard let view = cellView(identifier), let window = view.window else {
            log("self-test: no click target \(identifier)")
            return false
        }
        let local = fromTopLeft.map { CGPoint(x: view.bounds.minX + $0.x,
                                              y: view.bounds.maxY - $0.y) }
            ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = view.convert(local, to: nil)
        clickCounter += 1
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: clickCounter, clickCount: clickCount, pressure: 1)
            else { return false }
            window.sendEvent(event)
        }
        return true
    }

    private static var clickCounter = 0

    /// What the *database* holds, read through a second connection — the app's
    /// own catalog is exactly what is under test, so it cannot be the witness.
    private static func storedColor(_ id: Int64) -> ColorLabel? {
        guard let library = try? Library.openDefault() else { return nil }
        defer { try? library.close() }
        return (try? library.photo(id: id))??.color
    }

    private static func describe(_ color: ColorLabel?) -> String {
        color.map(\.name) ?? "nil"
    }

    private static func waitForScan(_ model: ImportModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if Date() < deadline, model.isScanning || model.totalCount == 0 {
                waitForScan(model, then: body)
            } else {
                body()
            }
        }
    }

    /// Every menu item AppKit has, submenus included — the colour labels live
    /// one level down, in Photo › Set Color Label.
    private static func findMenuItemDeep(titled title: String) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            menu.update()
            for item in menu.items {
                if item.title == title { return item }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu else { return nil }
        return search(main)
    }

    private static var previousLastFile: String?

    /// Puts back what the app will reopen at the next launch — see
    /// `startIfRequested`.
    private static func restoreLastOpenedFile() {
        if let previousLastFile {
            UserDefaults.standard.set(previousLastFile, forKey: AppModel.lastFileDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppModel.lastFileDefaultsKey)
        }
    }

    private static func finishLibrary(_ failures: [String]) -> Never {
        restoreLastOpenedFile()
        if failures.isEmpty {
            log("library self-test: PASS")
            exit(0)
        }
        log("library self-test: FAILED — \(failures.count) check(s): "
            + failures.joined(separator: "; "))
        exit(6)
    }

    // MARK: - Waiting

    private static func poll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let model = AppModel.shared
            guard Date() < deadline else { fail("timed out waiting for the first render") }
            guard let canvas = findCanvas(), canvas.window != nil,
                  model.previewSize != .zero, canvas.imageTexture != nil,
                  !model.isDecoding, !model.isRendering else {
                poll()
                return
            }
            switch mode {
            case .paint, nil: run(canvas: canvas, model: model)
            case .undo: runUndo(canvas: canvas, model: model)
            case .importWindow, .library: break
            }
        }
    }

    private static func findCanvas() -> CanvasNSView? {
        func search(_ view: NSView) -> CanvasNSView? {
            if let c = view as? CanvasNSView { return c }
            for sub in view.subviews { if let c = search(sub) { return c } }
            return nil
        }
        for window in NSApp.windows {
            if let root = window.contentView, let c = search(root) { return c }
        }
        return nil
    }

    private static func settle(_ model: AppModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if model.isRendering || model.isDecoding, Date() < deadline {
                settle(model, then: body)
            } else {
                body()
            }
        }
    }

    // MARK: - The test

    private static func run(canvas: CanvasNSView, model: AppModel) {
        guard let window = canvas.window else { fail("canvas has no window") }

        // A clean slate: whatever edit was stored must not colour the result.
        prepareForPainting(model)
        // So the screenshot *shows* where the paint landed, not just where the
        // cursor was.
        model.showMaskOverlay = true

        let targets = paintStroke(canvas: canvas, window: window, model: model)
        settle(model) { finish(canvas: canvas, window: window, model: model, targets: targets) }
    }

    /// Empty edit, one mask, brush tool — the starting point of both self-tests.
    private static func prepareForPainting(_ model: AppModel) {
        model.store.replace(EditState(), named: nil)
        model.store.addMask()
        model.updateBrush { $0.size = 0.06; $0.feather = 50; $0.flow = 100; $0.density = 100 }
        model.tool = .brush
    }

    /// Paints a diagonal across the image's top-left quadrant with synthesized
    /// mouse events and returns the normalized points it aimed at.
    @discardableResult
    private static func paintStroke(canvas: CanvasNSView, window: NSWindow,
                                    model: AppModel) -> [CGPoint] {
        let imageSize = model.previewSize

        // --- Ground truth, computed from the window layout only -------------
        // Where the fitted image sits inside the canvas, in device pixels:
        let scale = window.backingScaleFactor
        let viewW = canvas.bounds.width * scale
        let viewH = canvas.bounds.height * scale
        let zoom = min(min(viewW / imageSize.width, viewH / imageSize.height), 1)
        let drawnW = imageSize.width * zoom
        let drawnH = imageSize.height * zoom
        let originX = (viewW - drawnW) / 2
        let originY = (viewH - drawnH) / 2
        // The canvas rect in the window's y-**up** base coordinates:
        let rect = canvas.convert(canvas.bounds, to: nil)

        /// Normalised image point -> window point, without touching
        /// `CanvasTransform`.
        func windowPoint(normalized n: CGPoint) -> CGPoint {
            let deviceX = originX + n.x * drawnW          // from the canvas's left
            let deviceY = originY + n.y * drawnH          // *below* the canvas's top
            return CGPoint(x: rect.minX + deviceX / scale,
                           y: rect.maxY - deviceY / scale)
        }

        // A diagonal across the image's TOP-LEFT quadrant.
        let targets: [CGPoint] = stride(from: 0.20, through: 0.36, by: 0.02)
            .map { CGPoint(x: $0, y: $0) }
        log(String(format: "self-test: preview %.0fx%.0f, canvas %.0fx%.0f device px, zoom %.4f",
                   imageSize.width, imageSize.height, viewW, viewH, zoom))
        log("self-test: intended normalized points = "
            + targets.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " "))

        // --- Paint with real events -----------------------------------------
        var number = 0
        func send(_ type: NSEvent.EventType, at p: CGPoint) {
            number += 1
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: number, clickCount: 1, pressure: 1)
            else { fail("could not synthesize \(type)") }
            window.sendEvent(e)
        }

        send(.leftMouseDown, at: windowPoint(normalized: targets[0]))
        for t in targets.dropFirst() { send(.leftMouseDragged, at: windowPoint(normalized: t)) }
        send(.leftMouseUp, at: windowPoint(normalized: targets.last!))
        return targets
    }

    private static func finish(canvas: CanvasNSView, window: NSWindow,
                               model: AppModel, targets: [CGPoint]) {
        guard let stroke = model.store.edit.masks.last?.strokes.last else {
            fail("no stroke was recorded — the events never reached the canvas")
        }
        log("self-test: recorded normalized points = "
            + stroke.points.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " "))
        let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
        log(String(format: "self-test: x range %.3f…%.3f, y range %.3f…%.3f",
                   xs.min()!, xs.max()!, ys.min()!, ys.max()!))

        log("self-test: showMaskOverlay=\(model.showMaskOverlay) "
            + "canvas.showOverlay=\(canvas.showOverlay) "
            + "coverageTexture=\(canvas.coverageTexture != nil) "
            + "selectedMaskIndex=\(String(describing: model.store.selectedMaskIndex))")

        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)
        model.saveNow()

        writeWindowScreenshot(window: window)
        writeCanvasRender(canvas: canvas)

        // Non-zero only if the stroke is not where it was aimed; the numeric
        // coverage check lives in the shell script that drives this.
        let ok = zip(stroke.points, targets).allSatisfy {
            abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01
        } && stroke.points.count == targets.count
        log("self-test: points match intent = \(ok)")
        exit(ok ? 0 : 3)
    }

    // MARK: - The undo test

    /// `GRAYROOM_SELFTEST=undo swift run GrayroomApp <copy-of-file.DNG>`
    ///
    /// Paints a stroke, then drives **Cmd-Z / Cmd-Shift-Z as key events through
    /// `NSApp.sendEvent`** — the same path a real keystroke takes, menu-bar key
    /// equivalent matching and menu-item enablement included. That matters
    /// because a disabled menu item swallows its shortcut silently: the bug
    /// reproduces here and nowhere in the unit tests.
    private static func runUndo(canvas: CanvasNSView, model: AppModel) {
        guard let window = canvas.window else { fail("canvas has no window") }
        let store = model.store
        var failures: [String] = []

        func check(_ ok: Bool, _ what: String) {
            log("undo self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }
        func state(_ label: String) {
            log("undo self-test: \(label): canUndo=\(store.canUndo) canRedo=\(store.canRedo) "
                + "menuUndo=\(menuItemState("Undo")) menuRedo=\(menuItemState("Redo")) "
                + "strokes=\(strokeCount(store)) exposure=\(store.edit.tone.exposure)")
        }

        trackUndoAvailability(store)
        dumpMenus()
        prepareForPainting(model)
        state("after setup")
        paintStroke(canvas: canvas, window: window, model: model)

        let steps: [() -> Void] = [
            {
                state("after painting")
                check(strokeCount(store) == 1, "a stroke was painted")
                check(store.canUndo, "canUndo is true after painting")
                check(menuItemState("Undo") == "enabled", "the Undo menu item is live")
                check(menuItemState("Redo") == "DISABLED", "the Redo menu item is greyed out")
                sendKey("z", modifiers: .command, window: window)
            },
            {
                state("after Cmd-Z")
                check(strokeCount(store) == 0, "Cmd-Z removed the stroke")
                check(store.canRedo, "canRedo is true after undoing")
                check(menuItemState("Redo") == "enabled", "the Redo menu item went live")
                sendKey("z", modifiers: [.command, .shift], window: window)
            },
            {
                state("after Cmd-Shift-Z")
                check(strokeCount(store) == 1, "Cmd-Shift-Z restored the stroke")
                // A slider-style change made through the store API, undone
                // through the keyboard.
                store.perform("Exposure") { $0.tone.exposure = 1.25 }
            },
            {
                state("after the exposure change")
                check(store.edit.tone.exposure == 1.25, "the exposure change applied")
                sendKey("z", modifiers: .command, window: window)
            },
            {
                state("after Cmd-Z")
                check(store.edit.tone.exposure == 0, "Cmd-Z reverted the exposure change")
                check(strokeCount(store) == 1, "…and left the stroke alone")
            },
        ]

        runSteps(steps, model: model) {
            if failures.isEmpty {
                log("undo self-test: PASS (all \(steps.count) checkpoints)")
                exit(0)
            }
            log("undo self-test: FAILED — \(failures.count) check(s): "
                + failures.joined(separator: "; "))
            exit(4)
        }
    }

    private static func strokeCount(_ store: EditStateStore) -> Int {
        store.edit.masks.reduce(0) { $0 + $1.strokes.count }
    }

    /// Runs each step with a settle (render/decode quiescence) in between.
    private static func runSteps(_ steps: [() -> Void], model: AppModel,
                                 then done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        first()
        settle(model) { runSteps(Array(steps.dropFirst()), model: model, then: done) }
    }

    /// Pushes a real keystroke into the app.
    ///
    /// The event is built as a **`CGEvent`** and converted with
    /// `NSEvent(cgEvent:)`, not with `NSEvent.keyEvent(with:…)`. That is not
    /// incidental: AppKit's menu key-equivalent matching consults the event's
    /// underlying CGEvent (key code plus the current keyboard layout), so a
    /// hand-rolled `NSEvent` with the "right" character strings matches
    /// differently from a real keystroke — measured here: a hand-rolled
    /// Cmd-Shift-Z matched nothing at all, while the CGEvent-shaped one matches
    /// Redo. A self-test that used the hand-rolled form would report a bug the
    /// user does not have, or miss one they do.
    ///
    /// `NSApp.sendEvent` is the same entry point the window server uses, so this
    /// goes through menu key-equivalent matching, item validation and all.
    private static func sendKey(_ characters: String, modifiers: NSEvent.ModifierFlags,
                                window: NSWindow, virtualKey: CGKeyCode = 6 /* Z */) {
        log("self-test: sending key \(describe(modifiers))\(characters)")
        guard let source = CGEventSource(stateID: .privateState) else {
            fail("could not make a CGEventSource")
        }
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        for isDown in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: virtualKey,
                                   keyDown: isDown) else { fail("could not make a CGEvent") }
            cg.flags = flags
            guard let event = NSEvent(cgEvent: cg) else { fail("CGEvent -> NSEvent failed") }
            if isDown {
                log("undo self-test:   event characters='\(event.characters ?? "")' "
                    + "ignoringModifiers='\(event.charactersIgnoringModifiers ?? "")' "
                    + "flags=\(event.modifierFlags.rawValue)")
            }
            NSApp.sendEvent(event)
        }
    }

    private static func describe(_ modifiers: NSEvent.ModifierFlags) -> String {
        (modifiers.contains(.command) ? "Cmd-" : "") + (modifiers.contains(.shift) ? "Shift-" : "")
    }

    /// What the menu bar thinks of an item right now — the thing that decides
    /// whether the key equivalent fires at all.
    private static func menuItemState(_ title: String) -> String {
        guard let main = NSApp.mainMenu else { return "no-main-menu" }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            if let item = submenu.items.first(where: { $0.title == title }) {
                return item.isEnabled ? "enabled" : "DISABLED"
            }
        }
        return "missing"
    }

    /// Every menu item AppKit currently has, with the facts that decide whether
    /// a key equivalent fires: enablement, autoenabling, target and action.
    private static func dumpMenus() {
        guard let main = NSApp.mainMenu else {
            log("undo self-test: NSApp.mainMenu is nil")
            return
        }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            log("undo self-test: menu '\(top.title)' autoenables=\(submenu.autoenablesItems)")
            for item in submenu.items where !item.isSeparatorItem {
                log("undo self-test:   item '\(item.title)' enabled=\(item.isEnabled) "
                    + "key='\(item.keyEquivalent)' mask=\(item.keyEquivalentModifierMask.rawValue) "
                    + "action=\(item.action.map(String.init(describing:)) ?? "nil") "
                    + "target=\(item.target.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
    }

    /// Logs every Observation notification for `canUndo` / `canRedo`, i.e. every
    /// moment SwiftUI would re-evaluate the Edit menu's `.disabled(…)`.
    private static func trackUndoAvailability(_ store: EditStateStore) {
        withObservationTracking {
            _ = store.canUndo
            _ = store.canRedo
        } onChange: {
            DispatchQueue.main.async {
                log("undo self-test: observation fired -> canUndo=\(store.canUndo) "
                    + "canRedo=\(store.canRedo)")
                trackUndoAvailability(store)
            }
        }
    }

    // MARK: - Output

    private static func writeWindowScreenshot(window: NSWindow) {
        let url = outputDirectory.appendingPathComponent("selftest-paint.png")
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            log("self-test: CGWindowListCreateImage returned nil "
                + "(screen-recording permission?) — see selftest-canvas.png instead")
            return
        }
        write(image, to: url)
        log("self-test: wrote \(url.path) (\(image.width)x\(image.height))")
    }

    /// The canvas alone, re-rendered offscreen through the very same shader and
    /// uniforms the window is showing. Always available, no permissions needed.
    private static func writeCanvasRender(canvas: CanvasNSView) {
        guard let device = canvas.device, let queue = device.makeCommandQueue() else { return }
        let size = canvas.transform.viewSize
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: canvas.colorPixelFormat,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = canvas.clearColor
        pass.colorAttachments[0].storeAction = .store
        canvas.encodeCanvas(into: pass, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()

        // The drawable is display-linear `rgba16Float`, so the screenshot has to
        // be encoded here: sRGB, tone-mapped by a plain clip at SDR white (this
        // is a debugging artefact, not an HDR deliverable).
        var halfs = [Float16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!,
                            bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        func encode(_ v: Float16) -> UInt8 {
            let c = min(max(Double(v), 0), 1)
            let s = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return UInt8(min(max((s * 255).rounded(), 0), 255))
        }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            bytes[i * 4] = encode(halfs[i * 4])
            bytes[i * 4 + 1] = encode(halfs[i * 4 + 1])
            bytes[i * 4 + 2] = encode(halfs[i * 4 + 2])
        }
        let info: CGBitmapInfo = [CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)
                                      ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        let url = outputDirectory.appendingPathComponent("selftest-canvas.png")
        write(image, to: url)
        log("self-test: wrote \(url.path) (\(w)x\(h))")
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                         1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// A trace line from elsewhere in the app, printed only while a self-test is
    /// running so the normal app stays silent.
    static func note(_ message: String) {
        guard isRequested else { return }
        log("trace: " + message)
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        log("self-test FAILED: \(message)")
        exit(2)
    }
}





