import XCTest
@testable import GrayroomUI

final class GridScrollMetricsTests: XCTestCase {
    /// A scroll view under the window's title bar sits at `-insetTop` when it is
    /// at the top of its content. The number the grid means by "not scrolled" is
    /// 0.
    func testTheTopIsZeroWhateverTheTitleBarInsetIs() {
        let metrics = GridScrollMetrics(contentOffset: -52, insetTop: 52, insetBottom: 0,
                                        contentHeight: 1440, containerHeight: 800)
        XCTAssertEqual(metrics.offset, 0)
    }

    /// The inset coming and going must not read as the grid moving: it is the
    /// same picture on screen either way.
    func testTheSameScreenfulReadsTheSameWithAndWithoutTheInset() {
        let inset = GridScrollMetrics(contentOffset: 248, insetTop: 52, insetBottom: 0,
                                      contentHeight: 1440, containerHeight: 800)
        let bare = GridScrollMetrics(contentOffset: 300, insetTop: 0, insetBottom: 0,
                                     contentHeight: 1440, containerHeight: 800)
        XCTAssertEqual(inset.offset, bare.offset)
    }

    func testTheRangeIsWhatIsStillBelowTheWindow() {
        let metrics = GridScrollMetrics(contentOffset: 0, insetTop: 52, insetBottom: 8,
                                        contentHeight: 1440, containerHeight: 800)
        XCTAssertEqual(metrics.range, 700)
    }

    /// A grid that all fits has nowhere to go — never a negative distance.
    func testAGridThatFitsHasNoRange() {
        let metrics = GridScrollMetrics(contentOffset: 0, insetTop: 0, insetBottom: 0,
                                        contentHeight: 200, containerHeight: 800)
        XCTAssertEqual(metrics.range, 0)
    }
}
