import AppKit
import GrayroomCore
import GrayroomLibrary

extension SelfTest {
    @MainActor
    static func runFolderCompactionChecks() async {
        do {
            let source = outputDirectory.appendingPathComponent("folders-\(UUID().uuidString)")
            let library = try Library.openDefault()
            defer { try? library.close() }
            var ids: [Int64] = []
            for (index, path) in ["trip/direct.png", "trip/day/a.png", "elsewhere/b.png"].enumerated() {
                let url = source.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ImageWriter.write(image: FloatImage(width: 8, height: 8,
                                                        pixels: Array(repeating: Float(index + 1) / 4, count: 8 * 8 * 4)),
                                      to: url, format: .png)
                ids.append(try Importer(library: library).importFile(at: url).photoID)
            }
            let app = AppModel.shared
            app.reloadCatalog()
            let parent = source.appendingPathComponent("trip").standardizedFileURL.path
            app.folderSelection = .folder(path: parent)
            app.browser.expandAncestors(of: parent)
            guard let window = KeyRouter.mainWindow() else { fail("missing editor window") }
            await waitForLoading { sidebarRow(FolderSidebar.rowIdentifier(parent), in: window) != nil }
            guard app.visiblePhotoIDs == Array(ids.prefix(2)) else { fail("parent filter setup failed") }
            _ = try library.deletePhoto(id: ids[0])
            app.reloadCatalog()
            try await Task.sleep(for: .milliseconds(100))
            guard app.folderSelection == .folder(path: parent), app.visiblePhotoIDs == [ids[1]] else {
                fail("folder compaction replaced the selected parent filter")
            }
            guard sidebarRow(FolderSidebar.rowIdentifier(parent), in: window) != nil else {
                fail("the selected parent no longer has a sidebar row")
            }
            guard everyWindowIsOutOfTheWay() else { fail("test windows moved above desktop") }
            log("folders self-test: PASS — selected parent and its row survive compaction")
            exit(0)
        } catch { fail("folders self-test: \(error)") }
    }
}
