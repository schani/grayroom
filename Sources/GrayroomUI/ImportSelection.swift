import Foundation

/// What the library knows about a scanned file.
///
/// The answer costs a full SHA-256 of the file, so it is not available when the
/// grid first draws — hence `.pending`, which is a real state the cell has to
/// render rather than a placeholder for "no".
public enum ImportEntryStatus: Equatable, Sendable {
    /// Not hashed yet.
    case pending
    /// Hashed, and the library has no photo with those bytes at any location.
    case new
    /// The library has a photo with these exact bytes **and** at least one
    /// recorded location for it.
    ///
    /// Both halves matter. A photo whose every location has been removed is a
    /// row the library still remembers but no longer has a file for, so
    /// offering to add this file back is the right thing to do, not a
    /// duplicate.
    case alreadyImported
}

/// One candidate file in the import grid, minus its picture.
///
/// The thumbnail lives in the app rather than here: it arrives asynchronously,
/// it is a `CGImage`, and none of the selection rules care about it. What is
/// left is small, `Equatable` and testable without a window.
public struct ImportEntry: Identifiable, Equatable, Sendable {
    public var url: URL
    public var filename: String
    public var captureDate: Date?
    public var status: ImportEntryStatus
    /// The file's SHA-256, hex, once the scan has computed it.
    ///
    /// Kept so the import does not hash all 200 files a second time: the scan
    /// already paid for it.
    public var hash: String?
    /// Whether the Import button will take this file.
    public var checked: Bool
    /// The user has set this checkbox by hand.
    ///
    /// The status resolves asynchronously, seconds after the grid is usable, so
    /// without this a late `.alreadyImported` would silently untick a frame the
    /// user had just deliberately ticked.
    public var userTouched: Bool

    public var id: URL { url }
    public var alreadyImported: Bool { status == .alreadyImported }

    /// `checked` defaults to the inverse of "already imported": a scan arrives
    /// with everything ticked and unticks the frames the library turns out to
    /// have already, which is what makes re-pointing the window at yesterday's
    /// card a no-op instead of a chore.
    public init(url: URL,
                filename: String? = nil,
                captureDate: Date? = nil,
                status: ImportEntryStatus = .pending,
                hash: String? = nil,
                checked: Bool? = nil,
                userTouched: Bool = false) {
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.captureDate = captureDate
        self.status = status
        self.hash = hash
        self.checked = checked ?? (status != .alreadyImported)
        self.userTouched = userTouched
    }
}

/// How the grid is ordered.
public enum ImportSortOrder: String, CaseIterable, Identifiable, Sendable {
    case captureTime
    case checkedState
    case filename

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .captureTime: return "Capture Time"
        case .checkedState: return "Checked State"
        case .filename: return "File Name"
        }
    }
}

/// Which modifier keys were down for a click.
///
/// Deliberately not SwiftUI's `EventModifiers`: this type is the reason the
/// selection rules can be tested without a view, and dragging SwiftUI into the
/// library target to name two bits would undo that.
public struct ImportClickModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Extend the highlight from the anchor to the clicked item.
    public static let shift = ImportClickModifiers(rawValue: 1 << 0)
    /// Toggle the clicked item's membership in the highlight.
    public static let command = ImportClickModifiers(rawValue: 1 << 1)
}

/// The import grid's two independent selections, and the rules that connect
/// them.
///
/// Lightroom's import window has *two* notions of "selected", and conflating
/// them is the classic way to get this wrong:
///
/// - **highlighted** — what the click and the arrow keys move. Purely visual,
///   it decides which cells get a ring and which cells a bulk command applies
///   to.
/// - **checked** — what the Import button will actually take. Survives
///   re-sorting, re-filtering and every change of highlight.
///
/// The one place they meet is `toggleCheckbox`: clicking the checkbox of a cell
/// that is *part of a multi-cell highlight* applies to the whole highlight,
/// while clicking the checkbox of anything else is a single-cell edit. That is
/// the behaviour that lets you rubber-band twenty frames and tick them in one
/// gesture without turning every stray checkbox click into a bulk edit.
///
/// Everything here is a value type with no dependencies beyond Foundation, so
/// the whole set of rules is unit-testable — which is the point, given that the
/// app target it is used from cannot be imported by a test target at all.
public struct ImportSelection: Equatable, Sendable {
    /// Scan order (by path). The sorts below are defined relative to this, so
    /// "stable" has a fixed meaning.
    public private(set) var entries: [ImportEntry]
    /// What the ring is drawn around.
    public private(set) var highlighted: Set<URL> = []
    /// Where a shift-click measures its range from.
    public private(set) var anchor: URL?
    public var sort: ImportSortOrder = .captureTime
    /// On by default. Re-pointing the window at a card you have already
    /// imported half of should show you the half that is still to do, not make
    /// you find it among the frames that are already in.
    public var hideImported: Bool = true

    public init(entries: [ImportEntry] = []) {
        self.entries = entries
    }

    // MARK: - Contents

    /// Replaces the whole list; the highlight does not survive a rescan.
    public mutating func setEntries(_ entries: [ImportEntry]) {
        self.entries = entries
        highlighted = []
        anchor = nil
    }

    /// The scan's answer for one file, arriving well after the grid drew it.
    ///
    /// Unticking on `.alreadyImported` is skipped for an entry the user has
    /// already touched: their explicit choice outranks the library's opinion,
    /// and having a checkbox flip back seconds after you clicked it is the
    /// worst behaviour this window could have.
    public mutating func resolve(_ url: URL, status: ImportEntryStatus, hash: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[index].status = status
        if let hash { entries[index].hash = hash }
        if status == .alreadyImported, !entries[index].userTouched {
            entries[index].checked = false
        }
    }

