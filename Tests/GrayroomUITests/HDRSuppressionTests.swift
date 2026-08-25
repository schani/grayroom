import XCTest
@testable import GrayroomCore
@testable import GrayroomUI

/// The render half of HDR suppression: while the system says "no HDR", the loop
/// renders the edit's SDR rendition. The state is set directly here, which is
/// exactly how the canvas self-test drives it — the notification is AppKit's
/// business, the switch is not.
final class HDRSuppressionTests: XCTestCase {

    private func hdrEdit() -> EditState {
        var edit = EditState()
        edit.hdr = true
        edit.tone.exposure = 0.5
        return edit
    }

    func testItStartsUnsuppressed() {
        XCTAssertFalse(HDRSuppression().isSuppressed)
    }

    /// Nothing about the edit changes while HDR is allowed — the ceiling stays
    /// the EDR one.
    func testAnUnsuppressedEditIsRenderedAsItIs() {
        let edit = hdrEdit()
        let display = HDRSuppression().displayEdit(edit)
        XCTAssertEqual(display, edit)
        XCTAssertEqual(display.displayWhite, ToneCurve.hdrDisplayWhite)
    }

    /// Suppressed, the tone curve's shoulder aims at SDR white instead — the
    /// same rendition an export writes, and the same picture below the knee.
    func testSuppressionRendersTheSDRRendition() {
        let suppression = HDRSuppression()
        suppression.set(true)
        let display = suppression.displayEdit(hdrEdit())
        XCTAssertFalse(display.hdr)
        XCTAssertEqual(display.displayWhite, 1.0)
        // Only `hdr` moves: suppression is a display state, not an edit.
        var expected = hdrEdit()
        expected.hdr = false
        XCTAssertEqual(display, expected)
    }

    /// An SDR edit is untouched either way.
    func testAnSDREditIsUnaffected() {
        let suppression = HDRSuppression(isSuppressed: true)
        XCTAssertEqual(suppression.displayEdit(EditState()), EditState())
    }

    /// The canvas and the render loop follow the state through `onChange`, and
    /// only when it actually moves — a repeated notification must not re-render.
    func testOnChangeFiresOncePerActualChange() {
        let suppression = HDRSuppression()
        var seen: [Bool] = []
        suppression.onChange = { seen.append($0) }
        suppression.set(true)
        suppression.set(true)
        suppression.set(false)
        XCTAssertEqual(seen, [true, false])
        XCTAssertFalse(suppression.isSuppressed)
    }
}
