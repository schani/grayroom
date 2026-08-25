import Foundation
import XCTest
@testable import GrayroomUI

/// The highlight rules on their own, with photo ids for cells — the library
/// grid's case. `ImportSelectionTests` covers the same rules as the import
/// window drives them, over URLs and with the checkbox semantics on top.
final class GridSelectionTests: XCTestCase {
    private let order: [Int64] = [10, 20, 30, 40, 50]

    private func selection() -> GridSelection<Int64> { GridSelection<Int64>() }

    // MARK: - Clicking

    func testAFreshSelectionIsEmpty() {
        let selection = self.selection()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.count, 0)
        XCTAssertNil(selection.anchor)
        XCTAssertFalse(selection.contains(10))
    }

    func testPlainClickHighlightsOnlyThatCellAndMovesTheAnchor() {
        var selection = self.selection()
        selection.click(20, order: order)
        XCTAssertEqual(selection.highlighted, [20])
        XCTAssertEqual(selection.anchor, 20)
        selection.click(40, order: order)
        XCTAssertEqual(selection.highlighted, [40])
        XCTAssertEqual(selection.anchor, 40)
    }

    func testShiftClickSpansTheRangeFromTheAnchorAndKeepsIt() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.click(40, modifiers: .shift, order: order)
        XCTAssertEqual(selection.highlighted, [20, 30, 40])
        // The anchor stays put, so the range can be shrunk again.
        XCTAssertEqual(selection.anchor, 20)
        selection.click(30, modifiers: .shift, order: order)
        XCTAssertEqual(selection.highlighted, [20, 30])
    }

    func testShiftClickBackwardsWorks() {
        var selection = self.selection()
        selection.click(40, order: order)
        selection.click(20, modifiers: .shift, order: order)
        XCTAssertEqual(selection.highlighted, [20, 30, 40])
        XCTAssertEqual(selection.anchor, 40)
    }

    func testShiftClickWithoutAnAnchorIsAPlainClick() {
        var selection = self.selection()
        selection.click(30, modifiers: .shift, order: order)
        XCTAssertEqual(selection.highlighted, [30])
        XCTAssertEqual(selection.anchor, 30)
    }

    func testShiftClickOnTheAnchorItselfSelectsJustIt() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.click(40, modifiers: .shift, order: order)
        selection.click(20, modifiers: .shift, order: order)
        XCTAssertEqual(selection.highlighted, [20])
    }

    /// The range spans the *displayed* order it is given, not the ids' natural
    /// order — a re-sorted grid ranges along what the user sees.
    func testShiftClickFollowsTheGivenOrder() {
        var selection = self.selection()
        let reversed: [Int64] = [50, 40, 30, 20, 10]
        selection.click(50, order: reversed)
        selection.click(30, modifiers: .shift, order: reversed)
        XCTAssertEqual(selection.highlighted, [50, 40, 30])
    }

    /// A cell the displayed order does not contain (the filter hid it, say)
    /// cannot anchor a range; the click falls back to selecting it alone.
    func testShiftClickToACellOutsideTheOrderIsAPlainClick() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.click(99, modifiers: .shift, order: order)
        XCTAssertEqual(selection.highlighted, [99])
        XCTAssertEqual(selection.anchor, 99)
    }

    func testCommandClickTogglesMembership() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.click(30, modifiers: .command, order: order)
        selection.click(50, modifiers: .command, order: order)
        XCTAssertEqual(selection.highlighted, [10, 30, 50])
        XCTAssertEqual(selection.anchor, 50)
        selection.click(30, modifiers: .command, order: order)
        XCTAssertEqual(selection.highlighted, [10, 50])
    }

    /// Cmd-clicking the anchor away leaves the anchor on something that is
    /// still highlighted, so the next shift-click has somewhere to measure from.
    func testCommandClickingTheAnchorAwayMovesTheAnchor() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.click(30, modifiers: .command, order: order)
        selection.click(30, modifiers: .command, order: order)
        XCTAssertEqual(selection.highlighted, [10])
        XCTAssertEqual(selection.anchor, 10)
    }

    func testCommandClickingTheLastCellAwayLeavesNoAnchor() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.click(10, modifiers: .command, order: order)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    /// Both modifiers at once: shift wins, which is what AppKit's own list
    /// views do.
    func testShiftBeatsCommandWhenBothAreDown() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.click(40, modifiers: [.shift, .command], order: order)
        XCTAssertEqual(selection.highlighted, [20, 30, 40])
    }

    // MARK: - Arrows

    func testArrowsMoveByOneAndByARow() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.moveHighlight(dx: 1, dy: 0, columns: 3, order: order)
        XCTAssertEqual(selection.highlighted, [30])
        selection.moveHighlight(dx: -1, dy: 0, columns: 3, order: order)
        XCTAssertEqual(selection.highlighted, [20])
        selection.click(10, order: order)
        selection.moveHighlight(dx: 0, dy: 1, columns: 3, order: order)
        XCTAssertEqual(selection.highlighted, [40])
        selection.moveHighlight(dx: 0, dy: -1, columns: 3, order: order)
        XCTAssertEqual(selection.highlighted, [10])
    }

    func testArrowsClampAtBothEnds() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.moveHighlight(dx: -1, dy: 0, columns: 3, order: order)
        XCTAssertEqual(selection.highlighted, [10])
        selection.click(50, order: order)
        selection.moveHighlight(dx: 0, dy: 1, columns: 3, order: order)
        XCTAssertEqual(selection.highlighted, [50])
    }

    func testTheFirstArrowLandsOnTheFirstCell() {
        var selection = self.selection()
        selection.moveHighlight(dx: 1, dy: 0, columns: 4, order: order)
        XCTAssertEqual(selection.highlighted, [10])
        XCTAssertEqual(selection.anchor, 10)
    }

    func testArrowsOnAnEmptyGridDoNothing() {
        var selection = self.selection()
        selection.moveHighlight(dx: 1, dy: 0, columns: 3, order: [])
        XCTAssertTrue(selection.isEmpty)
    }

    /// An arrow collapses a multi-cell highlight to one cell, measured from the
    /// end the range stopped at — the shift-clicked cell, not the anchor.
    func testArrowsCollapseAMultiSelectionFromTheMovingEnd() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.click(40, modifiers: .shift, order: order)
        selection.moveHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [50])
        XCTAssertEqual(selection.anchor, 50)
    }

    /// With no anchor but something highlighted, the move starts from the
    /// earliest highlighted cell in displayed order.
    func testArrowsWithoutAnAnchorStartAtTheEarliestHighlight() {
        var selection = GridSelection<Int64>(highlighted: [30, 50], anchor: nil)
        selection.moveHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [40])
    }

    func testZeroColumnsIsTreatedAsOne() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.moveHighlight(dx: 0, dy: 1, columns: 0, order: order)
        XCTAssertEqual(selection.highlighted, [20])
    }

    // MARK: - Shift-arrow

    func testShiftArrowGrowsAndShrinksOneRangeFromTheAnchor() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.extendHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [20, 30])
        selection.extendHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [20, 30, 40])
        // Back the other way: the anchor never moved, so the range shrinks
        // rather than starting a new one in the opposite direction.
        selection.extendHighlight(dx: -1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [20, 30])
        selection.extendHighlight(dx: -1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [20])
        XCTAssertEqual(selection.anchor, 20)
        // …and past the anchor it grows again, on the other side.
        selection.extendHighlight(dx: -1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [10, 20])
        XCTAssertEqual(selection.anchor, 20)
    }

    func testShiftArrowExtendsByARow() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.extendHighlight(dx: 0, dy: 1, columns: 2, order: order)
        XCTAssertEqual(selection.highlighted, [10, 20, 30])
    }

    func testShiftArrowClampsAtTheEnds() {
        var selection = self.selection()
        selection.click(40, order: order)
        selection.extendHighlight(dx: 1, dy: 0, columns: 5, order: order)
        selection.extendHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [40, 50])
    }

    /// A bare arrow after a shift-range collapses it and re-anchors — moving on
    /// from the end the range stopped at, not from the anchor.
    func testABareArrowCollapsesFromTheMovingEnd() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.extendHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [20, 30])
        selection.moveHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [40])
        XCTAssertEqual(selection.anchor, 40)
        XCTAssertEqual(selection.cursor, 40)
        selection.extendHighlight(dx: -1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [30, 40])
    }

    func testShiftArrowWithoutAnAnchorBehavesLikeAnArrow() {
        var selection = self.selection()
        selection.extendHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [10])
        XCTAssertEqual(selection.anchor, 10)
    }

    /// A shift-click sets the moving end too, so shift-arrow carries on from
    /// where the shift-click left off.
    func testShiftClickThenShiftArrowContinuesTheSameRange() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.click(30, modifiers: .shift, order: order)
        XCTAssertEqual(selection.cursor, 30)
        selection.extendHighlight(dx: 1, dy: 0, columns: 5, order: order)
        XCTAssertEqual(selection.highlighted, [10, 20, 30, 40])
    }

    // MARK: - Bulk

    func testSelectReplacesTheHighlight() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.select([30, 40])
        XCTAssertEqual(selection.highlighted, [30, 40])
        XCTAssertEqual(selection.anchor, 30)
        // Select All then shift-arrow shrinks from the far end, as in the
        // Finder: the anchor is the first cell, the moving end the last.
        XCTAssertEqual(selection.cursor, 40)
        selection.select([])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    func testClearDropsEverything() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.click(30, modifiers: .shift, order: order)
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    /// After a reload, whatever is gone from the library goes from the
    /// highlight too — including the anchor.
    func testRetainDropsCellsThatNoLongerExist() {
        var selection = self.selection()
        selection.click(10, order: order)
        selection.click(30, modifiers: .command, order: order)
        selection.retain([10, 20])
        XCTAssertEqual(selection.highlighted, [10])
        XCTAssertEqual(selection.anchor, 10)

        var other = self.selection()
        other.click(30, order: order)
        other.click(10, modifiers: .command, order: order)
        other.retain([10, 20])          // the anchor (10) survives
        XCTAssertEqual(other.anchor, 10)

        var third = self.selection()
        third.click(30, order: order)
        third.retain([10, 20])
        XCTAssertTrue(third.isEmpty)
        XCTAssertNil(third.anchor)
    }

    func testOrderedReturnsTheHighlightInDisplayedOrder() {
        var selection = self.selection()
        selection.click(50, order: order)
        selection.click(20, modifiers: .command, order: order)
        selection.click(30, modifiers: .command, order: order)
        XCTAssertEqual(selection.ordered(in: order), [20, 30, 50])
        XCTAssertEqual(selection.ordered(in: [50, 40, 30, 20, 10]), [50, 30, 20])
    }

    // MARK: - Generic over the id type

    func testTheSameRulesWorkOverURLs() {
        let urls = ["a", "b", "c"].map { URL(fileURLWithPath: "/cards/\($0).dng") }
        var selection = GridSelection<URL>()
        selection.click(urls[0], order: urls)
        selection.click(urls[2], modifiers: .shift, order: urls)
        XCTAssertEqual(selection.highlighted, Set(urls))
        XCTAssertEqual(selection.ordered(in: urls), urls)
    }
}

