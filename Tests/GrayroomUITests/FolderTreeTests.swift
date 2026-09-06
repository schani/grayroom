import Foundation
import XCTest
@testable import GrayroomUI

final class FolderTreeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func photo(_ id: Int64, _ capturedAt: Date?) -> CatalogPhoto {
        CatalogPhoto(id: id, originalName: "\(id).dng", capturedAt: capturedAt)
    }

    func testBuildsYearMonthDayHierarchyAndCountsDescendants() {
        let tree = FolderTree(photos: [
            photo(1, date(2024, 3, 9)), photo(2, date(2024, 3, 9)),
            photo(3, date(2024, 4, 1)), photo(4, date(2025, 1, 2)), photo(5, nil),
        ], calendar: calendar)

        XCTAssertEqual(tree.roots.map(\.id), ["2025", "2024"])
        XCTAssertEqual(tree.node(at: "2024")?.children.map(\.id), ["2024/04", "2024/03"])
        XCTAssertEqual(tree.node(at: "2024")?.count, 3)
        XCTAssertEqual(tree.node(at: "2024/03")?.count, 2)
        XCTAssertEqual(tree.node(at: "2024/03/09")?.count, 2)
        XCTAssertEqual(tree.missingCount, 1)
    }

    func testSelectionsIncludeDescendantsAndPreserveCatalogOrder() {
        let tree = FolderTree(photos: [
            photo(3, date(2024, 4, 1)), photo(1, date(2024, 3, 9)),
            photo(5, nil), photo(2, date(2024, 3, 10)),
        ], calendar: calendar)

        XCTAssertEqual(tree.photoIDs(for: .folder(path: "2024")), [3, 1, 2])
        XCTAssertEqual(tree.photoIDs(for: .folder(path: "2024/03")), [1, 2])
        XCTAssertEqual(tree.photoIDs(for: .folder(path: "2024/03/09")), [1])
        XCTAssertEqual(tree.photoIDs(for: .missing), [5])
        XCTAssertEqual(tree.photoIDs(for: .all), [3, 1, 5, 2])
        XCTAssertEqual(tree.node(at: "2024/03")?.children.map(\.id),
                       ["2024/03/10", "2024/03/09"])
    }

    func testGroupingUsesViewerTimezone() {
        let instant = ISO8601DateFormatter().date(from: "2024-01-01T01:00:00Z")!
        let tree = FolderTree(photos: [photo(1, instant)], calendar: calendar)
        XCTAssertNotNil(tree.node(at: "2023/12/31"))
    }
}
