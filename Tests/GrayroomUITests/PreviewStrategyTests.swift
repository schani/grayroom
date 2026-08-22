import CoreGraphics
import XCTest
@testable import GrayroomUI

/// The draft-then-refine policy, stated as pure functions so the render loop's
/// decisions can be checked without a GPU, a window or a RAW file.
final class PreviewStrategyTests: XCTestCase {
    private let mp24 = CGSize(width: 6000, height: 4000)      // 24 MP
    private let mp100 = CGSize(width: 11664, height: 8750)    // ~102 MP
    private let small = CGSize(width: 2000, height: 1333)     // below the draft edge

    // MARK: - draftLongEdge

    func testCheapEditOnACameraSizedFrameRendersDirectly() {
        XCTAssertNil(PreviewStrategy.draftLongEdge(fullSize: mp24, clarityActive: false))
    }

    func testClarityMakesACameraSizedFrameDraft() {
        XCTAssertEqual(PreviewStrategy.draftLongEdge(fullSize: mp24, clarityActive: true),
                       PreviewStrategy.draftLongEdge)
    }

    /// Above the pixel limit even a clarity-free pipeline is too slow to drag
    /// against, so the draft is not conditional on clarity there.
    func testAVeryLargeFrameDraftsEvenWithoutClarity() {
        XCTAssertEqual(PreviewStrategy.draftLongEdge(fullSize: mp100, clarityActive: false),
                       PreviewStrategy.draftLongEdge)
        XCTAssertEqual(PreviewStrategy.draftLongEdge(fullSize: mp100, clarityActive: true),
                       PreviewStrategy.draftLongEdge)
    }

    /// A frame already at or below the draft edge has nothing to reduce, so
    /// drafting it would cost a whole extra render for an identical picture.
    func testASmallFrameNeverDrafts() {
        XCTAssertNil(PreviewStrategy.draftLongEdge(fullSize: small, clarityActive: true))
        let exact = CGSize(width: PreviewStrategy.draftLongEdge, height: 1707)
        XCTAssertNil(PreviewStrategy.draftLongEdge(fullSize: exact, clarityActive: true))
    }

    func testAnUnknownSizeDoesNotDraft() {
        XCTAssertNil(PreviewStrategy.draftLongEdge(fullSize: .zero, clarityActive: true))
    }

    /// The limit is on pixels, not on the long edge: a panorama with a long edge
    /// past the draft size but few pixels still renders directly.
    func testThePixelLimitIsOnAreaNotOnTheLongEdge() {
        let panorama = CGSize(width: 12000, height: 1200)     // 14 MP
        XCTAssertNil(PreviewStrategy.draftLongEdge(fullSize: panorama, clarityActive: false))
    }

    // MARK: - nextStep

    func testAPendingCheapEditGoesStraightToFull() {
        XCTAssertEqual(PreviewStrategy.nextStep(hasPendingEdit: true,
                                                lastRenderWasDraft: false,
                                                draftLongEdge: nil), .full)
    }

    func testAPendingExpensiveEditDrafts() {
        XCTAssertEqual(PreviewStrategy.nextStep(hasPendingEdit: true,
                                                lastRenderWasDraft: false,
                                                draftLongEdge: 2560),
                       .draft(longEdge: 2560))
    }

    /// The heart of the loop: a newer edit beats an owed refine, so a fast drag
    /// never pays for a full-resolution render it would have thrown away.
    func testANewerEditWinsOverAnOwedRefine() {
        XCTAssertEqual(PreviewStrategy.nextStep(hasPendingEdit: true,
                                                lastRenderWasDraft: true,
                                                draftLongEdge: 2560),
                       .draft(longEdge: 2560))
    }

    func testTheRefineRunsOnceNothingIsPending() {
        XCTAssertEqual(PreviewStrategy.nextStep(hasPendingEdit: false,
                                                lastRenderWasDraft: true,
                                                draftLongEdge: 2560), .full)
    }

    func testAFullRenderEndsTheSequence() {
        XCTAssertEqual(PreviewStrategy.nextStep(hasPendingEdit: false,
                                                lastRenderWasDraft: false,
                                                draftLongEdge: 2560), .idle)
        XCTAssertEqual(PreviewStrategy.nextStep(hasPendingEdit: false,
                                                lastRenderWasDraft: false,
                                                draftLongEdge: nil), .idle)
    }

    /// A whole gesture, driven through the same decision function the app uses:
    /// every frame of the drag drafts, and the loop settles on exactly one
    /// full-resolution refine — never two, never none.
    func testADragDraftsThroughoutAndRefinesExactlyOnceAtTheEnd() {
        var lastRenderWasDraft = false
        var pending = 0
        var steps: [PreviewRenderStep] = []
        let edge: Int? = PreviewStrategy.draftLongEdge(fullSize: mp24, clarityActive: true)

        // Five slider positions arrive; the loop renders one at a time.
        for frame in 0..<12 {
            if frame < 5 { pending += 1 }                       // the drag
            let step = PreviewStrategy.nextStep(hasPendingEdit: pending > 0,
                                                lastRenderWasDraft: lastRenderWasDraft,
                                                draftLongEdge: edge)
            steps.append(step)
            switch step {
            case .draft: pending = 0; lastRenderWasDraft = true
            case .full: pending = 0; lastRenderWasDraft = false
            case .idle: break
            }
        }

        XCTAssertEqual(steps.filter { $0 == .full }.count, 1, "exactly one refine")
        XCTAssertEqual(steps.last, .idle, "the loop comes to rest")
        // The refine is the step right after the last draft.
        let lastDraft = steps.lastIndex { if case .draft = $0 { return true }; return false }
        XCTAssertEqual(steps[lastDraft! + 1], .full)
    }

    /// The same gesture on a cheap edit never drafts at all — no wasted render.
    func testACheapDragRendersEveryFrameFullAndOwesNoRefine() {
        var lastRenderWasDraft = false
        var pending = 0
        var fulls = 0
        for frame in 0..<8 {
            if frame < 5 { pending += 1 }
            let step = PreviewStrategy.nextStep(hasPendingEdit: pending > 0,
                                                lastRenderWasDraft: lastRenderWasDraft,
                                                draftLongEdge: nil)
            if case .draft = step { XCTFail("a cheap edit must not draft") }
            if step == .full { fulls += 1; pending = 0; lastRenderWasDraft = false }
        }
        XCTAssertEqual(fulls, 5)
    }
}