// MARK: - Extending the highlight

extension GridSelectionTests {
    /// Select Similar Photos adds to what is already highlighted and leaves the
    /// anchor where the user put it, so the next shift-click still measures
    /// from there.
    func testExtendAddsWithoutDisturbingTheAnchor() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.extend(with: [40, 50])
        XCTAssertEqual(selection.highlighted, [20, 40, 50])
        XCTAssertEqual(selection.anchor, 20)
        XCTAssertEqual(selection.ordered(in: order), [20, 40, 50])
    }

    func testExtendOfNothingChangesNothing() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.extend(with: [])
        XCTAssertEqual(selection.highlighted, [20])
        XCTAssertEqual(selection.anchor, 20)
    }

    /// With an empty highlight there is no anchor to keep, so the first id
    /// becomes one — otherwise the arrows would have nowhere to start.
    func testExtendFromEmptyTakesAnAnchor() {
        var selection = self.selection()
        selection.extend(with: [30, 40])
        XCTAssertEqual(selection.highlighted, [30, 40])
        XCTAssertEqual(selection.anchor, 30)
        XCTAssertEqual(selection.cursor, 40)
    }

    func testExtendIsIdempotent() {
        var selection = self.selection()
        selection.click(20, order: order)
        selection.extend(with: [20, 30])
        selection.extend(with: [20, 30])
        XCTAssertEqual(selection.highlighted, [20, 30])
    }
}
