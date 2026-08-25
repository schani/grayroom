import AppKit
import GrayroomLibrary
import GrayroomUI

/// View › Sort in the running app: that the menu is there, and that its keys
/// and directions reorder the grid.
///
/// The last stretch of the `library2` run — see `SelfTest.Mode.library2`.
extension SelfTest {
    static func runSortChecks(app: AppModel,
                              check: @escaping (Bool, String) -> Void,
                              failures: @escaping () -> [String]) {
        phase("sort")

        // 1. The menu, as AppKit sees it, in Lightroom's place: Sort under
        //    View. Bare `Button`s with no key equivalents, as Lightroom gives
        //    them none either.
        for title in ["Sort", "Capture Time", "File Name", "Ascending", "Descending"] {
            let item = findMenuItemDeep(titled: title)
            check(item != nil, "'\(title)' is in the menu bar")
            check(menu(containing: item) == "View",
                  "…in the View menu (got \(menu(containing: item) ?? "nowhere"))")
            check(item?.isEnabled == true, "…and enabled, so picking it does something")
        }

        // The export checks leave the app in Develop on an open file, and the
        // Folders panel may have been left on a folder; the sort works on what
        // the grid shows.
        app.showLibrary()
        check(app.mode == .library,
              "back in the Library module (got \(app.mode.rawValue))")
        app.folderSelection = .all

        let steps: [() -> Void] = [
            {
                // 2. Sort, driven through the real menu items.
                check(sendMenuItem(titled: "File Name"), "picked View › Sort › File Name")
            },
            {
                let byName = app.catalog.photos
                    .sorted { $0.originalName.lowercased() == $1.originalName.lowercased()
                        ? $0.id < $1.id
                        : $0.originalName.lowercased() < $1.originalName.lowercased() }
                    .map(\.id)
                check(app.catalog.ids == byName,
                      "the grid is in file-name order (\(names(app, app.catalog.ids)))")
                check(app.visiblePhotoIDs == byName,
                      "…and so is the list the arrows and shift-ranges walk")
                check(app.sortKey == .fileName && app.sortAscending, "…ascending")
                check(sendMenuItem(titled: "Descending"), "picked View › Sort › Descending")
            },
            {
                let ascending = app.catalog.photos
                    .sorted { $0.originalName.lowercased() < $1.originalName.lowercased() }
                    .map(\.id)
                check(app.catalog.ids == ascending.reversed(),
                      "Descending turns the grid round (\(names(app, app.catalog.ids)))")
                check(app.visiblePhotoIDs == app.catalog.ids,
                      "…and the grid's list with it")
                // Back to Lightroom's default before anything else looks at the
                // grid.
                check(sendMenuItem(titled: "Capture Time"), "picked View › Sort › Capture Time")
                check(sendMenuItem(titled: "Ascending"), "picked View › Sort › Ascending")
            },
            {
                check(app.sortKey == .captureTime && app.sortAscending,
                      "the grid is back on capture time, ascending")
            },
        ]

        runSteps(steps, model: app) { finishLibrary(failures()) }
    }

    static func names(_ app: AppModel, _ ids: [Int64]) -> String {
        ids.compactMap { app.catalog.photo(id: $0)?.originalName }.joined(separator: ", ")
    }
}
