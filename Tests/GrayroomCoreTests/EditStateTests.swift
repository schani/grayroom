import XCTest
@testable import GrayroomCore

final class EditStateTests: XCTestCase {

    func testDefaults() {
        let e = EditState()
        XCTAssertEqual(e.version, 1)
        XCTAssertNil(e.whiteBalance.temperature)
        XCTAssertNil(e.whiteBalance.tint)
        XCTAssertEqual(e.tone, EditState.Tone())
        XCTAssertTrue(e.bwMix.enabled)
        XCTAssertEqual(e.clarity, 0)
        XCTAssertEqual(e.toning, EditState.Toning())
        XCTAssertTrue(e.masks.isEmpty)
    }

    func testRoundTrip() throws {
        var e = EditState()
        e.whiteBalance = .init(temperature: 5200, tint: -3.5)
        e.tone = .init(exposure: 0.75, contrast: 20, highlights: -40, shadows: 33, whites: -10, blacks: 5)
        e.bwMix = .init(red: -30, orange: 5, yellow: 12, green: -8,
                        aqua: 40, blue: -60, purple: 2, magenta: -1, enabled: true)
        e.clarity = 22
        e.toning = .init(shadowHue: 215, shadowSaturation: 12,
                         highlightHue: 45, highlightSaturation: 10, balance: 10)
        e.masks = [EditState.MaskStub()]

        let data = try e.jsonData()
        // Pretty printed, as required for a human-editable sidecar.
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\n  \""))
        let back = try EditState.decode(from: data)
        XCTAssertEqual(e, back)
    }

    func testSidecarFileRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw = dir.appendingPathComponent("IMG_1234.DNG")
        let sidecar = EditState.sidecarURL(forRAW: raw)
        XCTAssertEqual(sidecar.lastPathComponent, "IMG_1234.DNG.grayroom.json")

        var e = EditState()
        e.tone.exposure = -1.25
        try e.save(to: sidecar)
        XCTAssertEqual(try EditState.load(from: sidecar), e)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = """
        {
          "version": 1,
          "futureFeature": {"a": 1, "b": [1,2,3]},
          "tone": {"exposure": 1.5, "vibrance": 30},
          "bwMix": {"red": -20},
          "toning": {"shadowHue": 200}
        }
        """
        let e = try EditState.decode(from: Data(json.utf8))
        XCTAssertEqual(e.tone.exposure, 1.5)
        XCTAssertEqual(e.tone.contrast, 0)          // missing key -> default
        XCTAssertEqual(e.bwMix.red, -20)
        XCTAssertTrue(e.bwMix.enabled)               // missing bool -> default true
        XCTAssertEqual(e.toning.shadowHue, 200)
        XCTAssertNil(e.whiteBalance.temperature)     // missing object -> default
    }

    func testEmptyObjectDecodes() throws {
        let e = try EditState.decode(from: Data("{}".utf8))
        XCTAssertEqual(e, EditState())
    }

    func testSettableKeyPaths() {
        let keys = EditState.settableKeyPaths
        for k in ["version", "clarity",
                  "whiteBalance.temperature", "whiteBalance.tint",
                  "tone.exposure", "tone.contrast", "tone.highlights",
                  "tone.shadows", "tone.whites", "tone.blacks",
                  "bwMix.red", "bwMix.orange", "bwMix.yellow", "bwMix.green",
                  "bwMix.aqua", "bwMix.blue", "bwMix.purple", "bwMix.magenta",
                  "bwMix.enabled",
                  "toning.shadowHue", "toning.shadowSaturation",
                  "toning.highlightHue", "toning.highlightSaturation", "toning.balance"] {
            XCTAssertTrue(keys.contains(k), "missing settable key \(k)")
        }
    }

    func testDottedSetMerge() throws {
        let e = try EditState().applying(settings: [
            "tone.exposure=1.0",
            "bwMix.red=-50",
            "toning.shadowHue=210",
            "bwMix.enabled=false",
            "clarity=15",
            "whiteBalance.temperature=5200",
        ])
        XCTAssertEqual(e.tone.exposure, 1.0)
        XCTAssertEqual(e.bwMix.red, -50)
        XCTAssertEqual(e.toning.shadowHue, 210)
        XCTAssertFalse(e.bwMix.enabled)
        XCTAssertEqual(e.clarity, 15)
        XCTAssertEqual(e.whiteBalance.temperature, 5200)
        // untouched fields keep their defaults
        XCTAssertEqual(e.tone.contrast, 0)
        XCTAssertEqual(e.bwMix.blue, 0)
    }

    func testSetPreservesUnrelatedSidecarValues() throws {
        var base = EditState()
        base.tone.contrast = 42
        base.bwMix.blue = -70
        let e = try base.applying(settings: ["tone.exposure=-0.5"])
        XCTAssertEqual(e.tone.contrast, 42)
        XCTAssertEqual(e.bwMix.blue, -70)
        XCTAssertEqual(e.tone.exposure, -0.5)
    }

    func testSetNullResetsWhiteBalance() throws {
        var base = EditState()
        base.whiteBalance = .init(temperature: 4000, tint: 10)
        let e = try base.applying(settings: ["whiteBalance.temperature=null"])
        XCTAssertNil(e.whiteBalance.temperature)
        XCTAssertEqual(e.whiteBalance.tint, 10)
    }

    func testSetRejectsUnknownKey() {
        XCTAssertThrowsError(try EditState().applying(settings: ["tone.vibrance=10"])) { err in
            guard case EditStateError.unknownKeyPath(let k) = err else {
                return XCTFail("wrong error \(err)")
            }
            XCTAssertEqual(k, "tone.vibrance")
        }
    }

    func testSetRejectsMalformedArgument() {
        XCTAssertThrowsError(try EditState().applying(settings: ["tone.exposure"])) { err in
            guard case EditStateError.malformedSetting = err else {
                return XCTFail("wrong error \(err)")
            }
        }
    }
}
