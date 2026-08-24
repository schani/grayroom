import Foundation
import XCTest
@testable import GrayroomUI

/// The Folders panel's model, without a window: the shape of the tree, the
/// counts on it, and what a click on a row filters the grid to.
final class FolderTreeTests: XCTestCase {

    /// The catalog rows the panel is built from — id, and the paths the library
    /// has for that photo.
    private func photo(_ id: Int64, _ locations: String...) -> CatalogPhoto {
        CatalogPhoto(id: id, originalName: "photo-\(id).dng", locations: locations.sorted())
    }

    private func tree(_ photos: [CatalogPhoto]) -> FolderTree {
        FolderTree(photos: photos, bootVolumeName: "Macintosh HD")
    }

    // MARK: - Shape

    /// Two volumes, one collapsed chain, and the counts that go with them.
    func testTreeShape() {
        let folders = tree([
            photo(1, "/Users/schani/Pictures/a.dng"),
            photo(2, "/Users/schani/Pictures/b.dng"),
            photo(3, "/Users/schani/Pictures/2024/c.dng"),
            photo(4, "/Volumes/Archive/x.dng"),
            photo(5, "/Volumes/Archive/trip/y.dng"),
        ])

        // Roots are volumes: `/` under the volume's own name, and each mounted
        // volume beside it — not two rows under the boot disk.
        XCTAssertEqual(folders.roots.map(\.name), ["Archive", "Macintosh HD"])
        XCTAssertEqual(folders.roots.map(\.id), ["/Volumes/Archive", "/"])
        XCTAssertEqual(folders.totalCount, 5)
        XCTAssertEqual(folders.missingCount, 0)

        let boot = folders.roots[1]
        XCTAssertEqual(boot.count, 3)
        XCTAssertEqual(boot.directCount, 0)
        // /Users and /Users/schani hold nothing and have one child each, so the
        // three of them are one row — Lightroom's "parent path in that spot".
        XCTAssertEqual(boot.children.count, 1)
        let pictures = boot.children[0]
        XCTAssertEqual(pictures.name, "Users/schani/Pictures")
        XCTAssertEqual(pictures.id, "/Users/schani/Pictures")
        XCTAssertEqual(pictures.count, 3)
        XCTAssertEqual(pictures.directCount, 2)
        XCTAssertEqual(pictures.children.map(\.name), ["2024"])
        XCTAssertEqual(pictures.children[0].id, "/Users/schani/Pictures/2024")
        XCTAssertEqual(pictures.children[0].count, 1)
        XCTAssertTrue(pictures.children[0].children.isEmpty)

        let archive = folders.roots[0]
        XCTAssertEqual(archive.count, 2)
        XCTAssertEqual(archive.directCount, 1)
        XCTAssertEqual(archive.children.map(\.name), ["trip"])
        XCTAssertEqual(archive.children[0].id, "/Volumes/Archive/trip")
    }

    /// A volume is a place. Its single child is a row of its own even when the
    /// volume itself holds nothing.
    func testRootIsNeverCollapsedIntoItsChild() {
        let folders = tree([photo(1, "/Users/x.dng")])
        XCTAssertEqual(folders.roots.map(\.name), ["Macintosh HD"])
        XCTAssertEqual(folders.roots[0].id, "/")
        XCTAssertEqual(folders.roots[0].children.map(\.name), ["Users"])
        XCTAssertEqual(folders.roots[0].children.map(\.id), ["/Users"])
    }

    /// A photo directly on a volume: the volume row carries it.
    func testPhotoAtTheVolumeRoot() {
        let folders = tree([photo(1, "/a.dng"), photo(2, "/Volumes/Card/b.dng")])
        XCTAssertEqual(folders.roots.map(\.name), ["Card", "Macintosh HD"])
        XCTAssertEqual(folders.roots[1].directCount, 1)
        XCTAssertEqual(folders.roots[1].count, 1)
        XCTAssertTrue(folders.roots[1].children.isEmpty)
        XCTAssertEqual(folders.roots[0].directCount, 1)
    }

    func testChildrenAreSortedCaseInsensitively() {
        let folders = tree([
            photo(1, "/pics/beta/a.dng"),
            photo(2, "/pics/Alpha/b.dng"),
            photo(3, "/pics/gamma/c.dng"),
        ])
        // /pics has three children, so it is not collapsed into any of them.
        let pics = folders.roots[0].children[0]
        XCTAssertEqual(pics.name, "pics")
        XCTAssertEqual(pics.children.map(\.name), ["Alpha", "beta", "gamma"])
    }

