import AppKit
import CoreGraphics
import GrayroomCore
import GrayroomLibrary
import GrayroomUI
import ImageIO
import UniformTypeIdentifiers

/// The culling aids, in the running app: that the import scored every photo,
/// that Library › Sort By reorders the grid, and that Library › Select Similar
/// Photos rings the frames that look alike.
///
/// The last stretch of the `library2` run — see `SelfTest.Mode.library2`. It
/// imports two more photos of its own (the same picture in two containers), so
/// it goes after everything that counts what the grid holds.
extension SelfTest {
    static func runCullingChecks(app: AppModel, window: NSWindow,
                                 check: @escaping (Bool, String) -> Void,
                                 failures: @escaping () -> [String]) {
        phase("culling aids")

        // 1. The menu, as AppKit sees it, in Lightroom's two places: Sort under
        //    View, the selection command under Edit. Bare `Button`s with no key
        //    equivalents, as Lightroom gives them none either.
        for title in ["Sort", "Capture Time", "File Name", "Aesthetic Score",
                      "Ascending", "Descending"] {
            let item = findMenuItemDeep(titled: title)
            check(item != nil, "'\(title)' is in the menu bar")
            check(menu(containing: item) == "View",
                  "…in the View menu (got \(menu(containing: item) ?? "nowhere"))")
            check(item?.isEnabled == true, "…and enabled, so picking it does something")
        }
        let similar = findMenuItemDeep(titled: "Select Similar Photos")
        check(similar != nil, "'Select Similar Photos' is in the menu bar")
        check(menu(containing: similar) == "Edit",
              "…in the Edit menu (got \(menu(containing: similar) ?? "nowhere"))")
        check(similar?.isEnabled == true, "…and enabled")

        // 2. The import scored every photo it could — the whole point of doing
        //    it at import rather than on demand. Read back through a second
        //    connection, because the catalog is what is under test.
        let scored = app.catalog.photos.filter { $0.aestheticScore != nil }
        check(scored.count == app.catalog.count,
              "every imported photo has an aesthetics score "
                  + "(\(scored.count) of \(app.catalog.count))")
        check(scored.allSatisfy { ($0.aestheticScore ?? 2) >= -1 && ($0.aestheticScore ?? 2) <= 1 },
              "…and every score is in −1…1")
        check(storedMissingAnalysisCount() == 0,
              "…and the database agrees (\(storedMissingAnalysisCount()) unanalysed)")

        // The export checks leave the app in Develop on an open file. Both
        // commands under test are the Library module's, and the Folders panel
        // may have been left on a folder; the sort and the similarity both work
        // on what the grid shows.
        app.showLibrary()
        check(app.mode == .library,
              "back in the Library module (got \(app.mode.rawValue))")
        app.folderSelection = .all

        let steps: [() -> Void] = [
            {
                // 3. Sort By, driven through the real menu items.
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
                check(sendMenuItem(titled: "Aesthetic Score"), "picked View › Sort › Aesthetic Score")
            },
            {
                let worstFirst = app.catalog.ids.compactMap { app.catalog.photo(id: $0) }
                    .compactMap(\.aestheticScore)
                check(worstFirst == worstFirst.sorted(by: >),
                      "Aesthetic Score descending puts the best frame first "
                          + "(\(worstFirst.map { String(format: "%.2f", $0) }))")
                // Back to Lightroom's default before anything else looks at the
                // grid.
                check(sendMenuItem(titled: "Capture Time"), "picked View › Sort › Capture Time")
                check(sendMenuItem(titled: "Ascending"), "picked View › Sort › Ascending")
            },
            {
                check(app.sortKey == .captureTime && app.sortAscending,
                      "the grid is back on capture time, ascending")
                // 4. Two more photos: the same picture in two containers, which
                //    is the one thing in this library that *is* a near
                //    duplicate. Imported through the real importer, so they are
                //    scored and fingerprinted the way the rest were.
                twins = importTwins()
                check(twins.count == 2, "staged two near-identical photos (\(twins.count))")
                app.reloadCatalog()
            },
        ]

        runSteps(steps, model: app) {
            guard twins.count == 2 else { finishLibrary(failures()) }
            check(app.catalog.photo(id: twins[0]) != nil && app.catalog.photo(id: twins[1]) != nil,
                  "the two of them are in the grid")
            app.libraryClick(twins[0], modifiers: [])
            check(app.highlightedPhotoIDs == [twins[0]], "one of them is selected")
            check(sendMenuItem(titled: "Select Similar Photos"),
                  "picked Edit › Select Similar Photos")
            waitForSimilar(app) {
                let selected = Set(app.highlightedPhotoIDs)
                check(selected == Set(twins),
                      "the selection is exactly the two photos that look alike "
                          + "(\(names(app, app.highlightedPhotoIDs)))")
                check(app.libraryCountLabel.hasSuffix("· 2 selected"),
                      "the status bar says two (\(app.libraryCountLabel))")
                check(app.librarySelection.anchor == twins[0],
                      "…and the anchor is still the photo the user picked")
                finishLibrary(failures())
            }
        }
    }

    /// The two photos this check imports for itself.
    static var twins: [Int64] = []

    /// Polls until Select Similar Photos has finished — it reads every stored
    /// feature print on the library queue, so it is not a `settle`.
    static func waitForSimilar(_ app: AppModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if Date() < deadline,
               app.tasks.tasks.contains(where: { $0.title == "Finding similar photos" }) {
                waitForSimilar(app, then: body)
            } else {
                body()
            }
        }
    }

    /// Writes one picture twice — as a JPEG and as a PNG — and imports both.
    /// Different bytes, so two photos; the same picture, so a feature-print
    /// distance near zero.
    static func importTwins() -> [Int64] {
        let directory = outputDirectory.appendingPathComponent("similar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (width, height) = (320, 240)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8((x + y) * 255 / (width + height - 2))
                let i = (y * width + x) * 4
                bytes[i] = v
                bytes[i + 1] = UInt8(255 - Int(v))
                bytes[i + 2] = 128
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(
                                      rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else {
            log("library self-test: could not build the near-duplicate pair")
            return []
        }
        var urls: [URL] = []
        for (name, type) in [("twin.jpg", UTType.jpeg), ("twin.png", UTType.png)] {
            let url = directory.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { urls.append(url) }
        }
        guard let library = try? Library.openDefault() else { return [] }
        defer { try? library.close() }
        let importer = Importer(library: library)
        return importer.importFiles(urls).map(\.photoID)
    }

    /// What the *database* says is still unanalysed, read through a second
    /// connection.
    static func storedMissingAnalysisCount() -> Int {
        guard let library = try? Library.openDefault() else { return -1 }
        defer { try? library.close() }
        return ((try? library.photoIDsMissingAnalysis()) ?? []).count
    }

    static func names(_ app: AppModel, _ ids: [Int64]) -> String {
        ids.compactMap { app.catalog.photo(id: $0)?.originalName }.joined(separator: ", ")
    }
}
