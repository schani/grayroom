import Foundation
import Observation

/// Lightroom's two Library views, and its two keys for them: `g` for the grid,
/// `e` (or Return) for the loupe. Both are the Library module — the Folders
/// panel stays, the module picker stays on Library — which is why this is a
/// mode *inside* the browser and not a third `AppModel.Mode`.
public enum LibraryViewMode: String, Equatable, Sendable {
    case grid
    case loupe
}

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

    /// Whether the user wants the Folders panel. It is a *preference*, not what
    /// is on screen — see `isSidebarShowing`, which is the one the window binds
    /// to.
    public var isSidebarVisible = true

    /// The grid's highlight — a set of photo ids, moved by clicks and arrows.
    public var photoSelection = LibrarySelection()

    /// Grid or loupe. The loupe is a view of the Library module, not a module
    /// of its own.
    public private(set) var viewMode: LibraryViewMode = .grid

    /// The one photo the loupe is showing, `nil` in the grid. It is always the
    /// grid's whole selection too, so `g` comes back to it highlighted.
    public private(set) var loupePhotoID: Int64?

    /// What the grid was anchored on when the loupe took over.
    ///
    /// It is the whole of "does the grid need to be scrolled on the way out".
    /// The photo the loupe opened on was, by construction, the cell the user
    /// had just picked — so it was on screen, and a grid that has not moved
    /// since is already showing it. Only a loupe that *walked* somewhere else
    /// leaves the grid pointing at a photo it may not be showing.
    private var loupeEntryAnchor: Int64?

    /// Whether the Folders panel is on screen.
    ///
    /// The loupe never shows it: one photo fills the module's whole content
    /// area, as it does in Lightroom's `E`. That is a *derived* fact rather than
    /// a stored one on purpose — the panel's own visibility is never written to
    /// on the way in, so there is nothing to restore on the way out and no way
    /// for the two to drift apart. `g` from a loupe entered with the panel
    /// hidden comes back to a hidden panel; entered with it showing, to a
    /// showing one.
    public var isSidebarShowing: Bool { viewMode == .grid && isSidebarVisible }

    /// Whether the Library module is the one drawing a canvas right now, and
    /// therefore whose zoom the zoom keys and the zoom percentage belong to.
    /// The loupe draws the same `CanvasNSView` the develop view does.
    public var ownsCanvas: Bool { viewMode == .loupe }

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
        // The photo the loupe was showing is not in the grid any more — the
        // source moved, or it was deleted. There is nothing to be in the loupe
        // *of*, so the Library falls back to the grid.
        if let id = loupePhotoID, !visibleIDs.contains(id) {
            loupePhotoID = nil
            loupeEntryAnchor = nil
            viewMode = .grid
        }
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

    /// Adds photos to the highlight, ignoring any the current source does not
    /// show — Select Similar Photos, which must not ring a cell that is not on
    /// screen. Returns what it actually added to.
    @discardableResult
    public func extendSelection(with ids: [Int64]) -> [Int64] {
        let visible = ids.filter { visibleIDs.contains($0) }
        photoSelection.extend(with: visible)
        return visible
    }

    // MARK: - The loupe

    /// `e`, or Return: the loupe, on one photo.
    ///
    /// `id` is the photo to show; with none given it is the selection's
    /// anchor — Lightroom's *active* photo, the one it draws lighter than the
    /// rest of a multi-selection — and failing that the first cell in the grid.
    /// Returns the photo the loupe is now showing, and `nil` (staying in the
    /// grid) when there is none: an empty grid has nothing to be a loupe of.
    @discardableResult
    public func enterLoupe(on id: Int64? = nil) -> Int64? {
        let candidate = id
            ?? photoSelection.anchor
            ?? highlightedPhotoIDs.first
            ?? visiblePhotoIDs.first
        guard let candidate, visibleIDs.contains(candidate) else { return nil }
        // Before the loupe overwrites the selection with its own photo.
        loupeEntryAnchor = photoSelection.anchor
        loupePhotoID = candidate
        // Single selection, always: the loupe *is* the selection, so `g` comes
        // back to the photo that was on screen with the ring around it.
        photoSelection.select([candidate])
        viewMode = .loupe
        return candidate
    }

    /// `g` or Esc, from the loupe. Returns the cell to scroll into view — the
    /// loupe's photo, which the arrows may have walked a long way from wherever
    /// the grid was left — or `nil` when there is nothing to scroll to.
    ///
    /// `nil` is the common case and it matters: the grid is not taken out of
    /// the window while the loupe has it (see `LibraryView`), so it is still at
    /// the offset it was left at, showing the cell the loupe opened on. Asking
    /// for that cell to be scrolled into view anyway would *move* a grid that
    /// is already right — SwiftUI's `scrollTo` centres its target whether or
    /// not it is on screen.
    @discardableResult
    public func exitLoupe() -> Int64? {
        let photo = loupePhotoID
        let walked = photo != loupeEntryAnchor
        loupePhotoID = nil
        loupeEntryAnchor = nil
        viewMode = .grid
        return walked ? photo : nil
    }

    /// The left and right arrows in the loupe: one photo along the grid's own
    /// order, stopping at both ends rather than wrapping — as Lightroom does.
    /// Returns the photo now being shown.
    @discardableResult
    public func stepLoupe(_ delta: Int) -> Int64? {
        guard let current = loupePhotoID,
              let index = visiblePhotoIDs.firstIndex(of: current) else {
            return enterLoupe()
        }
        let next = min(max(index + delta, 0), visiblePhotoIDs.count - 1)
        guard next != index else { return current }
        let id = visiblePhotoIDs[next]
        loupePhotoID = id
        photoSelection.select([id])
        return id
    }

    /// Lightroom's "3 / 11" in the loupe's bottom bar: where this photo is in
    /// the filtered list, and how long that list is.
    public var loupePositionLabel: String {
        guard let id = loupePhotoID, let index = visiblePhotoIDs.firstIndex(of: id) else {
            return "\(visibleCount) photo" + (visibleCount == 1 ? "" : "s")
        }
        return "\(index + 1) / \(visibleCount)"
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
