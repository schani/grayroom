import Foundation
import Observation

/// Everything the Library module's browser — the Folders panel plus the grid it
/// filters — knows, with no view in it.
///
/// The panel is a `List` and the grid is a `LazyVGrid`, and neither of them can
/// be asked a question in a unit test. So the *state* lives here instead: which
/// source is selected, which volumes are open, which photos that leaves on
/// screen, what the bottom bar says, and what happens to the grid's highlight
/// when the filter moves under it. `AppModel` owns one of these and forwards to
/// it; the views read it and write it back through bindings.
///
/// # Why the highlight lives here too
///
/// "The grid's selection keeps only ids still visible" is a rule about *both*
/// halves at once, and a rule that spans two objects belongs to neither of
/// them. Keeping `GridSelection` here is what makes that rule — and every arrow
/// key that walks the filtered list rather than the catalog — testable without
/// a window.
@Observable
public final class LibraryBrowserState {
    /// The tree the panel draws, rebuilt from the catalog.
    public private(set) var folders = FolderTree()

    /// The selected source. Setting it re-filters the grid and drops whatever
    /// the new source does not show from the highlight.
    public var selection: FolderSelection = .all {
        didSet {
            guard oldValue != selection else { return }
            refresh()
        }
    }

    /// Which folder rows are open, by path. Volumes are opened once, when they
    /// first appear; after that it is the user's business.
    public var expandedFolders: Set<String> = []

    /// Whether the Folders panel is showing at all.
    public var isSidebarVisible = true

    /// The grid's highlight — a set of photo ids, moved by clicks and arrows.
    public var photoSelection = LibrarySelection()

    /// What the grid draws, by id, in the catalog's order.
    public private(set) var visiblePhotoIDs: [Int64] = []

    private var visibleIDs: Set<Int64> = []
    private var catalogIDs: [Int64] = []
    /// Volumes the panel has already opened once, so closing one by hand
    /// survives the next rebuild.
    private var knownRoots: Set<String> = []

    public init() {}

    // MARK: - The catalog moved

    /// Rebuilds the tree from the catalog and re-filters the grid.
    ///
    /// Called after anything that changes which photos, or which files, the
    /// library holds: an import, a deletion, a location that went away. Cheap
    /// enough to do outright — one pass over the catalog — so there is no
    /// incremental path to get wrong.
    public func rebuild(from photos: [CatalogPhoto]) {
        folders = FolderTree(photos: photos)
        catalogIDs = photos.map(\.id)
        for root in folders.roots where !knownRoots.contains(root.id) {
            expandedFolders.insert(root.id)
            knownRoots.insert(root.id)
        }
        // A folder can stop existing — its last photo removed, or its chain
        // folded into another row. Falling back to the whole catalog is what
        // Lightroom does with a source that goes away.
        if case .folder(let path) = selection, folders.node(at: path) == nil {
            selection = .all       // `didSet` refilters
            return
        }
        refresh()
    }

    private func refresh() {
        visiblePhotoIDs = selection == .all ? catalogIDs : folders.photoIDs(for: selection)
        visibleIDs = Set(visiblePhotoIDs)
        photoSelection.retain(visibleIDs)
    }

    // MARK: - What the grid shows

    public func isVisible(_ id: Int64) -> Bool { visibleIDs.contains(id) }

    /// The rows the grid draws. Taken from the catalog on demand rather than
    /// cached, so a colour label written into the catalog is on screen without
    /// a reload; `.all` hands the array straight back, which is the common case
    /// and copies nothing.
    public func visiblePhotos(from photos: [CatalogPhoto]) -> [CatalogPhoto] {
        guard selection != .all else { return photos }
        return photos.filter { visibleIDs.contains($0.id) }
    }

    public var visibleCount: Int { visiblePhotoIDs.count }

    /// The grid's bottom-bar line: what is on screen, and how much of it is
    /// selected — of the *filtered* list, the way Lightroom's is.
    public var countLabel: String {
        let photos = "\(visibleCount) photo" + (visibleCount == 1 ? "" : "s")
        let selected = photoSelection.count
        return selected == 0 ? photos : "\(photos) · \(selected) selected"
    }

    // MARK: - The grid's highlight

    /// The highlight in displayed order — what a bulk command applies to.
    public var highlightedPhotoIDs: [Int64] { photoSelection.ordered(in: visiblePhotoIDs) }

    public func isHighlighted(_ id: Int64) -> Bool { photoSelection.contains(id) }

    public func clickPhoto(_ id: Int64, modifiers: GridClickModifiers) {
        photoSelection.click(id, modifiers: modifiers, order: visiblePhotoIDs)
    }

    /// Bare arrow: one cell, or one row. Returns the cell to scroll into view.
    @discardableResult
    public func movePhotoHighlight(dx: Int, dy: Int, columns: Int) -> Int64? {
        photoSelection.moveHighlight(dx: dx, dy: dy, columns: columns, order: visiblePhotoIDs)
        return photoSelection.anchor
    }

    /// Shift-arrow: the anchor stays put, the moving end walks.
    @discardableResult
    public func extendPhotoHighlight(dx: Int, dy: Int, columns: Int) -> Int64? {
        photoSelection.extendHighlight(dx: dx, dy: dy, columns: columns, order: visiblePhotoIDs)
        return photoSelection.cursor
    }

    /// ⌘A — everything the grid is showing, not everything the library holds.
    public func selectAllPhotos() {
        photoSelection.select(visiblePhotoIDs)
    }

    /// Replaces the highlight, ignoring photos the current source does not
    /// show — coming back from Develop must not put a ring around a cell that
    /// is not on screen.
    public func selectPhotos(_ ids: [Int64]) {
        let visible = ids.filter { visibleIDs.contains($0) }
        guard !visible.isEmpty else { return }
        photoSelection.select(visible)
    }

    // MARK: - Disclosure

    public func isExpanded(_ path: String) -> Bool { expandedFolders.contains(path) }

    public func setExpanded(_ path: String, _ isExpanded: Bool) {
        if isExpanded {
            expandedFolders.insert(path)
        } else {
            expandedFolders.remove(path)
        }
    }

    /// Opens every row between a volume and this folder, so that folder's row
    /// is on screen. What clicking each triangle in turn does.
    public func expandAncestors(of path: String) {
        for node in folders.allNodes where FolderTree.directory(path, isWithin: node.id) {
            expandedFolders.insert(node.id)
        }
    }
}
