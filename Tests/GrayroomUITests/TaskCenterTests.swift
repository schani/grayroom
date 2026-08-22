import Foundation
import XCTest
@testable import GrayroomUI

final class TaskCenterTests: XCTestCase {
    private var center: TaskCenter!

    override func setUp() {
        center = TaskCenter()
    }

    override func tearDown() {
        center = nil
    }

    // MARK: - begin / update / finish

    func testAFreshCentreIsIdle() {
        XCTAssertFalse(center.isBusy)
        XCTAssertTrue(center.tasks.isEmpty)
    }

    func testBeginMakesTheCentreBusy() {
        let id = center.begin(title: "Scanning card", total: 200)
        XCTAssertTrue(center.isBusy)
        let task = try? XCTUnwrap(center.task(id))
        XCTAssertEqual(task?.title, "Scanning card")
        XCTAssertEqual(task?.total, 200)
        // A task with a known total starts at zero, not at "unknown".
        XCTAssertEqual(task?.completed, 0)
        XCTAssertEqual(task?.fractionCompleted, 0)
        XCTAssertFalse(task?.isCancellable ?? true)
    }

    func testATaskWithoutATotalIsIndeterminate() {
        let id = center.begin(title: "Exporting")
        XCTAssertNil(center.task(id)?.total)
        XCTAssertNil(center.task(id)?.completed)
        XCTAssertNil(center.task(id)?.fractionCompleted)
    }

    func testUpdateMovesProgressAndDetail() {
        let id = center.begin(title: "Importing photos", total: 4)
        center.update(id, completed: 1, detail: "a.dng")
        XCTAssertEqual(center.task(id)?.completed, 1)
        XCTAssertEqual(center.task(id)?.detail, "a.dng")
        XCTAssertEqual(center.task(id)?.fractionCompleted, 0.25)
        // Each argument is independent: moving one leaves the other alone.
        center.update(id, completed: 2)
        XCTAssertEqual(center.task(id)?.detail, "a.dng")
        center.update(id, detail: "c.dng")
        XCTAssertEqual(center.task(id)?.completed, 2)
        XCTAssertEqual(center.task(id)?.detail, "c.dng")
    }

    /// The import scan begins before it has enumerated the folder, so it fills
    /// its total in later.
    func testTotalCanArriveAfterTheTaskBegan() {
        let id = center.begin(title: "Scanning card")
        XCTAssertNil(center.task(id)?.fractionCompleted)
        center.update(id, completed: 0, total: 50)
        center.update(id, completed: 25)
        XCTAssertEqual(center.task(id)?.fractionCompleted, 0.5)
    }

    func testFractionIsClampedAndSafeAtZeroTotal() {
        let id = center.begin(title: "Odd", total: 0)
        XCTAssertNil(center.task(id)?.fractionCompleted)
        center.update(id, completed: 9, total: 4)
        XCTAssertEqual(center.task(id)?.fractionCompleted, 1)
    }

    func testFinishRemovesTheTask() {
        let id = center.begin(title: "Importing photos", total: 2)
        center.finish(id)
        XCTAssertFalse(center.isBusy)
        XCTAssertNil(center.task(id))
    }

    func testUpdatingOrFinishingAnUnknownTaskIsANoOp() {
        let id = center.begin(title: "One", total: 2)
        let stale = UUID()
        center.update(stale, completed: 1)
        center.finish(stale)
        XCTAssertEqual(center.tasks.count, 1)
        XCTAssertEqual(center.task(id)?.completed, 0)
    }

    /// The indicator shows the "front" task, so the order has to be the order
    /// they were begun in — not whichever one last reported progress.
    func testTasksKeepTheirBeginOrder() {
        let first = center.begin(title: "One", total: 1)
        let second = center.begin(title: "Two", total: 1)
        let third = center.begin(title: "Three", total: 1)
        center.update(first, completed: 1)
        XCTAssertEqual(center.tasks.map(\.title), ["One", "Two", "Three"])
        center.finish(second)
        XCTAssertEqual(center.tasks.map(\.title), ["One", "Three"])
        XCTAssertEqual(center.tasks.map(\.id), [first, third])
    }

    // MARK: - Cancellation

    func testCancelRaisesTheFlagButLeavesTheTaskListed() {
        let id = center.begin(title: "Importing photos", total: 10, cancellable: true)
        XCTAssertFalse(center.isCancelled(id))
        center.cancel(id)
        XCTAssertTrue(center.isCancelled(id))
        XCTAssertEqual(center.task(id)?.isCancelled, true)
        // Still listed: the worker has to notice and call finish itself.
        XCTAssertTrue(center.isBusy)
        center.finish(id)
        XCTAssertFalse(center.isBusy)
    }

    func testANonCancellableTaskIgnoresCancel() {
        let id = center.begin(title: "Exporting")
        center.cancel(id)
        XCTAssertFalse(center.isCancelled(id))
        XCTAssertEqual(center.task(id)?.isCancelled, false)
    }

    func testCancelAllOnlyTouchesCancellableTasks() {
        let scan = center.begin(title: "Scanning", total: 3, cancellable: true)
        let export = center.begin(title: "Exporting")
        center.cancelAll()
        XCTAssertTrue(center.isCancelled(scan))
        XCTAssertFalse(center.isCancelled(export))
    }

    /// The flag is read from a worker thread between files; finishing has to
    /// clear it so a recycled read cannot see a stale cancellation.
    func testFinishClearsTheCancelFlag() {
        let id = center.begin(title: "Importing photos", total: 3, cancellable: true)
        center.cancel(id)
        center.finish(id)
        XCTAssertFalse(center.isCancelled(id))
    }

    func testIsCancelledIsReadableFromAnotherThread() {
        let id = center.begin(title: "Importing photos", total: 3, cancellable: true)
        center.cancel(id)
        let answer = expectation(description: "read off the main thread")
        var seen = false
        DispatchQueue.global().async { [center] in
            seen = center!.isCancelled(id)
            answer.fulfill()
        }
        wait(for: [answer], timeout: 2)
        XCTAssertTrue(seen)
    }
}
