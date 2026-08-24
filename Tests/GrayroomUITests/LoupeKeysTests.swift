import XCTest
@testable import GrayroomUI

/// The Library loupe's key table. It lives away from the window precisely so
/// that "0 zooms to fit in the loupe" can be asserted without one — `KeyRouter`
/// is an `NSEvent` monitor in an executable target and nothing here could reach
/// it.
final class LoupeKeysTests: XCTestCase {

    func testTheZoomKeysAreTheDevelopViewsOwn() {
        XCTAssertEqual(LoupeKeys.command(for: "0"), .zoomToFit)
        XCTAssertEqual(LoupeKeys.command(for: "1"), .zoomToActualSize)
    }

    func testTheWaysOutAndOnward() {
        XCTAssertEqual(LoupeKeys.command(for: "g"), .grid)
        XCTAssertEqual(LoupeKeys.command(for: "\u{1b}"), .grid, "Esc leaves too")
        XCTAssertEqual(LoupeKeys.command(for: "d"), .develop)
        // Already here: swallowed, so it never falls through to the grid.
        XCTAssertEqual(LoupeKeys.command(for: "e"), .nothing)
        XCTAssertEqual(LoupeKeys.command(for: "\r"), .nothing)
    }

    /// Lightroom's 6–9, as `ColorLabel` raw values.
    func testTheColourKeys() {
        XCTAssertEqual(LoupeKeys.command(for: "6"), .colorLabel(1))
        XCTAssertEqual(LoupeKeys.command(for: "7"), .colorLabel(2))
        XCTAssertEqual(LoupeKeys.command(for: "8"), .colorLabel(3))
        XCTAssertEqual(LoupeKeys.command(for: "9"), .colorLabel(4))
        // Lightroom gives purple no key; neither does this.
        XCTAssertNil(LoupeKeys.command(for: "5"))
    }

    /// Everything else falls through to whoever else wants it — the day this app
    /// grows a rating key, `2` must reach it.
    func testAnUnclaimedKeyFallsThrough() {
        for key in ["2", "b", "t", "\\", "[", "p", " "] {
            XCTAssertNil(LoupeKeys.command(for: key), "'\(key)' is not the loupe's")
        }
    }

    /// Left and right walk the filtered list; up and down are swallowed, because
    /// the loupe has no rows and the keystroke must not move the grid's ring
    /// underneath it.
    func testTheArrows() {
        XCTAssertEqual(LoupeKeys.command(forArrow: -1, 0), .step(-1))
        XCTAssertEqual(LoupeKeys.command(forArrow: 1, 0), .step(1))
        XCTAssertEqual(LoupeKeys.command(forArrow: 0, -1), .nothing)
        XCTAssertEqual(LoupeKeys.command(forArrow: 0, 1), .nothing)
    }
}
