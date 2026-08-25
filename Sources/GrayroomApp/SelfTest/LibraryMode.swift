import AppKit
import CoreGraphics
import GrayroomCore
import GrayroomLibrary
import GrayroomUI

/// `GRAYROOM_SELFTEST=library` — see `SelfTest.Mode.library`. The grid, the
/// module keys, the colour-label keys and the development-aware previews;
/// the Folders panel is in `FolderPanelChecks.swift` and the window's chrome,
/// the menus and the export sheet in `WindowChecks.swift`.
extension SelfTest {
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
    static func runLibrary() {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            log("library self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }
        let app = AppModel.shared

        dumpMenus()
        // `dumpMenus` for the half of the UI that is views. Off by default —
        // it is a few hundred lines — and the first thing to turn on when a
        // control cannot be found.
        if ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_DUMP_VIEWS"] != nil,
           let window = KeyRouter.mainWindow() {
            dumpViews(in: window)
        }

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
        // Checked by hash rather than by count below, so that a run pointed at
        // a home that already holds photos still says something true.
        log("library self-test: the library starts with \(app.catalog.count) photo(s)")

        // 2. Lightroom's keys, as AppKit sees them. A disabled item would
        //    swallow its key equivalent silently (see UndoMenu.swift).
        for (title, key) in [("Library", "g"), ("Loupe", "e"), ("Develop", "d"), ("Red", "6"),
                             ("Yellow", "7"), ("Green", "8"), ("Blue", "9"),
                             ("Before / After", "\\"), ("Brush Tool", "b"),
                             ("Targeted Adjustment Tool", "t")] {
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

        // macOS's own sidebar shortcut, checked here with the rest of them and
        // again at the end of the run, where it is pressed. Two things can take
        // it away and neither shows up as a crash: SwiftUI can rebuild the item
        // without the shortcut, and SwiftUI's *own* sidebar command — the
        // "Toggle Sidebar" item it installs for a `NavigationSplitView`, which
        // wants ⌥⌘S too — can win the collision instead of losing it.
        let folders = findMenuItemDeep(titled: "Show/Hide Folders")
        check(folders != nil, "View › Show/Hide Folders is in the menu")
        check(folders?.keyEquivalent == "s",
              "…carrying 's' (got '\(folders?.keyEquivalent ?? "missing")')")
        check(folders?.keyEquivalentModifierMask == [.command, .option],
              "…with ⌥⌘ (got \(folders?.keyEquivalentModifierMask.rawValue ?? 0))")
        check(folders?.isEnabled == true, "…and enabled, so the key is not swallowed")
        check(menu(containing: folders) == "View",
              "…in the View menu (got \(menu(containing: folders) ?? "nowhere"))")
        let claimants = menuItems { $0.keyEquivalent == "s"
            && $0.keyEquivalentModifierMask == [.command, .option] }
        check(claimants.count == 1,
              "…and it is the only item in the menu bar claiming ⌥⌘S "
                  + "(\(claimants.map(\.title)))")

        // 3. Fill the library through the real import path, with one photo in a
        //    subfolder so the Folders panel has a tree to show and not a row.
        let path = ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_IMPORT_DIR"] ?? "testdata"
        let source = stageSourceWithAJPEG(URL(fileURLWithPath: path, isDirectory: true),
                                          subfolder: folderSubfolderName)
        stagedSource = source
        log("library self-test: importing \(source.path)")
        app.importModel.setSource(source)
        waitForScan(app.importModel) {
            // By hash, not by count: "how many photos" is a number that
            // depends on what the home this run was pointed at already held.
            // "Every file I imported has a cell" does not.
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
                // Same allowance as above: a file the decoder cannot read never
                // becomes a photo, so it cannot be a cell either.
                check(app.catalog.count >= expected.count - undecodable.count,
                      "the grid has at least the photos that could be imported "
                          + "(\(app.catalog.count) cells, \(expected.count) checked, "
                          + "\(undecodable.count) undecodable)")
                check(app.catalog.photos.allSatisfy { $0.firstLocation != nil },
                      "every catalogued photo has a file on disk")
                // The run is split in two — see `SelfTest.Mode.library2`. Both
                // halves import into a throwaway library of their own; from
                // here they check different things.
                guard mode == .library else {
                    waitForPreviews(app) {
                        guard let window = KeyRouter.mainWindow() else {
                            check(false, "a window to drive the grid with")
                            finishLibrary(failures)
                        }
                        runGridScrollChecks(app: app, window: window, check: check,
                                            failures: { failures })
                    }
                    return
                }
                runLibraryKeys(app: app, check: check, failures: { failures })
            }
        }
    }

    static func runLibraryKeys(app: AppModel,
                                       check: @escaping (Bool, String) -> Void,
                                       failures: @escaping () -> [String]) {
        phase("grid keys")
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
                check(waitForCells(ids[0...2].map(cellID)),
                      "the grid put a click target behind every cell")
                check(clickCell(cellID(ids[0])), "clicked the first cell")
                check(app.highlightedPhotoIDs == [ids[0]],
                      "a plain click selects one (\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· 1 selected"),
                      "the status bar says so (\(app.libraryCountLabel))")

                check(clickCell(cellID(ids[2]), modifiers: .shift), "shift-clicked the third cell")
                check(app.highlightedPhotoIDs == [ids[0], ids[1], ids[2]],
                      "shift-click selects the range of three "
                          + "(\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· 3 selected"),
                      "the status bar says three (\(app.libraryCountLabel))")

