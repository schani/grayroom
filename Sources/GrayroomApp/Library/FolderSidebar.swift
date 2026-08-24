import AppKit
import GrayroomUI
import SwiftUI

/// Lightroom's left panel in the Library module, reduced to its Folders section.
///
/// Three sources, in Lightroom's order: **Catalog** ("All Photographs" and its
/// count), **Folders** (a volume per root, the directory tree under it, counts
/// right-aligned), and at the very bottom the photos whose files are gone. The
/// missing row is drawn even when it counts zero — greyed — because its absence
/// would be indistinguishable from "there is no such thing in this app", and
/// the whole point of the row is to tell the user the library is intact.
///
/// # The keyboard is not this list's
///
/// `KeyRouter` sees every `keyDown` before AppKit dispatches it, so the arrows
/// keep moving the grid's ring even while this list has focus (the panel is
/// mouse-driven, as it is in Lightroom, where the arrows always belong to the
/// grid). Nothing here needs to arrange that; it is a consequence of the
/// router's local monitor running before the responder chain.
struct FolderSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        // The binding is what draws the highlight on the selected row; the
        // rows themselves report a click through `select`, not through the
        // list — see `FolderSidebarRow`.
        List(selection: Binding(get: { model.folderSelection },
                                set: { model.folderSelection = $0 ?? .all })) {
            Section("Catalog") {
                FolderSidebarRow(path: "all", icon: "photo.on.rectangle.angled",
                                 leafName: "All Photographs", count: model.folders.totalCount,
                                 selection: .all, select: select)
                    .tag(FolderSelection.all)
            }
            Section("Folders") {
                ForEach(model.folders.roots) { root in
                    FolderOutline(model: model, node: root, isVolume: true)
                }
            }
            Section {
                FolderSidebarRow(path: "missing", icon: "questionmark.folder",
                                 leafName: "Missing", count: model.folders.missingCount,
                                 isDimmed: model.folders.missingCount == 0,
                                 tooltip: "Photos the library remembers and has no file for",
                                 selection: .missing, select: select)
                    .tag(FolderSelection.missing)
            }
        }
        .listStyle(.sidebar)
    }

    private func select(_ selection: FolderSelection) {
        model.folderSelection = selection
    }
}

/// One folder and its subfolders, recursively — the outline itself.
///
/// A `DisclosureGroup` per level rather than `OutlineGroup`, for one reason:
/// `OutlineGroup` owns its expansion state privately and offers no binding, and
/// this panel has to (a) open every volume the first time it sees it, the way
/// Lightroom does, (b) survive a catalog rebuild without folding itself back
/// up, and (c) be openable from the self-test. All three are the same
/// `model.expandedFolders` set, which is what a disclosure triangle writes.
private struct FolderOutline: View {
    @Bindable var model: AppModel
    let node: FolderNode
    let isVolume: Bool

    var body: some View {
        // Read here, in the body, and not only inside the binding's getter:
        // Observation notices what a *body* touches, and a closure SwiftUI
        // calls later registers no dependency at all. Without this line the
        // triangles follow a click and nothing else — the panel could not be
        // opened by the app itself, and the self-test could not open it either
        // (measured: the rows below a root never appeared).
        let isExpanded = model.expandedFolders.contains(node.id)
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: Binding(get: { isExpanded },
                                                set: { setExpanded($0) })) {
                ForEach(node.children) { child in
                    FolderOutline(model: model, node: child, isVolume: false)
                }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        // A volume's row is one line — the volume *is* the leaf, and it has no
        // folded-away parents above it to show.
        FolderSidebarRow(path: node.id, icon: isVolume ? "externaldrive" : "folder",
                         leafName: node.leafName, parentChain: node.parentChain,
                         count: node.count, tooltip: node.id,
                         selection: .folder(path: node.id),
                         select: { model.folderSelection = $0 })
            .tag(FolderSelection.folder(path: node.id))
    }

    /// One disclosure triangle, written back into the model so a catalog reload
    /// does not close the panel up again.
    private func setExpanded(_ isExpanded: Bool) {
        if isExpanded {
            model.expandedFolders.insert(node.id)
        } else {
            model.expandedFolders.remove(node.id)
        }
    }
}

