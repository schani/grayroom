import Foundation

/// Where a photo grid is scrolled to, and how far it can still go.
///
/// The numbers a `ScrollView` reports are not the ones "the grid is 300 pt
/// down" means. A scroll view under the window's title bar carries a top
/// content inset the height of the toolbar, and its offset is measured from
/// the top of the *inset* — so an inset that comes and goes moves the offset by
/// its own height while the picture on screen does not move at all (measured:
/// 52 pt, each time the develop view is put in front of the grid). Adding the
/// inset back is what makes `offset` the distance the user sees, and 0 the top.
public struct GridScrollMetrics: Equatable, Sendable {
    /// Points scrolled down from the first row, with 0 the top.
    public let offset: Double
    /// How much of the content is still below the window — 0 when it all fits.
    public let range: Double

    public init(offset: Double, range: Double) {
        self.offset = offset
        self.range = range
    }

    /// The two numbers as they come off a `ScrollGeometry`.
    public init(contentOffset: Double, insetTop: Double, insetBottom: Double,
                contentHeight: Double, containerHeight: Double) {
        offset = contentOffset + insetTop
        range = max(0, contentHeight + insetTop + insetBottom - containerHeight)
    }
}
