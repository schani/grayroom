import AppKit
import GrayroomLibrary
import GrayroomUI

/// File › Export… on the Library's selection, in the `library2` run: the item's
/// live enablement, the sheet, the folder panel a multi-photo export asks for,
/// and the files that land in the folder.
extension SelfTest {
    /// The two photos this stretch exports. Small, synthetic and dated in 1999
    /// so they sort to the very top of the grid: a full-resolution export of a
    /// hundred-megapixel RAW is minutes per file, and a cell the grid has not
    /// laid out cannot be clicked.
    static let batchExportNames = ["batch-a.jpg", "batch-b.jpg"]

    static func runBatchExportChecks(app: AppModel, window: NSWindow,
                                     check: @escaping (Bool, String) -> Void,
                                     failures: @escaping () -> [String]) {
        phase("batch export")
        let source = outputDirectory.appendingPathComponent("batch-source", isDirectory: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = outputDirectory.appendingPathComponent("batch-export", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Imported behind the app's back and reloaded, the way the Folders
        // checks take a location away: the import *window* is not what is under
        // test here.
        var imported: [Int64] = []
        if let library = try? Library.openDefault() {
            let importer = Importer(library: library)
            for (index, name) in batchExportNames.enumerated() {
                let url = source.appendingPathComponent(name)
                guard writeSyntheticJPEG(to: url, seed: 40 + index * 40,
                                         captured: "1999:01:0\(index + 1) 12:00:00"),
                      let id = try? importer.importFile(at: url).photoID else { continue }
                imported.append(id)
            }
            try? library.close()
        }
        guard imported.count == 2 else {
            check(false, "two small photos to export (staged \(imported.count))")
            finishLibrary(failures())
        }
        // The first one's name is already taken in the destination, so the
        // export has to go round it rather than over it.
        let taken = destination.appendingPathComponent("batch-a.png")
        try? "not an export".write(to: taken, atomically: true, encoding: .utf8)

        var panel: (isOpenPanel: Bool, directories: Bool, files: Bool)?

        let steps: [() -> Void] = [
            {
                app.showLibrary()
                app.folderSelection = .all
                app.reloadCatalog()
                app.librarySelection.clear()
                app.libraryScrollTarget = imported[0]
            },
            {
                // 41. Nothing selected: File › Export… is dead, and being dead
                //     it swallows ⌘E — which is the behaviour, not a bug (see
                //     UndoMenu.swift). The item is validated live, so this is a
                //     question AppKit answers now rather than at launch.
                check(app.mode == .library && app.libraryViewMode == .grid,
                      "back in the grid (got \(app.mode.rawValue))")
                check(app.highlightedPhotoIDs.isEmpty,
                      "…with nothing highlighted (\(app.highlightedPhotoIDs.count))")
                check(!app.canExport, "…so there is nothing to export")
                let item = findMenuItemDeep(titled: "Export…")
                check(item != nil, "File › Export… is in the menu bar")
                check(item?.isEnabled == false,
                      "…and it is greyed out with an empty selection "
                          + "(enabled=\(item?.isEnabled.description ?? "no item"))")
                sendKey("e", modifiers: .command, window: window, virtualKey: 14)
            },
            {
                check(!app.isExportSheetPresented,
                      "…so ⌘E does nothing at all")
                // 42. Two photos highlighted — a plain click and a cmd-click,
                //     as real mouse events — and the item comes alive.
                check(clickCell(cellID(imported[0])), "clicked the first photo's cell")
                check(clickCell(cellID(imported[1]), modifiers: .command),
                      "cmd-clicked the second")
            },
            {
                check(Set(app.highlightedPhotoIDs) == Set(imported),
                      "both photos are highlighted (\(app.highlightedPhotoIDs))")
                check(app.canExport, "…so Export is live")
                let item = findMenuItemDeep(titled: "Export…")
                check(item?.isEnabled == true,
                      "…and the menu item says so, live "
                          + "(enabled=\(item?.isEnabled.description ?? "no item"))")
                check(app.exportJobs().count == 2,
                      "…and Export would write both (\(app.exportJobs().count))")
                check(sendMenuItem(titled: "Export…"), "sent File › Export…")
            },
            {
                check(app.isExportSheetPresented, "the export sheet came up")
                check(window.attachedSheet != nil, "…as a real sheet on the window")
                check(selectPopUpItem(named: "export-format", titled: "PNG (8-bit)"),
                      "picked PNG (8-bit), the same sheet as a single export")
            },
            {
                check(app.exportFormat == .png, "…and the format took (\(app.exportFormat))")
                // 43. Choose… now asks for a *folder*, because there is more
                //     than one photo to write.
                panel = returnOpensTheFolderPanel(in: window)
                check(panel?.isOpenPanel == true,
                      "Choose… opened an NSOpenPanel, not a save panel")
                check(panel?.directories == true && panel?.files == false,
                      "…that picks a directory and nothing else "
                          + "(directories=\(panel?.directories.description ?? "-"), "
                          + "files=\(panel?.files.description ?? "-"))")
                check(!app.isExportSheetPresented, "…and running it took the sheet down")
                // 44. Everything after the panel answers, which is the
                //     production path.
                app.exportBatch(to: destination)
                check(app.tasks.tasks.contains { $0.title == "Exporting 2 photos" },
                      "the batch registered a cancellable task "
                          + "(\(app.tasks.tasks.map(\.title)))")
                check(app.tasks.tasks.first { $0.title == "Exporting 2 photos" }?
                          .isCancellable == true,
                      "…with a cancel button on it")
            },
        ]

        runSteps(steps, model: app) {
            waitForExport(app) {
                let written = ((try? FileManager.default
                    .contentsOfDirectory(atPath: destination.path)) ?? []).sorted()
                log("library self-test: batch export wrote \(written)")
                check(written == ["batch-a-2.png", "batch-a.png", "batch-b.png"],
                      "the batch wrote one file per photo, going round the name that "
                          + "was already there (\(written))")
                check((try? String(contentsOf: taken, encoding: .utf8)) == "not an export",
                      "…without overwriting it")
                for name in ["batch-a-2.png", "batch-b.png"] {
                    let url = destination.appendingPathComponent(name)
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                        as? Int) ?? 0
                    check(size > 128, "…and \(name) is a real file (\(size) bytes)")
                }
                check(app.statusMessage == "Exported 2",
                      "…and the status bar says so (got \(app.statusMessage ?? "nil"))")
                check(app.errorMessage == nil,
                      "…with no error on the bar (\(app.errorMessage ?? "none"))")
                check(!app.tasks.tasks.contains { $0.title.hasPrefix("Exporting ") },
                      "…and the task went away")
                // 45. One photo selected is the single-file flow again — on
                //     *that* photo, out of the library, not on whatever Develop
                //     has open.
                app.libraryClick(imported[0], modifiers: [])
                let single = app.exportJobs()
                check(single.count == 1 && single.first?.stem == "batch-a",
                      "one photo highlighted is one job, named after its original "
                          + "(\(single.map(\.stem)))")
                check(single.first?.source?.lastPathComponent == batchExportNames[0],
                      "…and it renders that photo's own file "
                          + "(\(single.first?.source?.lastPathComponent ?? "none"))")
                runSortChecks(app: app, check: check, failures: failures)
            }
        }
    }

    /// Presses Return on the export sheet and reports what modal panel that put
    /// up — the folder panel a multi-photo export needs, read while it is on
    /// screen and then aborted.
    ///
    /// Same shape as `returnOpensTheSavePanel`, and for the same reason: the
    /// panel runs modally and starves the main queue, so it can only be
    /// answered from a run-loop timer in `.modalPanel` mode.
    static func returnOpensTheFolderPanel(in window: NSWindow)
        -> (isOpenPanel: Bool, directories: Bool, files: Bool) {
        var seen = (isOpenPanel: false, directories: false, files: false)
        let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
            guard let modal = NSApp.modalWindow as? NSSavePanel else { return }
            if let open = modal as? NSOpenPanel {
                seen = (true, open.canChooseDirectories, open.canChooseFiles)
            }
            NSApp.abortModal()
            timer.invalidate()
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        sendKey("\r", modifiers: [], window: window, virtualKey: 36)
        timer.invalidate()
        return seen
    }
}
