import AppKit
import GrayroomUI
import SwiftUI

/// The grid both photo grids are made of: the import window's and the library's.
///
/// What is shared is everything structural — the adaptive `LazyVGrid`, the
/// column arithmetic the arrow keys need, scroll-to-a-cell, and the mouse. What
/// is not is the cell itself, which is why that is a closure: the import window
/// draws a checkbox and greys out what it already has, the library tints by
/// colour label and badges developments.
///
/// # Why the mouse goes through an `NSView`
///
/// The cells do not use `onTapGesture`. A tap gesture cannot see the modifier
/// keys — `TapGesture().modifiers` does not compose with a plain tap, and
/// `NSEvent.modifierFlags` reads the *hardware* state, which is right for a
/// human and wrong for anything synthesized (a self-test's shift-click arrives
/// with no shift). `ClickCatcher` is a real `NSView` that reads the modifiers
/// off the `NSEvent` it was handed, which is correct in both cases and also
/// gives us `clickCount` for free.
///
/// It sits *behind* the cell, and the cells mark their inert parts
/// `.allowsHitTesting(false)` so the click reaches it: SwiftUI's own hit
/// testing otherwise claims the click for the filled rectangle a cell is drawn
/// on and the catcher never hears about it (measured — every click was
/// swallowed until the cells stood aside). What a cell leaves hit-testable — the
/// import window's checkbox — keeps taking its own clicks.
struct ThumbnailGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    /// The cell's edge, in points; the grid is adaptive to it.
    let thumbnailSize: Double
    /// Written by the grid, read by whoever moves the highlight with arrows.
    @Binding var columns: Int
    /// Set it to scroll a cell into view; the grid clears it once it has.
    @Binding var scrollTarget: Item.ID?
    let onClick: (Item, GridClickModifiers) -> Void
    /// Double-click. `nil` where a double-click means nothing (the import grid).
    var onOpen: ((Item) -> Void)?
    /// The cell's tooltip. It hangs off the click catcher rather than the cell,
    /// because the cell is not hit-testable (see below) and a tooltip needs a
    /// tracking area on something that is.
    var help: ((Item) -> String?)?
    @ViewBuilder let cell: (Item) -> Cell

    static var spacing: Double { 12 }
    static var padding: Double { 12 }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: thumbnailSize),
                                           spacing: ThumbnailGrid.spacing)],
                        spacing: ThumbnailGrid.spacing
                    ) {
                        ForEach(items) { item in
                            cell(item)
                                .background(ClickCatcher(
                                    identifier: ThumbnailGrid.cellIdentifier(item.id),
                                    help: help?(item)
                                ) { modifiers, clickCount in
                                    if clickCount >= 2, let onOpen {
                                        onOpen(item)
                                    } else {
                                        onClick(item, modifiers)
                                    }
                                })
                                .id(item.id)
                        }
                    }
                    .padding(ThumbnailGrid.padding)
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    scroller.scrollTo(target, anchor: .center)
                    scrollTarget = nil
                }
                .onAppear {
                    guard let target = scrollTarget else { return }
                    scroller.scrollTo(target, anchor: .center)
                    scrollTarget = nil
                }
            }
            // `LazyVGrid(.adaptive(minimum:))` never says what column count it
            // settled on, so it is recomputed here with the same arithmetic:
            // the arrow keys have to know what "one row down" means.
            .onChange(of: geometry.size.width, initial: true) { _, width in
                columns = ThumbnailGrid.columnCount(width: width, itemWidth: thumbnailSize)
            }
            .onChange(of: thumbnailSize) { _, size in
                columns = ThumbnailGrid.columnCount(width: geometry.size.width, itemWidth: size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The same count `LazyVGrid(.adaptive(minimum:))` arrives at: as many
    /// columns of `itemWidth` as fit, separated by `spacing`, inside the padded
    /// width.
    static func columnCount(width: Double, itemWidth: Double) -> Int {
        let usable = width - 2 * padding
        guard usable > 0, itemWidth > 0 else { return 1 }
        return max(1, Int((usable + spacing) / (itemWidth + spacing)))
    }

    /// How a cell's click target is found from outside — by the self-test,
    /// which clicks these views with real (synthesized) mouse events.
    static func cellIdentifier(_ id: Item.ID) -> String {
        "grid-cell-\(id)"
    }
}

/// A transparent `NSView` that reports clicks with the modifiers the event
/// actually carried.
struct ClickCatcher: NSViewRepresentable {
    let identifier: String
    var help: String?
    /// What this thing *is*, when the catcher is standing in for a control
    /// rather than sitting behind a cell that reads itself out. A cell leaves
    /// both nil and stays out of the accessibility tree.
    var accessibilityLabel: String?
    var accessibilityValue: String?
    let onClick: (GridClickModifiers, Int) -> Void

    func makeNSView(context: Context) -> ClickCatcherView {
        let view = ClickCatcherView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ClickCatcherView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ClickCatcherView) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.toolTip = help
        view.onClick = onClick
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityValue(accessibilityValue)
        view.isElement = accessibilityLabel != nil
    }
}

final class ClickCatcherView: NSView {
    var onClick: ((GridClickModifiers, Int) -> Void)?
    /// Whether this catcher is the accessibility element for what is drawn on
    /// top of it — true when it stands in for a control, false behind a cell.
    var isElement = false

    override func isAccessibilityElement() -> Bool { isElement }
    override func accessibilityRole() -> NSAccessibility.Role? { isElement ? .button : nil }

    override func mouseDown(with event: NSEvent) {
        onClick?(GridClickModifiers(event.modifierFlags), event.clickCount)
    }

    /// A click that also brings the window forward still selects the cell it
    /// landed on, which is what every photo grid does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The keyboard is routed at the window level (`KeyRouter`), so nothing
    /// here wants focus — and taking it would put a focus ring around a
    /// transparent view.
    override var acceptsFirstResponder: Bool { false }
}

extension GridClickModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: GridClickModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
