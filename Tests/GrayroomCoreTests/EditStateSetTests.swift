import Foundation
import XCTest
@testable import GrayroomCore

/// The dotted-path `--set` merge, at its edges.
///
/// This is the only writer of an `EditState` that takes free text, so every
/// malformed spelling has to land as a named error rather than as a silently
/// mangled edit — and the message is what the CLI prints.
final class EditStateSetTests: XCTestCase {

    private func maskedEdit() -> EditState {
        var edit = EditState()
        edit.masks = [Mask(name: "Mask 1", adjustments: MaskAdjustments(exposure: 0.5),
                           strokes: [Stroke(brush: BrushParams(), polyline: [(0.5, 0.5)])])]
        return edit
    }

    private func assertThrows(_ settings: [String], on edit: EditState = EditState(),
                              file: StaticString = #filePath, line: UInt = #line,
                              _ check: (EditStateError) -> Void = { _ in }) {
        XCTAssertThrowsError(try edit.applying(settings: settings), "\(settings)",
                             file: file, line: line) { error in
            guard let e = error as? EditStateError else {
                return XCTFail("expected an EditStateError, got \(error)", file: file, line: line)
            }
            check(e)
        }
    }

    // MARK: - Value parsing

    /// A value that is neither a number, a boolean nor null stays a string —
    /// which is what makes the one string-typed field settable.
    func testAStringValueReachesAStringField() throws {
        let edit = try maskedEdit().applying(settings: ["masks[0].name=Sky over the roof"])
        XCTAssertEqual(edit.masks[0].name, "Sky over the roof")
        XCTAssertEqual(edit.masks[0].adjustments.exposure, 0.5, "nothing else moved")
    }

    func testBooleanSpellings() throws {
        for spelling in ["false", "FALSE", "no", "No"] {
            XCTAssertFalse(try EditState().applying(settings: ["bwMix.enabled=\(spelling)"])
                .bwMix.enabled, spelling)
        }
        for spelling in ["true", "TRUE", "yes", "Yes"] {
            var off = EditState()
            off.bwMix.enabled = false
            XCTAssertTrue(try off.applying(settings: ["bwMix.enabled=\(spelling)"])
                .bwMix.enabled, spelling)
        }
    }

    /// `null`, `nil` and an empty value all mean "unset", which is how white
    /// balance goes back to as-shot.
    func testNullSpellingsUnsetAnOptional() throws {
        var edit = EditState()
        edit.whiteBalance = EditState.WhiteBalance(temperature: 5500, tint: 12)
        for spelling in ["null", "nil", "", "  "] {
            let cleared = try edit.applying(settings: ["whiteBalance.temperature=\(spelling)"])
            XCTAssertNil(cleared.whiteBalance.temperature, "'\(spelling)'")
            XCTAssertEqual(cleared.whiteBalance.tint, 12, "the other axis is untouched")
        }
    }

    /// A value of the wrong type is rejected at decode rather than quietly
    /// dropped: `bwMix.enabled=maybe` is a mistake, not a `false`.
    func testAValueOfTheWrongTypeIsRejected() {
        XCTAssertThrowsError(try EditState().applying(settings: ["bwMix.enabled=maybe"]))
        XCTAssertThrowsError(try EditState().applying(settings: ["tone.exposure=quite a lot"]))
    }

    /// Ranges are clamped on decode, not rejected — the documented behaviour of
    /// `--set clarity=-50`.
    func testClarityIsClampedRatherThanRejected() throws {
        XCTAssertEqual(try EditState().applying(settings: ["clarity=-50"]).clarity, 0)
        XCTAssertEqual(try EditState().applying(settings: ["clarity=500"]).clarity, 100)
        // A per-mask delta keeps the full ±100 range.
        XCTAssertEqual(try maskedEdit()
            .applying(settings: ["masks[0].adjustments.clarity=-100"])
            .masks[0].adjustments.clarity, -100)
    }

    // MARK: - Path parsing

    func testAnEmptyPathComponentIsRejected() {
        assertThrows([".enabled=false"]) { XCTAssertNotNil($0 as EditStateError) }
        assertThrows(["tone..exposure=1"])
        assertThrows(["=1"]) {
            guard case .malformedSetting = $0 else { return XCTFail("wrong error \($0)") }
        }
    }

    func testAMalformedSubscriptIsRejected() {
        let edit = maskedEdit()
        for spelling in ["masks[x].enabled=false",
                         "masks[-1].enabled=false",
                         "masks[].enabled=false",
                         "masks[0]tail.enabled=false"] {
            assertThrows([spelling], on: edit) {
                guard case .unknownKeyPath = $0 else { return XCTFail("wrong error for \(spelling)") }
            }
        }
    }

