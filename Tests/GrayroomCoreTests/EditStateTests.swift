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
        XCTAssertFalse(e.hdr)
        XCTAssertEqual(e.displayWhite, 1.0)
    }

    /// `hdr` is an ordinary field: it round-trips, it defaults to false when the
    /// stored JSON has no such key, and `--set hdr=true` reaches it through the
    /// generic dotted-path merge with no special case.
    func testHDRRoundTripsAndDefaultsOffWhenAbsent() throws {
        var e = EditState()
        e.hdr = true
        e.tone.exposure = 0.5
        let back = try EditState.decode(from: try e.jsonData())
        XCTAssertEqual(back, e)
        XCTAssertTrue(back.hdr)
        XCTAssertEqual(back.displayWhite, ToneCurve.hdrDisplayWhite)

        // An edit stored without the `hdr` key: every other field is honoured
        // and the render stays SDR.
        let old = """
        {"version": 1, "tone": {"exposure": 1.5}, "clarity": 30}
        """
        let loaded = try EditState.decode(from: Data(old.utf8))
        XCTAssertFalse(loaded.hdr)
        XCTAssertEqual(loaded.tone.exposure, 1.5)
        XCTAssertEqual(loaded.clarity, 30)

        XCTAssertTrue(EditState.settableKeyPaths.contains("hdr"))
        XCTAssertTrue(try EditState().applying(settings: ["hdr=true"]).hdr)
        XCTAssertFalse(try e.applying(settings: ["hdr=false"]).hdr)
        // ... and it does not disturb anything else.
        XCTAssertEqual(try EditState().applying(settings: ["hdr=true"]).tone, EditState.Tone())
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
        e.masks = [Mask(name: "sky",
                        adjustments: MaskAdjustments(exposure: -0.8, contrast: 15, clarity: 20),
                        strokes: [Stroke(brush: BrushParams(size: 0.25, feather: 60),
                                         polyline: [(0.1, 0.2), (0.9, 0.2)])])]

        let data = try e.jsonData()
        // Pretty printed, as required for human-readable JSON.
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\n  \""))
        let back = try EditState.decode(from: data)
        XCTAssertEqual(e, back)
    }

    func testJSONFileRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("edit.json")

        var e = EditState()
        e.tone.exposure = -1.25
        try e.save(to: url)
        XCTAssertEqual(try EditState.load(from: url), e)
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

    func testSetPreservesUnrelatedValues() throws {
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

    // MARK: - Masks (M3)

    func testMasksRoundTrip() throws {
        var e = EditState()
        e.clarity = 25
        e.masks = [
            Mask(name: "sky",
                 adjustments: MaskAdjustments(exposure: -0.8, contrast: 15, clarity: 20),
                 strokes: [
                    Stroke(brush: BrushParams(size: 0.25, feather: 60, flow: 100, density: 100),
                           points: [StrokePoint(x: -0.05, y: 0.06),
                                    StrokePoint(x: 0.5, y: 0.07, pressure: 0.6),
                                    StrokePoint(x: 1.05, y: 0.06)]),
                    Stroke(brush: BrushParams(size: 0.1, feather: 20, flow: 40, density: 70),
                           erase: true,
                           polyline: [(0.4, 0.1), (0.6, 0.2)]),
                 ]),
            Mask(name: "face", enabled: false,
                 adjustments: MaskAdjustments(highlights: -30, shadows: 40),
                 strokes: []),
        ]

        let data = try e.jsonData()
        let back = try EditState.decode(from: data)
        XCTAssertEqual(e, back)
        XCTAssertEqual(back.masks[0].strokes[0].points[1].pressure, 0.6)
        XCTAssertTrue(back.masks[0].strokes[1].erase)
        XCTAssertFalse(back.masks[1].enabled)
        XCTAssertEqual(back.activeMasks.count, 1, "disabled and strokeless masks are inactive")
        // The schema version does not move: `masks` was already part of v1.
        XCTAssertEqual(back.version, 1)
    }

    /// Pre-M3 edits were stored with `"masks": []` (and older ones had no key at
    /// all).
    func testLegacyMasksDecode() throws {
        let legacy = """
        {"version": 1, "clarity": 10, "masks": [], "tone": {"exposure": 0.5}}
        """
        let e = try EditState.decode(from: Data(legacy.utf8))
        XCTAssertTrue(e.masks.isEmpty)
        XCTAssertEqual(e.clarity, 10)
        XCTAssertEqual(e.tone.exposure, 0.5)

        // Partial masks fall back to defaults key by key.
        let partial = """
        {"masks": [{"strokes": [{"points": [{"x": 0.5, "y": 0.5}]}]}]}
        """
        let p = try EditState.decode(from: Data(partial.utf8))
        XCTAssertEqual(p.masks.count, 1)
        XCTAssertTrue(p.masks[0].enabled)
        XCTAssertEqual(p.masks[0].adjustments, MaskAdjustments())
        XCTAssertEqual(p.masks[0].strokes[0].brush, BrushParams())
        XCTAssertEqual(p.masks[0].strokes[0].points[0].pressure, 1)
        XCTAssertFalse(p.masks[0].strokes[0].erase)
    }

    func testSetReachesMasksByIndex() throws {
        var base = EditState()
        base.masks = [
            Mask(name: "a", adjustments: MaskAdjustments(exposure: 0.5)),
            Mask(name: "b", adjustments: MaskAdjustments(clarity: 10)),
        ]
        let e = try base.applying(settings: [
            "masks[0].adjustments.exposure=1.5",
            "masks[1].adjustments.clarity=-40",
            "masks[1].enabled=false",
            "tone.contrast=20",
        ])
        XCTAssertEqual(e.masks[0].adjustments.exposure, 1.5)
        XCTAssertEqual(e.masks[1].adjustments.clarity, -40)
        XCTAssertFalse(e.masks[1].enabled)
        XCTAssertTrue(e.masks[0].enabled)
        XCTAssertEqual(e.masks[0].id, base.masks[0].id, "unrelated fields survive the merge")
        XCTAssertEqual(e.tone.contrast, 20)

        // Out of range and unknown leaves are rejected, and --set cannot create
        // a mask (strokes come from the stored edit).
        XCTAssertThrowsError(try base.applying(settings: ["masks[2].enabled=false"])) { err in
            guard case EditStateError.indexOutOfRange(_, let i, let n) = err else {
                return XCTFail("wrong error \(err)")
            }
            XCTAssertEqual(i, 2)
            XCTAssertEqual(n, 2)
        }
        XCTAssertThrowsError(try base.applying(settings: ["masks[0].adjustments.vibrance=1"])) { err in
            guard case EditStateError.unknownKeyPath = err else { return XCTFail("wrong error \(err)") }
        }
        XCTAssertThrowsError(try EditState().applying(settings: ["masks[0].enabled=false"]))
    }

    func testSetRejectsMalformedArgument() {
        XCTAssertThrowsError(try EditState().applying(settings: ["tone.exposure"])) { err in
            guard case EditStateError.malformedSetting = err else {
                return XCTFail("wrong error \(err)")
            }
        }
    }

    /// `clarityActive` is what both the pipeline (does the clarity stage run?)
    /// and the preview loop (is this edit expensive enough to draft?) ask, so
    /// the two can never disagree about the frame in front of them.
    func testClarityActiveMatchesWhenTheStageWouldRun() {
        XCTAssertFalse(EditState().clarityActive)

        var global = EditState()
        global.clarity = 1
        XCTAssertTrue(global.clarityActive)

        // A mask that would move clarity, but is identity overall, cannot.
        var identityMask = EditState()
        identityMask.masks = [Mask(name: "m")]
        XCTAssertFalse(identityMask.clarityActive)

        var local = EditState()
        var mask = Mask(name: "m")
        mask.adjustments.clarity = 40
        mask.strokes = [Stroke(brush: BrushParams(), polyline: [(0.5, 0.5)])]
        local.masks = [mask]
        XCTAssertTrue(local.clarityActive)

        // A negative delta still means the clarity stage runs (the mask carves
        // a region out of a global lift), so it counts as active too.
        var negative = local
        negative.masks[0].adjustments.clarity = -40
        XCTAssertTrue(negative.clarityActive)

        // A mask with no clarity of its own does not make the stage run.
        var toneOnly = local
        toneOnly.masks[0].adjustments.clarity = 0
        toneOnly.masks[0].adjustments.exposure = 1
        XCTAssertFalse(toneOnly.clarityActive)
    }
}