    /// Sorted and filtered — the order the grid draws, and therefore the order
    /// shift-ranges and arrow keys move in.
    public var visibleEntries: [ImportEntry] {
        let filtered = hideImported ? entries.filter { !$0.alreadyImported } : entries
        // Every sort carries the scan-order index as its last tiebreak, which
        // is what makes `.checkedState` a stable partition rather than an
        // arbitrary shuffle of two groups.
        let indexed = filtered.enumerated().map { ($0.offset, $0.element) }
        let sorted: [(Int, ImportEntry)]
        switch sort {
        case .captureTime:
            sorted = indexed.sorted { a, b in
                switch (a.1.captureDate, b.1.captureDate) {
                case let (x?, y?) where x != y: return x < y
                // A file with no EXIF date sorts after every dated one rather
                // than pretending to have been shot at the epoch.
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.0 < b.0
                }
            }
        case .checkedState:
            sorted = indexed.sorted { a, b in
                a.1.checked == b.1.checked ? a.0 < b.0 : (a.1.checked && !b.1.checked)
            }
        case .filename:
            sorted = indexed.sorted { a, b in
                let order = a.1.filename.localizedStandardCompare(b.1.filename)
                return order == .orderedSame ? a.0 < b.0 : order == .orderedAscending
            }
        }
        return sorted.map(\.1)
    }

    /// What the Import button will take — counted across *all* entries, not
    /// just the visible ones, because hiding a row does not untick it.
    public var checkedCount: Int { entries.reduce(0) { $0 + ($1.checked ? 1 : 0) } }

    public var checkedEntries: [ImportEntry] { entries.filter(\.checked) }
    public var checkedURLs: [URL] { checkedEntries.map(\.url) }

    // MARK: - Highlighting

    public mutating func click(_ url: URL, modifiers: ImportClickModifiers = []) {
        guard entries.contains(where: { $0.url == url }) else { return }
        if modifiers.contains(.shift), let anchor, anchor != url {
            let order = visibleEntries.map(\.url)
            if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: url) {
                highlighted = Set(order[min(from, to)...max(from, to)])
                // The anchor deliberately stays put, so dragging the shift-click
                // around grows and shrinks one range instead of ratcheting.
                return
            }
        }
        if modifiers.contains(.command) {
            if highlighted.contains(url) {
                highlighted.remove(url)
                if anchor == url { anchor = highlighted.first }
            } else {
                highlighted.insert(url)
                anchor = url
            }
            return
        }
        highlighted = [url]
        anchor = url
    }

    /// Left/right by one, up/down by a row, in visible order. `columns` is the
    /// grid's current column count, which only the view knows.
    public mutating func moveHighlight(dx: Int, dy: Int, columns: Int) {
        let order = visibleEntries.map(\.url)
        guard !order.isEmpty else { return }
        let step = dx + dy * max(columns, 1)
        guard let current = anchor.flatMap(order.firstIndex(of:))
            ?? highlighted.compactMap(order.firstIndex(of:)).min()
        else {
            // Nothing highlighted yet: the first arrow key lands on the first
            // cell rather than doing nothing.
            highlighted = [order[0]]
            anchor = order[0]
            return
        }
        let next = min(max(current + step, 0), order.count - 1)
        highlighted = [order[next]]
        anchor = order[next]
    }

    // MARK: - Checking

    /// The checkbox rule: a checkbox inside a multi-cell highlight edits the
    /// whole highlight, anything else edits one cell.
    public mutating func toggleCheckbox(_ url: URL) {
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        let value = !entries[index].checked
        if highlighted.contains(url), highlighted.count > 1 {
            apply(value, to: highlighted)
        } else {
            setChecked(value, atIndex: index)
        }
    }

    /// P and U. `forHighlighted` picks the target: the highlight, or everything
    /// currently visible (which is what Check All / Uncheck All want).
    public mutating func setChecked(_ value: Bool, forHighlighted: Bool) {
        let targets: Set<URL> = forHighlighted ? highlighted : Set(visibleEntries.map(\.url))
        apply(value, to: targets)
    }

    private mutating func apply(_ value: Bool, to targets: Set<URL>) {
        guard !targets.isEmpty else { return }
        for i in entries.indices where targets.contains(entries[i].url) {
            setChecked(value, atIndex: i)
        }
    }

    /// Every user-driven check goes through here, so `userTouched` cannot be
    /// forgotten on one of the four paths that set a checkbox.
    private mutating func setChecked(_ value: Bool, atIndex index: Int) {
        entries[index].checked = value
        entries[index].userTouched = true
    }

    /// Space: one state for the whole highlight, taken from the first
    /// highlighted cell in visible order — so a mixed selection resolves to a
    /// single unambiguous outcome instead of flipping each cell separately.
    public mutating func toggleHighlighted() {
        guard let first = visibleEntries.first(where: { highlighted.contains($0.url) })
        else { return }
        setChecked(!first.checked, forHighlighted: true)
    }

    /// Check All / Uncheck All, which honour the "hide already imported"
    /// filter: what you cannot see, you cannot accidentally tick.
    public mutating func checkAll() { setChecked(true, forHighlighted: false) }
    public mutating func uncheckAll() { setChecked(false, forHighlighted: false) }
}