    /// A subscript on something that is not an array is a path mistake, not an
    /// index mistake.
    func testSubscriptingANonArrayIsRejected() {
        assertThrows(["tone[0]=1"]) {
            guard case .unknownKeyPath = $0 else { return XCTFail("wrong error \($0)") }
        }
    }

    /// Descending past a leaf — `masks[0].enabled.x` — is rejected rather than
    /// creating a nested object where a boolean was.
    func testDescendingThroughALeafIsRejected() {
        assertThrows(["masks[0].enabled.deeper=1"], on: maskedEdit()) {
            guard case .notAnObject = $0 else { return XCTFail("wrong error \($0)") }
        }
    }

    /// Assigning to a whole array element is not supported: `--set` edits a
    /// mask's fields, it does not replace masks.
    func testAssigningToAWholeMaskIsRejected() {
        XCTAssertThrowsError(try maskedEdit().applying(settings: ["masks[0]=null"]))
        XCTAssertThrowsError(try maskedEdit().applying(settings: ["masks[0]=whatever"]))
    }

    /// The index error names the index *and* how many elements there actually
    /// are, because that is the number the user needs.
    func testTheIndexErrorNamesTheCount() {
        assertThrows(["masks[3].enabled=false"], on: maskedEdit()) { error in
            guard case .indexOutOfRange(let key, let i, let n) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(key, "masks[3].enabled")
            XCTAssertEqual(i, 3)
            XCTAssertEqual(n, 1)
            XCTAssertEqual(error.description,
                           "index 3 out of range in 'masks[3].enabled' (1 element)")
        }
    }

    /// The messages the CLI prints, verbatim.
    func testErrorMessages() {
        XCTAssertEqual(EditStateError.unknownKeyPath("tone.nope").description,
                       "unknown edit key 'tone.nope'")
        XCTAssertEqual(EditStateError.malformedSetting("tone.exposure").description,
                       "malformed --set argument 'tone.exposure' (expected key=value)")
        XCTAssertEqual(EditStateError.notAnObject("tone").description,
                       "edit key 'tone' is not an object")
        XCTAssertEqual(EditStateError.indexOutOfRange("masks[9]", 9, 2).description,
                       "index 9 out of range in 'masks[9]' (2 elements)")
    }

    // MARK: - Application

    /// Overrides are applied left to right, so the last one wins.
    func testTheLastOverrideOfAKeyWins() throws {
        let edit = try EditState().applying(settings: ["tone.exposure=1", "tone.exposure=-2"])
        XCTAssertEqual(edit.tone.exposure, -2)
    }

    /// Whitespace around the key is trimmed; whitespace inside the value is not,
    /// except where the number parser eats it.
    func testTheKeyIsTrimmedAndNumbersToleratePadding() throws {
        let edit = try EditState().applying(settings: ["  tone.exposure  = 1.25 "])
        XCTAssertEqual(edit.tone.exposure, 1.25)
    }

    func testNoSettingsIsTheIdentity() throws {
        let edit = maskedEdit()
        XCTAssertEqual(try edit.applying(settings: []), edit)
        XCTAssertEqual(try edit.applying(keyValues: []), edit)
    }

    /// Every scalar key path the schema advertises really is settable, and the
    /// value lands where the name says. The list is derived from the schema, so
    /// this catches a field that gains a name the merge cannot reach.
    ///
    /// `masks` is the one non-scalar name on the list — the template's empty
    /// array flattens to a leaf — and it is addressed by index instead.
    func testEveryScalarKeyPathAccepts() throws {
        let scalars = EditState.settableKeyPaths.subtracting(["masks"])
        XCTAssertGreaterThan(scalars.count, 20, "the schema should have plenty of fields")

        for key in scalars {
            let isBool = key == "hdr" || key.hasSuffix("enabled")
            let value = isBool ? "true" : "1"
            let edit = try XCTUnwrap(try? EditState().applying(settings: ["\(key)=\(value)"]),
                                     "\(key) is advertised as settable but was rejected")
            // The value really moved: re-encoding puts it back where it came from.
            let json = try JSONSerialization.jsonObject(with: try edit.jsonData())
            let stored = try XCTUnwrap(leaf(key, in: json) as? NSNumber,
                                       "\(key) did not come back as a number")
            XCTAssertEqual(stored.doubleValue, 1, key)
        }
    }

    /// Walks a dotted key path through a decoded JSON object.
    private func leaf(_ key: String, in json: Any) -> Any? {
        var current: Any? = json
        for component in key.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(component)]
        }
        return current
    }
}
