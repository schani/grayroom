import Foundation

/// Which modifier keys were down for a click.
///
/// Deliberately not SwiftUI's `EventModifiers`: this type is the reason the
/// selection rules can be tested without a view, and dragging SwiftUI into this
/// target to name two bits would undo that.
public struct GridClickModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Extend the highlight from the anchor to the clicked item.
    public static let shift = GridClickModifiers(rawValue: 1 << 0)
    /// Toggle the clicked item's membership in the highlight.
    public static let command = GridClickModifiers(rawValue: 1 << 1)
}

/// Which cells in a photo grid have the ring, and how a click or an arrow key
/// moves it.
///
/// Both grids in this app — the import window's and the library's — behave the
/// same way here, because Lightroom's do: plain click replaces the highlight,
/// shift-click extends a range from the anchor *in displayed order*, cmd-click
/// toggles one cell's membership, and the arrows move one cell or one row.
/// Everything that differs between the two grids (what a cell *is*, what the
/// order is, what else a click means) stays outside.
///
/// The displayed order is passed in rather than stored. It is the sorted,
/// filtered list the view is actually drawing, it changes whenever a sort or a
/// filter does, and a copy kept here would be a second source of truth for it.
///
/// `ID` is `Hashable`, so the import grid selects `URL`s and the library grid
/// selects photo row ids without either of them owning this logic.
public struct GridSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    /// What the ring is drawn around.
    public private(set) var highlighted: Set<ID> = []
    /// Where a shift-click measures its range from — the *fixed* end.
    public private(set) var anchor: ID?
    /// The moving end: where a shift-range currently stops. Shift-arrow walks
    /// this one and leaves the anchor alone, which is what makes holding shift
    /// and tapping an arrow grow and shrink one range rather than ratchet — the
    /// behaviour Lightroom and the Finder both have.
    public private(set) var cursor: ID?

    public init() {}

    public init(highlighted: Set<ID>, anchor: ID?, cursor: ID? = nil) {
        self.highlighted = highlighted
        self.anchor = anchor
        self.cursor = cursor ?? anchor
    }

    public var isEmpty: Bool { highlighted.isEmpty }
    public var count: Int { highlighted.count }

    public func contains(_ id: ID) -> Bool { highlighted.contains(id) }

    public mutating func clear() {
        highlighted = []
        anchor = nil
        cursor = nil
    }

    /// Replaces the highlight outright — what "come back to the library with
    /// the photo you were developing still selected" and Select All need.
    public mutating func select(_ ids: [ID]) {
        highlighted = Set(ids)
        anchor = ids.first
        cursor = ids.last
    }

    /// `order` is the grid's displayed order: sorted and filtered, i.e. what a
    /// shift-range spans.
    public mutating func click(_ id: ID, modifiers: GridClickModifiers = [], order: [ID]) {
        if modifiers.contains(.shift), let anchor, anchor != id {
            if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
                highlighted = Set(order[min(from, to)...max(from, to)])
                // The anchor deliberately stays put, so dragging the shift-click
                // around grows and shrinks one range instead of ratcheting.
                cursor = id
                return
            }
        }
        if modifiers.contains(.command) {
            if highlighted.contains(id) {
                highlighted.remove(id)
                if anchor == id { anchor = highlighted.first }
                if cursor == id { cursor = anchor }
            } else {
                highlighted.insert(id)
                anchor = id
                cursor = id
            }
            return
        }
        highlighted = [id]
        anchor = id
        cursor = id
    }

    /// Left/right by one, up/down by a row, in displayed order. `columns` is the
    /// grid's current column count, which only the view knows.
    public mutating func moveHighlight(dx: Int, dy: Int, columns: Int, order: [ID]) {
        guard !order.isEmpty else { return }
        let step = dx + dy * max(columns, 1)
        // From the moving end, not the anchor: after shift-extending a range,
        // a bare arrow carries on from the cell the range *stopped* at, which
        // is what the Finder and Lightroom both do. With no range in play the
        // two ends are the same cell and it makes no difference.
        guard let current = (cursor ?? anchor).flatMap(order.firstIndex(of:))
            ?? highlighted.compactMap(order.firstIndex(of:)).min()
        else {
            // Nothing highlighted yet: the first arrow key lands on the first
            // cell rather than doing nothing.
            highlighted = [order[0]]
            anchor = order[0]
            cursor = order[0]
            return
        }
        let next = min(max(current + step, 0), order.count - 1)
        highlighted = [order[next]]
        anchor = order[next]
        cursor = order[next]
    }

    /// Shift-arrow: the anchor stays, the moving end walks, and the highlight
    /// is whatever lies between them.
    public mutating func extendHighlight(dx: Int, dy: Int, columns: Int, order: [ID]) {
        guard !order.isEmpty else { return }
        guard let anchor, let anchorIndex = order.firstIndex(of: anchor) else {
            // Nothing to extend from: shift-arrow behaves like a plain arrow.
            moveHighlight(dx: dx, dy: dy, columns: columns, order: order)
            return
        }
        let step = dx + dy * max(columns, 1)
        let from = cursor.flatMap(order.firstIndex(of:)) ?? anchorIndex
        let next = min(max(from + step, 0), order.count - 1)
        cursor = order[next]
        highlighted = Set(order[min(anchorIndex, next)...max(anchorIndex, next)])
    }

    /// Drops whatever is no longer in the grid, after a reload.
    public mutating func retain(_ valid: Set<ID>) {
        highlighted.formIntersection(valid)
        if let anchor, !valid.contains(anchor) { self.anchor = highlighted.first }
        if let cursor, !valid.contains(cursor) { self.cursor = self.anchor }
    }

    /// The highlight in displayed order — what a bulk command applies to, in
    /// the order the user sees.
    public func ordered(in order: [ID]) -> [ID] {
        order.filter { highlighted.contains($0) }
    }
}

/// The library grid selects photos by their row id.
public typealias LibrarySelection = GridSelection<Int64>
