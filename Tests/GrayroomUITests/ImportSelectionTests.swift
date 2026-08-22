import Foundation
import XCTest
@testable import GrayroomUI

final class ImportSelectionTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/cards/A/\(name)")
    }

    /// Five files, shot a minute apart, already resolved — the state the grid
    /// settles into once the scan's hashing pass has finished.
    private func selection(_ names: [String] = ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng"],
                           imported: Set<String> = []) -> ImportSelection {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = names.enumerated().map { index, name in
            ImportEntry(url: url(name),
                        captureDate: base.addingTimeInterval(Double(index) * 60),
                        status: imported.contains(name) ? .alreadyImported : .new)
        }
        var selection = ImportSelection(entries: entries)
        selection.sort = .filename
        return selection
    }

    /// The state a fresh scan starts in: everything `.pending` and ticked.
    private func pendingSelection(
        _ names: [String] = ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng"]
    ) -> ImportSelection {
        var selection = ImportSelection(entries: names.map { ImportEntry(url: url($0)) })
        selection.sort = .filename
        return selection
    }

    private func entry(_ selection: ImportSelection, _ name: String) -> ImportEntry {
        selection.entries.first { $0.filename == name }!
    }

    private func checked(_ selection: ImportSelection) -> [String] {
        selection.entries.filter(\.checked).map(\.filename)
    }

    private func visible(_ selection: ImportSelection) -> [String] {
        selection.visibleEntries.map(\.filename)
    }

    // MARK: - Defaults

    func testEverythingNewIsCheckedAndEverythingImportedIsNot() {
        var selection = self.selection(imported: ["b.dng", "d.dng"])
        XCTAssertEqual(checked(selection), ["a.dng", "c.dng", "e.dng"])
        XCTAssertEqual(selection.checkedCount, 3)
        // The count is over every entry, filtered or not.
        XCTAssertEqual(selection.entries.count, 5)
        // With the filter off they are listed — greyed, not gone.
        selection.hideImported = false
        XCTAssertEqual(visible(selection).count, 5)
    }

    /// On by default: pointing the window at a card you have half-imported
    /// should show the half still to do.
    func testHideImportedIsOnByDefault() {
        XCTAssertTrue(ImportSelection().hideImported)
        let selection = self.selection(imported: ["b.dng", "d.dng"])
        XCTAssertEqual(visible(selection), ["a.dng", "c.dng", "e.dng"])
    }

    func testAnExplicitCheckedValueOverridesTheDefault() {
        let entry = ImportEntry(url: url("a.dng"), status: .alreadyImported, checked: true)
        XCTAssertTrue(entry.checked)
    }

    // MARK: - Pending → resolved

    /// The library's answer costs a full file hash, so the grid draws before it
    /// arrives: everything starts pending, visible and ticked.
    func testAFreshScanStartsPendingAndChecked() {
        let selection = pendingSelection()
        XCTAssertTrue(selection.entries.allSatisfy { $0.status == .pending })
        XCTAssertTrue(selection.entries.allSatisfy { !$0.alreadyImported })
        XCTAssertEqual(selection.checkedCount, 5)
        XCTAssertEqual(visible(selection).count, 5)
    }

    func testResolvingToAlreadyImportedGreysAndUnchecksAnUntouchedEntry() {
        var selection = pendingSelection()
        selection.resolve(url("b.dng"), status: .alreadyImported, hash: "beef")
        XCTAssertTrue(entry(selection, "b.dng").alreadyImported)
        XCTAssertFalse(entry(selection, "b.dng").checked)
        XCTAssertEqual(entry(selection, "b.dng").hash, "beef")
        XCTAssertEqual(checked(selection), ["a.dng", "c.dng", "d.dng", "e.dng"])
    }

    func testResolvingToNewLeavesTheEntryChecked() {
        var selection = pendingSelection()
        selection.resolve(url("b.dng"), status: .new, hash: "cafe")
        XCTAssertEqual(entry(selection, "b.dng").status, .new)
        XCTAssertTrue(entry(selection, "b.dng").checked)
        XCTAssertEqual(selection.checkedCount, 5)
    }

    /// The one rule that stops the window fighting the user: a checkbox they
    /// set by hand is not overwritten when the hash finally comes back.
    func testResolvingDoesNotOverrideACheckboxTheUserTouched() {
        var selection = pendingSelection()
        selection.click(url("b.dng"))
        selection.toggleCheckbox(url("b.dng"))          // deliberately off
        selection.resolve(url("b.dng"), status: .alreadyImported)
        XCTAssertTrue(entry(selection, "b.dng").alreadyImported)
        XCTAssertFalse(entry(selection, "b.dng").checked)

        // …and the same in the direction that actually loses information:
        // ticked by hand, then resolved as already imported.
        var other = pendingSelection()
        other.click(url("c.dng"))
        other.toggleCheckbox(url("c.dng"))              // off
        other.toggleCheckbox(url("c.dng"))              // back on, still touched
        other.resolve(url("c.dng"), status: .alreadyImported)
        XCTAssertTrue(entry(other, "c.dng").alreadyImported)
        XCTAssertTrue(entry(other, "c.dng").checked)
    }

    func testEveryCheckCommandCountsAsTouching() {
        for command in [
            { (s: inout ImportSelection) in s.checkAll() },
            { (s: inout ImportSelection) in s.uncheckAll() },
            { (s: inout ImportSelection) in
                s.click(self.url("b.dng"))
                s.setChecked(true, forHighlighted: true)
            },
            { (s: inout ImportSelection) in
                s.click(self.url("b.dng"))
                s.toggleHighlighted()
            },
        ] {
            var selection = pendingSelection()
            command(&selection)
            let before = entry(selection, "b.dng").checked
            selection.resolve(url("b.dng"), status: .alreadyImported)
            XCTAssertEqual(entry(selection, "b.dng").checked, before)
        }
    }

    func testResolvingAnUnknownURLIsANoOp() {
        var selection = pendingSelection()
        selection.resolve(URL(fileURLWithPath: "/elsewhere/z.dng"), status: .alreadyImported)
        XCTAssertEqual(selection.checkedCount, 5)
    }

    func testResolvedHashesRideAlongToTheImport() {
        var selection = pendingSelection(["a.dng", "b.dng"])
        selection.resolve(url("a.dng"), status: .new, hash: "aaaa")
        selection.resolve(url("b.dng"), status: .alreadyImported, hash: "bbbb")
        XCTAssertEqual(selection.checkedEntries.map(\.hash), ["aaaa"])
        XCTAssertEqual(selection.checkedEntries.map(\.filename), ["a.dng"])
    }

    /// A pending entry is not "already imported", so the filter leaves it in
    /// place rather than hiding files whose status has not come back yet.
    func testHideImportedKeepsPendingEntries() {
        var selection = pendingSelection()
        selection.hideImported = true
        XCTAssertEqual(visible(selection).count, 5)
        selection.resolve(url("b.dng"), status: .alreadyImported)
        XCTAssertEqual(visible(selection), ["a.dng", "c.dng", "d.dng", "e.dng"])
    }

    func testCheckedURLsAreWhatImportWouldTake() {
        var selection = self.selection(imported: ["a.dng"])
        selection.click(url("c.dng"))
        selection.toggleCheckbox(url("c.dng"))
        XCTAssertEqual(selection.checkedURLs.map(\.lastPathComponent), ["b.dng", "d.dng", "e.dng"])
    }

    // MARK: - Clicking

    func testPlainClickHighlightsOnlyThatItem() {
        var selection = self.selection()
        selection.click(url("b.dng"))
        XCTAssertEqual(selection.highlighted, [url("b.dng")])
        selection.click(url("d.dng"))
        XCTAssertEqual(selection.highlighted, [url("d.dng")])
        XCTAssertEqual(selection.anchor, url("d.dng"))
    }

    func testPlainClickDoesNotChangeChecks() {
        var selection = self.selection(imported: ["b.dng"])
        selection.click(url("b.dng"))
        XCTAssertEqual(checked(selection), ["a.dng", "c.dng", "d.dng", "e.dng"])
    }

    func testShiftClickSelectsTheRangeFromTheAnchorInVisibleOrder() {
        var selection = self.selection()
        selection.click(url("b.dng"))
        selection.click(url("d.dng"), modifiers: .shift)
        XCTAssertEqual(selection.highlighted, [url("b.dng"), url("c.dng"), url("d.dng")])
        // The anchor stays put, so shrinking the range works too.
        XCTAssertEqual(selection.anchor, url("b.dng"))
        selection.click(url("c.dng"), modifiers: .shift)
        XCTAssertEqual(selection.highlighted, [url("b.dng"), url("c.dng")])
    }

    func testShiftClickBackwardsWorks() {
        var selection = self.selection()
        selection.click(url("d.dng"))
        selection.click(url("b.dng"), modifiers: .shift)
        XCTAssertEqual(selection.highlighted, [url("b.dng"), url("c.dng"), url("d.dng")])
    }

    /// The range follows the *displayed* order, not the scan order.
    func testShiftClickRangeFollowsTheCurrentSort() {
        var selection = self.selection()
        selection.sort = .checkedState
        selection.toggleCheckbox(url("a.dng"))   // a is now unchecked → last group
        // Visible order is now b c d e a.
        XCTAssertEqual(visible(selection), ["b.dng", "c.dng", "d.dng", "e.dng", "a.dng"])
        selection.click(url("e.dng"))
        selection.click(url("a.dng"), modifiers: .shift)
        XCTAssertEqual(selection.highlighted, [url("e.dng"), url("a.dng")])
    }

    func testShiftClickWithoutAnAnchorBehavesLikeAPlainClick() {
        var selection = self.selection()
        selection.click(url("c.dng"), modifiers: .shift)
        XCTAssertEqual(selection.highlighted, [url("c.dng")])
    }

    func testCommandClickTogglesMembership() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.click(url("c.dng"), modifiers: .command)
        selection.click(url("e.dng"), modifiers: .command)
        XCTAssertEqual(selection.highlighted, [url("a.dng"), url("c.dng"), url("e.dng")])
        selection.click(url("c.dng"), modifiers: .command)
        XCTAssertEqual(selection.highlighted, [url("a.dng"), url("e.dng")])
    }

    func testClickingAnUnknownURLDoesNothing() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.click(URL(fileURLWithPath: "/elsewhere/z.dng"))
        XCTAssertEqual(selection.highlighted, [url("a.dng")])
    }

    // MARK: - The checkbox rule

    func testCheckboxOnAMultiHighlightAppliesToTheWholeHighlight() {
        var selection = self.selection()
        selection.click(url("b.dng"))
        selection.click(url("d.dng"), modifiers: .shift)
        // b, c and d are highlighted and all checked; unticking one unticks all.
        selection.toggleCheckbox(url("c.dng"))
        XCTAssertEqual(checked(selection), ["a.dng", "e.dng"])
        selection.toggleCheckbox(url("c.dng"))
        XCTAssertEqual(checked(selection), ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng"])
    }

    /// The bulk value is the clicked item's *new* value, not each item's own —
    /// a mixed highlight ends up uniform.
    func testBulkCheckboxUsesTheClickedItemsNewValue() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.click(url("c.dng"), modifiers: .shift)
        selection.toggleCheckbox(url("b.dng"))          // a, b, c all off
        XCTAssertEqual(checked(selection), ["d.dng", "e.dng"])
        // Now make it mixed by hand, then bulk-toggle from an off item.
        var solo = ImportSelection(entries: selection.entries)
        solo.sort = .filename
        solo.click(url("a.dng"))
        solo.click(url("c.dng"), modifiers: .shift)
        solo.toggleCheckbox(url("a.dng"))               // a was off → on, so all on
        XCTAssertEqual(checked(solo), ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng"])
    }

    func testCheckboxOnASingleHighlightAppliesToThatItemOnly() {
        var selection = self.selection()
        selection.click(url("b.dng"))
        selection.toggleCheckbox(url("b.dng"))
        XCTAssertEqual(checked(selection), ["a.dng", "c.dng", "d.dng", "e.dng"])
    }

    func testCheckboxOutsideTheHighlightAppliesToThatItemOnly() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.click(url("c.dng"), modifiers: .shift)
        selection.toggleCheckbox(url("e.dng"))
        XCTAssertEqual(checked(selection), ["a.dng", "b.dng", "c.dng", "d.dng"])
    }

    // MARK: - P / U / Space

    func testPAndUSetTheHighlight() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.click(url("c.dng"), modifiers: .shift)
        selection.setChecked(false, forHighlighted: true)
        XCTAssertEqual(checked(selection), ["d.dng", "e.dng"])
        selection.setChecked(true, forHighlighted: true)
        XCTAssertEqual(checked(selection), ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng"])
    }

    func testPAndUDoNothingWithoutAHighlight() {
        var selection = self.selection()
        selection.setChecked(false, forHighlighted: true)
        XCTAssertEqual(selection.checkedCount, 5)
    }

    func testSpaceTogglesTheWholeHighlightToOneState() {
        var selection = self.selection()
        selection.click(url("b.dng"))
        selection.toggleCheckbox(url("b.dng"))          // b off, the rest on
        selection.click(url("a.dng"))
        selection.click(url("c.dng"), modifiers: .shift) // highlight a b c — mixed
        selection.toggleHighlighted()                    // first visible is a (on) → all off
        XCTAssertEqual(checked(selection), ["d.dng", "e.dng"])
        selection.toggleHighlighted()                    // a is now off → all on
        XCTAssertEqual(checked(selection), ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng"])
    }

    func testSpaceDoesNothingWithoutAHighlight() {
        var selection = self.selection()
        selection.toggleHighlighted()
        XCTAssertEqual(selection.checkedCount, 5)
    }

    // MARK: - Check all / uncheck all

    func testCheckAllAndUncheckAllCoverEverythingVisible() {
        var selection = self.selection(imported: ["b.dng"])
        selection.hideImported = false
        selection.checkAll()
        XCTAssertEqual(selection.checkedCount, 5)
        selection.uncheckAll()
        XCTAssertEqual(selection.checkedCount, 0)
    }

    /// The hidden rows keep whatever they had: "check all" means all of what
    /// you are looking at.
    func testCheckAllHonoursTheHideImportedFilter() {
        var selection = self.selection(imported: ["b.dng", "d.dng"])
        selection.hideImported = true
        selection.checkAll()
        XCTAssertEqual(checked(selection), ["a.dng", "c.dng", "e.dng"])

        selection.hideImported = false
        selection.checkAll()
        XCTAssertEqual(selection.checkedCount, 5)
        selection.hideImported = true
        selection.uncheckAll()
        // b and d were hidden, so they stayed checked.
        XCTAssertEqual(checked(selection), ["b.dng", "d.dng"])
    }

    // MARK: - Sorting and filtering

    func testSortByFilename() {
        var selection = self.selection(["delta.dng", "alpha.dng", "charlie.dng"])
        selection.sort = .filename
        XCTAssertEqual(visible(selection), ["alpha.dng", "charlie.dng", "delta.dng"])
    }

    func testSortByCaptureTimePutsUndatedFilesLast() {
        let dated = Date(timeIntervalSince1970: 1_700_000_000)
        var selection = ImportSelection(entries: [
            ImportEntry(url: url("late.dng"), captureDate: dated.addingTimeInterval(600),
                        status: .new),
            ImportEntry(url: url("undated.dng"), captureDate: nil, status: .new),
            ImportEntry(url: url("early.dng"), captureDate: dated, status: .new),
        ])
        selection.sort = .captureTime
        XCTAssertEqual(visible(selection), ["early.dng", "late.dng", "undated.dng"])
    }

    func testSortByCheckedStatePutsCheckedFirstAndIsStable() {
        var selection = self.selection()
        selection.sort = .checkedState
        selection.toggleCheckbox(url("b.dng"))
        selection.toggleCheckbox(url("d.dng"))
        // Checked keep scan order; unchecked keep scan order after them.
        XCTAssertEqual(visible(selection),
                       ["a.dng", "c.dng", "e.dng", "b.dng", "d.dng"])
        selection.toggleCheckbox(url("b.dng"))
        XCTAssertEqual(visible(selection),
                       ["a.dng", "b.dng", "c.dng", "e.dng", "d.dng"])
    }

    func testHideImportedFiltersTheGrid() {
        var selection = self.selection(imported: ["b.dng", "d.dng"])
        XCTAssertEqual(visible(selection), ["a.dng", "c.dng", "e.dng"])
        selection.hideImported = false
        XCTAssertEqual(visible(selection).count, 5)
        // …and the entries themselves are untouched either way.
        XCTAssertEqual(selection.entries.count, 5)
    }

    // MARK: - Arrow keys

    func testArrowsMoveLeftAndRightByOne() {
        var selection = self.selection()
        selection.click(url("b.dng"))
        selection.moveHighlight(dx: 1, dy: 0, columns: 3)
        XCTAssertEqual(selection.highlighted, [url("c.dng")])
        selection.moveHighlight(dx: -1, dy: 0, columns: 3)
        XCTAssertEqual(selection.highlighted, [url("b.dng")])
    }

    func testArrowsMoveUpAndDownByTheColumnCount() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.moveHighlight(dx: 0, dy: 1, columns: 3)
        XCTAssertEqual(selection.highlighted, [url("d.dng")])
        selection.moveHighlight(dx: 0, dy: -1, columns: 3)
        XCTAssertEqual(selection.highlighted, [url("a.dng")])
    }

    func testArrowsClampAtBothEnds() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.moveHighlight(dx: -1, dy: 0, columns: 3)
        XCTAssertEqual(selection.highlighted, [url("a.dng")])
        selection.click(url("e.dng"))
        selection.moveHighlight(dx: 0, dy: 1, columns: 3)
        XCTAssertEqual(selection.highlighted, [url("e.dng")])
    }

    func testTheFirstArrowKeyLandsOnTheFirstItem() {
        var selection = self.selection()
        selection.moveHighlight(dx: 1, dy: 0, columns: 4)
        XCTAssertEqual(selection.highlighted, [url("a.dng")])
        XCTAssertEqual(selection.anchor, url("a.dng"))
    }

    func testArrowsMoveWithinTheVisibleSetOnly() {
        var selection = self.selection(imported: ["b.dng"])
        selection.hideImported = true
        selection.click(url("a.dng"))
        selection.moveHighlight(dx: 1, dy: 0, columns: 3)
        XCTAssertEqual(selection.highlighted, [url("c.dng")])
    }

    func testArrowsOnAnEmptyGridDoNothing() {
        var selection = ImportSelection()
        selection.moveHighlight(dx: 1, dy: 0, columns: 3)
        XCTAssertTrue(selection.highlighted.isEmpty)
    }

    // MARK: - Rescanning

    func testSetEntriesDropsTheHighlight() {
        var selection = self.selection()
        selection.click(url("b.dng"))
        selection.setEntries([ImportEntry(url: url("z.dng"))])
        XCTAssertTrue(selection.highlighted.isEmpty)
        XCTAssertNil(selection.anchor)
        XCTAssertEqual(selection.checkedCount, 1)
        XCTAssertEqual(selection.entries.first?.status, .pending)
        XCTAssertFalse(selection.entries.first?.userTouched ?? true)
    }
}