                check(clickCell(cellID(ids[1]), modifiers: .command), "cmd-clicked the middle cell")
                check(app.highlightedPhotoIDs == [ids[0], ids[2]],
                      "cmd-click toggles one out of the selection "
                          + "(\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· 2 selected"),
                      "the status bar says two (\(app.libraryCountLabel))")

                // 4a. What a drag out of this selection would hand over: the
                //     two photos' own files, in grid order. The drag session
                //     itself cannot be driven from here — which cells travel is
                //     the drag container's rule — so what is checked is the
                //     payload the container asks the grid for.
                let dragged = app.draggedFiles(for: app.highlightedPhotoIDs)
                let wanted = app.highlightedPhotoIDs
                    .compactMap { app.catalog.photo(id: $0)?.firstLocation }
                check(dragged.map(\.url.path) == wanted,
                      "a drag of the selection carries both photos' originals "
                          + "(\(dragged.map { $0.url.lastPathComponent }))")
                check(dragged.map(\.id) == app.highlightedPhotoIDs,
                      "…each still named by its own photo, which is what the drag "
                          + "container matches the cells by")
                let alone = app.draggedFiles(for: [ids[1]])
                check(alone.map(\.id) == [ids[1]],
                      "…and a drag of one photo carries only that one "
                          + "(\(alone.map { $0.url.lastPathComponent }))")

                // ⌘A is a key, and it is *not* a menu item — the router owns it.
                sendKey("a", modifiers: .command, window: window, virtualKey: 0)
            },
            {
                check(app.librarySelection.count == ids.count,
                      "cmd-A selected all \(ids.count) (\(app.librarySelection.count))")
                check(app.libraryCountLabel.hasSuffix("· \(ids.count) selected"),
                      "the status bar says all of them (\(app.libraryCountLabel))")

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
                // 6. Return opens the *loupe*, which is Lightroom's binding for
                //    it: the Library module's other view, not the develop
                //    module. (The loupe itself is checked in `library2`.)
                sendKey("", modifiers: [], window: window, virtualKey: 36, viaQueue: true)
            },
            {
                check(app.mode == .library, "Return does not leave the Library module")
                check(app.libraryViewMode == .loupe,
                      "…it opens the loupe, as in Lightroom "
                          + "(\(app.libraryViewMode.rawValue))")
                check(findCanvas() == nil, "…and never the develop canvas")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
            {
                check(app.libraryViewMode == .grid, "g came back to the grid")
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
                // 12. A double-click opens the loupe (Lightroom), not Develop.
                check(clickCell(cellID(ids[0]), clickCount: 2), "double-clicked the first cell")
            },
            {
                check(app.mode == .library && app.libraryViewMode == .loupe
                          && app.loupePhoto?.id == ids[0],
                      "a double-click opened that photo in the loupe "
                          + "(mode \(app.mode.rawValue))")
                check(findCanvas() == nil, "…without a develop canvas")
                sendKey("g", modifiers: [], window: window, virtualKey: 5)
            },
        ]

        runSteps(steps, model: app) {
            // 13. What all of that looks like: one red cell, the ring on it.
            try? FileManager.default.createDirectory(at: outputDirectory,
                                                     withIntermediateDirectories: true)
            writeScreenshot(of: window, named: "selftest-library.png")
            runPreviewChecks(app: app, window: window, subject: subject,
                             check: check, failures: failures)
        }
    }

    // MARK: - The preview checks

    /// The development-aware previews, end to end: the grid builds embedded ones
    /// for an undeveloped library, and developing a photo replaces *that* photo's
    /// preview with a render of the edit.
    ///
    /// The witnesses are deliberately outside the app: `previews.sqlite` read
    /// through a second connection, and the mean luminance of the two `CGImage`s
    /// the grid actually held. `PreviewBuilder`'s own bookkeeping is what is
    /// under test, so it cannot be the thing that says the test passed.
    static func runPreviewChecks(app: AppModel, window: NSWindow, subject: Int64,
                                         check: @escaping (Bool, String) -> Void,
                                         failures: @escaping () -> [String]) {
        phase("previews")
        let ids = app.catalog.ids
        waitForPreviews(app) {
            // 14. Every cell the grid built has an embedded preview, in memory
            //     and in previews.sqlite. Only the cells `LazyVGrid` realised
            //     ask for one at all, which is why this counts them rather than
            //     asserting over the whole library.
            let inMemory = ids.filter { id in
                app.catalog.photo(id: id).flatMap { app.previews.cached($0) } != nil
            }
            check(!inMemory.isEmpty,
                  "the grid built previews in memory (\(inMemory.count) of \(ids.count))")
            let embedded = inMemory.filter { storedPreview($0)?.source == .embedded }
            check(embedded.count == inMemory.count,
                  "…and every one of them is an embedded preview row in previews.sqlite "
                      + "(\(embedded.count) of \(inMemory.count))")
            let sized = inMemory.compactMap { storedPreview($0) }
            check(sized.allSatisfy { max($0.width, $0.height) <= PreviewBuilder.pixelSize },
                  "…at \(PreviewBuilder.pixelSize) px or less "
                      + "(\(sized.map { "\($0.width)x\($0.height)" }.joined(separator: " ")))")
            check(sized.allSatisfy { $0.fingerprint == nil },
                  "…with no edit fingerprint, because an embedded preview is not "
                      + "a rendition of an edit")

            let before = app.catalog.photo(id: subject).flatMap { app.previews.cached($0) }
            check(before != nil, "the subject has a preview to compare against")
            let beforeLuminance = before.map(meanLuminance) ?? 0
            log("library self-test: subject preview before the edit: "
                + "\(before.map { "\($0.width)x\($0.height)" } ?? "none") "
                + String(format: "mean luminance %.4f", beforeLuminance))

            // 15. Develop the subject: +2 EV, autosaved, then back to the grid.
            _ = clickCell(cellID(subject))
            sendKey("d", modifiers: [], window: window, virtualKey: 2)
            settle(app) {
                guard app.mode == .develop, app.currentPhotoID == subject else {
                    check(false, "d reopened the subject in develop")
                    finishLibrary(failures())
                }
                app.store.perform("Exposure") { $0.tone.exposure = 2 }
                check(app.store.edit.tone.exposure == 2, "the exposure change applied")
                waitForAutosave(app) {
                    check(!app.store.isDirty, "the autosave wrote the development")
                    let stored = storedDevelopmentFingerprint(subject)
                    check(stored != nil, "…and the library has a development #1 for it")
                    check(stored == app.store.edit.fingerprint,
                          "…whose fingerprint is the edit's own")
                    check(app.catalog.photo(id: subject)?.developmentFingerprint == stored,
                          "…and the catalog carries it, so the cell knows it is stale")
                    sendKey("g", modifiers: [], window: window, virtualKey: 5)
                    waitForRenderedPreview(app, photoID: subject, fingerprint: stored) {
                        finishPreviewChecks(app: app, window: window, subject: subject,
                                            fingerprint: stored,
                                            beforeLuminance: beforeLuminance,
                                            check: check, failures: failures)
                    }
                }
            }
        }
    }

    static func finishPreviewChecks(app: AppModel, window: NSWindow, subject: Int64,
                                            fingerprint: Data?, beforeLuminance: Double,
                                            check: @escaping (Bool, String) -> Void,
                                            failures: @escaping () -> [String]) {
        check(app.mode == .library, "g came back to the grid")
        let row = storedPreview(subject)
        check(row?.source == .rendered,
              "the subject's stored preview is a rendered one now "
                  + "(got \(row.map { String(describing: $0.source) } ?? "no row"))")
        check(row?.fingerprint == fingerprint,
              "…of development #1's edit, by fingerprint")
        check(row.map { $0.isCurrent(developmentFingerprint: fingerprint) } == true,
              "…and therefore current")

        let after = app.catalog.photo(id: subject).flatMap { app.previews.cached($0) }
        check(after != nil, "the grid holds the new picture in memory")
        let afterLuminance = after.map(meanLuminance) ?? 0
        log(String(format: "library self-test: subject preview after +2 EV: mean luminance "
                   + "%.4f (was %.4f)", afterLuminance, beforeLuminance))
        // +2 EV is two stops of light. Anything short of a frame that was
        // already clipped comes back visibly brighter, and "brighter" is the
        // whole claim: the grid is showing the development, not the camera's
        // embedded JPEG.
        check(afterLuminance > beforeLuminance,
              String(format: "…and it is brighter than the embedded preview was "
                     + "(%.4f > %.4f)", afterLuminance, beforeLuminance))

        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)
        writeScreenshot(of: window, named: "selftest-library-previews.png")
        // The same claim in the loupe, where the picture is a pipeline render
        // rather than a stored 512 px preview.
        runDevelopedLoupeChecks(app: app, window: window, subject: subject,
                                beforeLuminance: beforeLuminance, check: check) {
            runLensChecks(app: app, window: window, check: check, failures: failures)
        }
    }

    // MARK: - The lens in the develop status bar

    /// The develop bar names the lens the open photo was taken through, after
    /// the camera and in the same secondary style — and names nothing at all
    /// for a file that does not say, without the line moving.
    ///
    /// The expected text is probed from the *file*, not read out of the
    /// library, so this cannot pass by agreeing with the same import that
    /// filled the bar.
    static func runLensChecks(app: AppModel, window: NSWindow,
                              check: @escaping (Bool, String) -> Void,
                              failures: @escaping () -> [String]) {
        phase("lens")
        // Candidates come from the catalog — one photo the import gave a lens
        // and one it did not — and the text to expect is then read back out of
        // the *file*. Two probes rather than one per photo: a RAW probe is a
        // decoder set-up, and this run has a deadline to keep.
        // Smallest file first, in both cases: opening a photo decodes it, and a
        // hundred-megapixel frame costs seconds this run does not need to spend
        // to read a label off the status bar.
        let byCost = app.catalog.photos.filter { $0.url != nil }
            .sorted { $0.byteSize < $1.byteSize }
        let lensCandidate = byCost.first { $0.lensId != nil }
        let plainCandidate = byCost.first { $0.lensId == nil }
        var withLens: (id: Int64, description: String)?
        if let candidate = lensCandidate, let url = candidate.url,
           let info = try? ImageDecoder.probe(url: url), let model = info.lensModel,
           !model.isEmpty {
            let make = info.lensMake ?? ""
            withLens = (candidate.id, "\(make) \(model)".trimmingCharacters(in: .whitespaces))
        }
        check(lensCandidate == nil || withLens != nil,
              "a photo the import gave a lens has one in its file too "
                  + "(\(lensCandidate?.originalName ?? "none"))")
        var withoutLens: Int64?
        if let candidate = plainCandidate, let url = candidate.url,
           let info = try? ImageDecoder.probe(url: url),
           (info.lensModel ?? "").isEmpty {
            withoutLens = candidate.id
        }
        let subjectLabel = withLens.map { "\($0.id) '\($0.description)'" } ?? "none"
        let plainLabel = withoutLens.map(String.init) ?? "none"
        log("library self-test: lens subject = \(subjectLabel), lensless subject = \(plainLabel)")

        guard let subject = withLens else {
            // Nothing in this folder names its glass. Then the one thing to
            // check is that the bar does not invent a label — and that the
            // line it would have gone on is where it always is.
            checkNoLensLabel(app: app, window: window, photoID: withoutLens,
                             reference: nil, check: check) {
                finishLibrary(failures())
            }
            return
        }

        _ = clickCell(cellID(subject.id))
        sendKey("d", modifiers: [], window: window, virtualKey: 2)
        waitForProbe(app, photoID: subject.id) {
            check(app.mode == .develop && app.currentPhotoID == subject.id,
                  "d opened the photo whose file names a lens")
            check(app.lensDescription == subject.description,
                  "the model says the lens the file says (got '\(app.lensDescription)', "
                      + "want '\(subject.description)')")
            let lens = controlFrame(named: "develop-lens")
            let camera = controlFrame(named: "develop-camera")
            let name = controlFrame(named: "develop-name")
            check(lens != nil, "the develop status bar draws a lens label")
            check(camera != nil, "…and the camera label it follows")
            if let lens, let camera {
                check(lens.minX >= camera.maxX,
                      "…after the camera, not before it (lens \(lens.minX), "
                          + "camera ends \(camera.maxX))")
                check(sameLine(lens, camera),
                      "…on the camera's own line (lens \(lens), camera \(camera))")
            }
            writeScreenshot(of: window, named: "selftest-develop-lens.png")
            // The same bar, on a file that names no lens: no label, and the
            // filename at the other end of the bar has not moved a pixel.
            checkNoLensLabel(app: app, window: window, photoID: withoutLens,
                             reference: name, check: check) {
                finishLibrary(failures())
            }
        }
    }

    /// Opens `photoID` in develop (when there is one) and asserts the bar shows
    /// no lens, on the same line `reference` was drawn on.
    static func checkNoLensLabel(app: AppModel, window: NSWindow, photoID: Int64?,
                                 reference: NSRect?,
                                 check: @escaping (Bool, String) -> Void,
                                 then done: @escaping () -> Void) {
        guard let photoID else {
            log("library self-test: every importable file here names its lens")
            backToTheGrid(app: app, window: window, then: done)
            return
        }
        if app.mode == .library { _ = clickCell(cellID(photoID)) }
        sendKey("g", modifiers: [], window: window, virtualKey: 5)
        settle(app) {
            _ = clickCell(cellID(photoID))
            sendKey("d", modifiers: [], window: window, virtualKey: 2)
            waitForProbe(app, photoID: photoID) {
                check(app.lensDescription.isEmpty,
                      "a file with no EXIF lens gets no lens in the bar "
                          + "(got '\(app.lensDescription)')")
                check(controlFrame(named: "develop-lens") == nil,
                      "…and no label is drawn for it at all")
                if let reference, let name = controlFrame(named: "develop-name") {
                    check(sameLine(name, reference),
                          "…and the bar's line has not moved (\(name) vs \(reference))")
                }
                backToTheGrid(app: app, window: window, then: done)
            }
        }
    }

    static func backToTheGrid(app: AppModel, window: NSWindow,
                              then done: @escaping () -> Void) {
        sendKey("g", modifiers: [], window: window, virtualKey: 5)
        settle(app) { done() }
    }

    /// Polls until the open photo's metadata probe has landed — the camera and
    /// lens labels are cleared when a file is opened and filled in by an
    /// asynchronous probe, so "the bar is empty" is only an answer once it has
    /// come back. Bounded on its own so a photo whose file names neither can
    /// never eat the whole run's deadline.
    static func waitForProbe(_ app: AppModel, photoID: Int64, attemptsLeft: Int = 100,
                             then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let landed = app.currentPhotoID == photoID
                && (!app.cameraDescription.isEmpty || !app.lensDescription.isEmpty)
            if !landed, attemptsLeft > 0, Date() < deadline {
                waitForProbe(app, photoID: photoID, attemptsLeft: attemptsLeft - 1, then: body)
            } else {
                body()
            }
        }
    }

    /// Deletes every location row of a photo through the library API — the
    /// "someone moved the files" case, done the way the app would do it.
    static func removeLocations(of photoID: Int64) {
        guard let library = try? Library.openDefault() else { return }
        defer { try? library.close() }
        for location in (try? library.locations(for: photoID)) ?? [] {
            if let id = location.id { _ = try? library.removeLocation(id: id) }
        }
    }

    /// Polls until the preview queue has drained.
    static func waitForPreviews(_ app: AppModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if Date() < deadline, app.tasks.tasks.contains(where: { $0.title == "Building previews" }) {
                waitForPreviews(app, then: body)
            } else {
                body()
            }
        }
    }

    /// Polls until the store holds a rendered preview of this edit — a full
    /// decode of a RAW at 512 px, which is seconds rather than milliseconds.
    static func waitForRenderedPreview(_ app: AppModel, photoID: Int64,
                                               fingerprint: Data?,
                                               then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let row = storedPreview(photoID)
            let ready = row?.source == .rendered && row?.fingerprint == fingerprint
                && app.catalog.photo(id: photoID).flatMap { app.previews.cached($0) } != nil
            if Date() < deadline, !ready {
                waitForRenderedPreview(app, photoID: photoID, fingerprint: fingerprint, then: body)
            } else {
                body()
            }
        }
    }

    /// The autosave is a one-second timer, so this is not a `settle`.
    static func waitForAutosave(_ app: AppModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if Date() < deadline, app.store.isDirty {
                waitForAutosave(app, then: body)
            } else {
                settle(app, then: body)
            }
        }
    }

    /// What `previews.sqlite` holds, read through its own connection — the app's
    /// builder is what is under test, so it cannot be the witness.
    static func storedPreview(_ id: Int64) -> StoredPreview? {
        guard let library = try? Library.openDefault() else { return nil }
        defer { try? library.close() }
        guard let hash = (try? library.photo(id: id))??.hash,
              let store = try? PreviewStore.open(for: library) else { return nil }
        defer { try? store.close() }
        return (try? store.preview(for: hash)) ?? nil
    }

    static func storedDevelopmentFingerprint(_ id: Int64) -> Data? {
        storedDevelopment(id)?.fingerprint
    }

    static func storedDevelopment(_ id: Int64) -> EditState? {
        guard let library = try? Library.openDefault() else { return nil }
        defer { try? library.close() }
        return ((try? library.developments(for: id)) ?? []).first?.edit
    }

    /// Rec.709 luminance of a `CGImage`, averaged — the one number that says
    /// "this is a different, brighter picture" without depending on the file.
    static func meanLuminance(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = context.data else { return 0 }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1])
            let b = Double(pixels[i * 4 + 2])
            total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return total / Double(w * h)
    }

    /// What the *database* holds, read through a second connection — the app's
    /// own catalog is exactly what is under test, so it cannot be the witness.
    static func storedColor(_ id: Int64) -> ColorLabel? {
        guard let library = try? Library.openDefault() else { return nil }
        defer { try? library.close() }
        return (try? library.photo(id: id))??.color
    }

    static func describe(_ color: ColorLabel?) -> String {
        color.map(\.name) ?? "nil"
    }

    static func finishLibrary(_ failures: [String]) -> Never {
        if failures.isEmpty {
            log("library self-test: PASS")
            exit(0)
        }
        log("library self-test: FAILED — \(failures.count) check(s): "
            + failures.joined(separator: "; "))
        exit(6)
    }
}