/// One row: icon, name, and the photo count right-aligned in secondary
/// monospaced digits — Lightroom's layout, and the reason for the monospacing
/// is that a column of counts that jitters is unreadable.
///
/// The row's click and its accessibility both go through one `NSView` behind
/// it (`SidebarRowTarget`) rather than through the `List`. Two reasons, and the
/// first is the user's:
///
/// - a `List` row does not take a click unless its window is **key**, so
///   clicking a folder in a Grayroom window that is not in front does nothing
///   at all — you have to click twice. The grid has never behaved that way
///   (`ClickCatcher.acceptsFirstMouse`), and neither does the Finder's sidebar;
/// - and it makes the panel addressable. `List` builds its rows' SwiftUI
///   accessibility nodes only for a window the user can see, so a row's name
///   and count are unreadable from inside the process exactly when the
///   self-test needs them (it runs with its windows below the desktop). An
///   `NSView` is an accessibility element wherever it is.
private struct FolderSidebarRow: View {
    let path: String
    let icon: String
    /// The folder itself — the primary line.
    let leafName: String
    /// The folded-away parents above it, drawn smaller underneath. `nil` for
    /// every row that is not a collapsed chain, which is all of them except the
    /// one Lightroom folds.
    var parentChain: String?
    let count: Int
    var isDimmed = false
    /// What the row says when the pointer rests on it: the full path, which is
    /// the thing the two-line label deliberately no longer spells out in full.
    var tooltip: String?
    /// What clicking the row selects.
    let selection: FolderSelection
    let select: (FolderSelection) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 0) {
                Text(leafName)
                    .lineLimit(1)
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary)
                                              : AnyShapeStyle(.primary))
                if let parentChain {
                    // Head truncation, because the *nearest* parent is the one
                    // worth keeping: "…/schani" tells you which Pictures this
                    // is, "Users/…" does not.
                    Text(parentChain)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        // The icon and the labels stand aside so the click reaches the view
        // behind them, exactly as the grid's cells do — SwiftUI's own hit
        // testing would otherwise claim it for the text.
        .allowsHitTesting(false)
        .background(SidebarRowTarget(identifier: FolderSidebar.rowIdentifier(path),
                                     label: leafName,
                                     value: tooltip ?? leafName,
                                     help: FolderSidebar.countDescription(count),
                                     tooltip: tooltip) { select(selection) })
        // The row *is* the `NSView` behind it, as far as anything outside is
        // concerned: one element that reads "Pictures", worth 42 photos, at
        // /Users/schani/Pictures — rather than an icon and three labels.
        .accessibilityHidden(true)
    }
}

/// The `NSView` behind one row: it takes the click, it carries the row's
/// tooltip, and it is the row's accessibility element. See `FolderSidebarRow`
/// for why the row does not leave any of those to the `List` — the tooltip in
/// particular cannot hang off the label, because the label is not hit-testable
/// and a tooltip needs a tracking area on something that is.
private struct SidebarRowTarget: NSViewRepresentable {
    let identifier: String
    /// What the row is: the folder's own name.
    let label: String
    /// Where the row is: the full path, which the two-line label truncates.
    let value: String
    /// How much is in it. Accessibility's `help` and not its `value`, because
    /// the value is the path; a count is exactly the kind of secondary detail
    /// help is for.
    let help: String
    let tooltip: String?
    let onClick: () -> Void

    func makeNSView(context: Context) -> SidebarRowTargetView {
        let view = SidebarRowTargetView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: SidebarRowTargetView, context: Context) {
        update(nsView)
    }

    private func update(_ view: SidebarRowTargetView) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        view.setAccessibilityHelp(help)
        view.toolTip = tooltip
        view.onClick = onClick
    }
}

final class SidebarRowTargetView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    /// A click that also brings the window forward still selects the row it
    /// landed on — the same rule the photo grid has always had.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The keyboard belongs to the window (`KeyRouter`); nothing here wants it.
    override var acceptsFirstResponder: Bool { false }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
}

extension FolderSidebar {
    /// How a row is addressed from outside: `all`, `missing`, or a folder's
    /// path. It is the row's accessibility identifier.
    static func rowIdentifier(_ path: String) -> String { "folder-row-\(path)" }

    /// What a row's count reads as to accessibility. The row *draws* the bare
    /// number, which is only legible next to the other numbers in the column.
    static func countDescription(_ count: Int) -> String {
        "\(count) photo" + (count == 1 ? "" : "s")
    }
}
