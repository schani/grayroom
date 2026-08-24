import AppKit
import SwiftUI

/// Names the `NSScrollView` a SwiftUI `ScrollView` is built on, and reads its
/// content offset.
///
/// # Why AppKit
///
/// SwiftUI on macOS 14 will not tell you where a `ScrollView` is scrolled to —
/// `ScrollViewReader` only scrolls to an *identity*, and `scrollPosition` is
/// macOS 15 — so "the grid is where it was" is a claim no SwiftUI-level test can
/// make. A plain `NSView` dropped into the scrolled content answers
/// `enclosingScrollView`, and that is the whole trick: the offset is read off
/// its clip view, and the view carries a name the self-test can find it by.
///
/// Nothing saves or puts back that offset. The Library view stays in the window
/// while Develop is frontmost (see `RootView`), so the clip view is the same
/// object, at the same offset, when the grid comes back.
struct ScrollBridge: NSViewRepresentable {
    /// A name the self-test can find the scroll view by.
    let identifier: String

    /// What the library grid's bridge is called — the self-test reads the
    /// grid's real scroll position through it.
    static let gridIdentifier = "grid-scroll"

    func makeNSView(context: Context) -> ScrollBridgeView {
        let view = ScrollBridgeView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ScrollBridgeView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ScrollBridgeView) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
}

final class ScrollBridgeView: NSView {
    /// Invisible to the mouse and to VoiceOver: this draws nothing and stands
    /// in for nothing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// How far down its own content the scroll view is, in points, or `nil`
    /// when this is not in one (yet).
    ///
    /// The clip view's `bounds.origin` is **not** that number on its own. A
    /// scroll view under the window's title bar carries a top content inset the
    /// height of the toolbar, and the origin is measured from the top of the
    /// inset rather than from the top of the content — so an inset that comes
    /// and goes moves the origin by its own height while the picture on screen
    /// does not move at all (measured: 52 pt, each time the develop view is put
    /// in front of the grid). Adding the inset back is what makes this the
    /// distance the user sees.
    var offset: Double? {
        enclosingScrollView.map {
            Double($0.contentView.bounds.origin.y + $0.contentView.contentInsets.top)
        }
    }
}