    /// The same photo filed in two directories is one photo everywhere: once in
    /// each of the two, and once — not twice — in the ancestor they share.
    func testAPhotoInTwoDirectoriesIsCountedOncePerAncestor() {
        let folders = tree([
            photo(1, "/pics/2024/a.dng", "/pics/2025/a.dng"),
            photo(2, "/pics/2024/b.dng"),
        ])
        let pics = folders.roots[0].children[0]
        XCTAssertEqual(pics.name, "pics")
        XCTAssertEqual(pics.count, 2)
        XCTAssertEqual(pics.directCount, 0)
        XCTAssertEqual(pics.children.map(\.count), [2, 1])
        XCTAssertEqual(pics.children.map(\.directCount), [2, 1])
        XCTAssertEqual(folders.roots[0].count, 2)
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/pics")), [1, 2])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/pics/2025")), [1])
    }

    /// Two files of the same photo in one directory still count as one photo.
    func testTwoFilesOfOnePhotoInOneDirectory() {
        let folders = tree([photo(1, "/pics/a.dng", "/pics/copy-of-a.dng")])
        let pics = folders.roots[0].children[0]
        XCTAssertEqual(pics.count, 1)
        XCTAssertEqual(pics.directCount, 1)
    }

    // MARK: - Row labels

    /// A collapsed chain is drawn as two lines: the folder, and the parents
    /// folded into its row. Everything else is one line.
    func testLeafNameAndParentChain() {
        let folders = tree([
            photo(1, "/Users/schani/Pictures/a.dng"),
            photo(2, "/Users/schani/Pictures/2024/c.dng"),
            photo(3, "/Volumes/Archive/x.dng"),
        ])

        // A volume is its own leaf: the row has nothing folded into it.
        let boot = folders.roots[1]
        XCTAssertEqual(boot.leafName, "Macintosh HD")
        XCTAssertNil(boot.parentChain)
        XCTAssertEqual(boot.name, "Macintosh HD")

        let archive = folders.roots[0]
        XCTAssertEqual(archive.leafName, "Archive")
        XCTAssertNil(archive.parentChain)

        // The chain: the folder the row selects is "Pictures", and the two
        // directories folded away above it are the second line.
        let pictures = boot.children[0]
        XCTAssertEqual(pictures.id, "/Users/schani/Pictures")
        XCTAssertEqual(pictures.leafName, "Pictures")
        XCTAssertEqual(pictures.parentChain, "Users/schani")
        XCTAssertEqual(pictures.name, "Users/schani/Pictures")

        // A folder that folds nothing away has no second line at all.
        let year = pictures.children[0]
        XCTAssertEqual(year.leafName, "2024")
        XCTAssertNil(year.parentChain)
        XCTAssertEqual(year.name, "2024")
    }

    /// One folded parent is still a chain — the second line reads "pics".
    func testChainOfOne() {
        let folders = tree([photo(1, "/pics/2024/a.dng")])
        let node = folders.roots[0].children[0]
        XCTAssertEqual(node.id, "/pics/2024")
        XCTAssertEqual(node.leafName, "2024")
        XCTAssertEqual(node.parentChain, "pics")
    }

    /// `name` is `parentChain` and `leafName` joined, everywhere — that is the
    /// invariant the panel's sort order rests on.
    func testNameIsTheChainJoined() {
        let folders = tree([
            photo(1, "/Users/schani/Pictures/a.dng"),
            photo(2, "/Users/schani/Pictures/2024/c.dng"),
            photo(3, "/Volumes/Archive/trip/y.dng"),
            photo(4, "/Volumes/Archive/x.dng"),
        ])
        for node in folders.allNodes {
            XCTAssertEqual(node.name,
                           node.parentChain.map { $0 + "/" + node.leafName } ?? node.leafName,
                           "\(node.id)")
            XCTAssertFalse(node.leafName.contains("/"), "\(node.id)")
        }
    }

    // MARK: - Filtering

    /// A folder means itself *and everything below it*, and the prefix has to
    /// stop at a path-component boundary: `/a/b` is not `/a/bc`.
    func testFolderFilterMatchesOnComponentBoundaries() {
        let folders = tree([
            photo(1, "/a/b/one.dng"),
            photo(2, "/a/b/deeper/two.dng"),
            photo(3, "/a/bc/three.dng"),
            photo(4, "/a/four.dng"),
        ])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/a/b")), [1, 2])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/a/bc")), [3])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/a/b/deeper")), [2])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/a")), [1, 2, 3, 4])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/")), [1, 2, 3, 4])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/nothing")), [])

        XCTAssertTrue(FolderTree.directory("/a/b", isWithin: "/a/b"))
        XCTAssertTrue(FolderTree.directory("/a/b/c", isWithin: "/a/b"))
        XCTAssertFalse(FolderTree.directory("/a/bc", isWithin: "/a/b"))
        XCTAssertFalse(FolderTree.directory("/a", isWithin: "/a/b"))
        XCTAssertTrue(FolderTree.directory("/a", isWithin: "/"))
        XCTAssertTrue(FolderTree.directory("/", isWithin: "/"))
    }

    /// The grid's order is the catalog's order, filtered — never re-sorted.
    func testFilterKeepsCatalogOrder() {
        let folders = tree([
            photo(7, "/pics/g.dng"),
            photo(3, "/pics/a.dng"),
            photo(9, "/other/z.dng"),
            photo(1, "/pics/m.dng"),
        ])
        XCTAssertEqual(folders.photoIDs(for: .all), [7, 3, 9, 1])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/pics")), [7, 3, 1])
    }

    /// A photo the library remembers and has no file for is in "All
    /// Photographs" and in "Missing", and in no folder at all.
    func testMissing() {
        let folders = tree([
            photo(1, "/pics/a.dng"),
            photo(2),
            photo(3),
        ])
        XCTAssertEqual(folders.missingCount, 2)
        XCTAssertEqual(folders.totalCount, 3)
        XCTAssertEqual(folders.photoIDs(for: .missing), [2, 3])
        XCTAssertEqual(folders.photoIDs(for: .all), [1, 2, 3])
        XCTAssertEqual(folders.photoIDs(for: .folder(path: "/")), [1])
        XCTAssertEqual(folders.roots[0].count, 1)
    }

    func testEmptyCatalog() {
        let folders = tree([])
        XCTAssertTrue(folders.roots.isEmpty)
        XCTAssertEqual(folders.totalCount, 0)
        XCTAssertEqual(folders.missingCount, 0)
        XCTAssertEqual(folders.photoIDs(for: .all), [])
        XCTAssertEqual(FolderTree().totalCount, 0)
    }

    // MARK: - Lookup

    func testNodeLookupAddressesACollapsedChainByItsDeepestPath() {
        let folders = tree([photo(1, "/Users/schani/Pictures/a.dng")])
        XCTAssertEqual(folders.node(at: "/Users/schani/Pictures")?.name,
                       "Users/schani/Pictures")
        // The rows that were folded away are not selectable, because they are
        // not rows.
        XCTAssertNil(folders.node(at: "/Users"))
        XCTAssertNotNil(folders.node(at: "/"))
        XCTAssertEqual(folders.allNodes.map(\.id), ["/", "/Users/schani/Pictures"])
    }

    // MARK: - Paths

    func testDirectoryOfPath() {
        XCTAssertEqual(FolderTree.directory(ofPath: "/a/b/c.dng"), "/a/b")
        XCTAssertEqual(FolderTree.directory(ofPath: "/c.dng"), "/")
        XCTAssertEqual(FolderTree.directory(ofPath: "c.dng"), "")
    }

    func testAncestorPaths() {
        XCTAssertEqual(FolderTree.ancestorPaths(of: "/a/b"), ["/", "/a", "/a/b"])
        XCTAssertEqual(FolderTree.ancestorPaths(of: "/"), ["/"])
        XCTAssertEqual(FolderTree.ancestorPaths(of: "/Volumes/X/a"),
                       ["/Volumes/X", "/Volumes/X/a"])
        XCTAssertEqual(FolderTree.ancestorPaths(of: "/Volumes/X"), ["/Volumes/X"])
        // A photo sitting in /Volumes itself is on the boot volume, because
        // /Volumes is a directory there — only what is *inside* it is a disk.
        XCTAssertEqual(FolderTree.ancestorPaths(of: "/Volumes"), ["/", "/Volumes"])
        XCTAssertEqual(FolderTree.ancestorPaths(of: "relative/path"), [])
    }

    /// The boot volume is named, not spelled `/`.
    func testBootVolumeNameIsSomething() {
        XCTAssertFalse(FolderTree.bootVolumeName().isEmpty)
        XCTAssertFalse(FolderTree.bootVolumeName().contains("/"))
    }
}
