import Foundation
import XCTest
@testable import GrayroomCore

/// The fingerprint is what tells a stored preview apart from the development it
/// was rendered from, so what matters about it is not the algorithm but two
/// properties: the same edit always hashes the same way, and it agrees with the
/// hash taken over the bytes the library stores.
final class EditStateFingerprintTests: XCTestCase {

    private func sampleEdit() -> EditState {
        var edit = EditState()
        edit.tone = EditState.Tone(exposure: 0.75, contrast: -12, highlights: 30,
                                   shadows: -20, whites: 5, blacks: -7)
        edit.clarity = 42
        edit.toning.shadowHue = 210
        edit.grain = .init(amount: 30, size: 45)
        edit.masks = [
            Mask(id: UUID(uuidString: "6A1E0B0C-0000-4000-8000-000000000001")!,
                 name: "Sky",
                 enabled: true,
                 adjustments: MaskAdjustments(exposure: -1.25, clarity: 15),
                 strokes: [Stroke(brush: BrushParams(size: 0.2, feather: 60),
                                  erase: false,
                                  polyline: [(0.1, 0.1), (0.4, 0.2)])]),
        ]
        return edit
    }

    func testItIsThirtyTwoBytes() {
        XCTAssertEqual(EditState().fingerprint.count, 32)
    }

    func testTheSameEditAlwaysHashesTheSame() {
        let edit = sampleEdit()
        XCTAssertEqual(edit.fingerprint, edit.fingerprint)
        XCTAssertEqual(edit.fingerprint, sampleEdit().fingerprint)
    }

    func testADifferentEditHashesDifferently() {
        var edit = sampleEdit()
        let before = edit.fingerprint
        edit.tone.exposure += 0.01
        XCTAssertNotEqual(edit.fingerprint, before)
    }

    /// Every slider is in the hash, not just the ones the pipeline happens to
    /// use — a preview of a photo whose mask moved is a different picture.
    func testEveryFieldParticipates() {
        var mutations: [(String, (inout EditState) -> Void)] = [
            ("exposure", { $0.tone.exposure = 1 }),
            ("contrast", { $0.tone.contrast = 10 }),
            ("clarity", { $0.clarity = 20 }),
            ("bw mix", { $0.bwMix.red = 30 }),
            ("toning", { $0.toning.highlightSaturation = 25 }),
            ("grain amount", { $0.grain.amount = 31 }),
            ("grain size", { $0.grain.size = 46 }),
            ("hdr", { $0.hdr = true }),
            ("white balance", { $0.whiteBalance = EditState.WhiteBalance(temperature: 4000) }),
        ]
        mutations.append(("mask enable", { $0.masks[0].enabled = false }))
        let base = sampleEdit()
        for (name, mutate) in mutations {
            var edit = base
            mutate(&edit)
            XCTAssertNotEqual(edit.fingerprint, base.fingerprint, "\(name) did not move the hash")
        }
    }

    /// The catalog load hashes the stored `edit_json` text instead of decoding
    /// it. That is only sound if both roads end at the same number — which they
    /// do because `jsonData()` sorts its keys and is what the library writes.
    func testHashingTheStoredJSONAgreesWithHashingTheEdit() throws {
        let edit = sampleEdit()
        let json = try edit.jsonData()
        XCTAssertEqual(EditState.fingerprint(ofEditJSON: json), edit.fingerprint)
        // Through the round trip the library actually performs: Data -> String
        // in the row, String -> Data on the way back out.
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertEqual(EditState.fingerprint(ofEditJSON: Data(text.utf8)), edit.fingerprint)
    }

    /// The renderer is the other half of "is the stored picture still right":
    /// the same edit through a changed pipeline is a different picture, so
    /// bumping the version has to move every key in `previews.sqlite`.
    func testTheRendererVersionIsInTheHash() throws {
        let json = try sampleEdit().jsonData()
        XCTAssertNotEqual(EditState.fingerprint(ofEditJSON: json, rendererVersion: 1),
                          EditState.fingerprint(ofEditJSON: json, rendererVersion: 2))
        XCTAssertEqual(
            EditState.fingerprint(ofEditJSON: json,
                                  rendererVersion: Pipeline.rendererVersion),
            EditState.fingerprint(ofEditJSON: json))
    }

    /// Decoding and re-encoding an edit must not move its fingerprint, or every
    /// preview would go stale the first time the app read one back.
    func testARoundTripThroughJSONKeepsTheFingerprint() throws {
        let edit = sampleEdit()
        let decoded = try EditState.decode(from: edit.jsonData())
        XCTAssertEqual(decoded, edit)
        XCTAssertEqual(decoded.fingerprint, edit.fingerprint)
    }

    func testStoredRoughnessDoesNotParticipateInDecodedEditFingerprint() throws {
        let old = try EditState.decode(from: Data(
            #"{"grain":{"amount":30,"size":45,"roughness":0}}"#.utf8))
        let current = try EditState.decode(from: Data(
            #"{"grain":{"amount":30,"size":45}}"#.utf8))

        XCTAssertEqual(old, current)
        XCTAssertEqual(old.fingerprint, current.fingerprint)
    }

    func testAddingDefaultGrainDoesNotMoveLegacyCanonicalFingerprint() throws {
        // Captured from the synthesized pre-grain encoder. A fixture, rather
        // than today's encoder generating its own expected value, catches any
        // unrelated field accidentally lost by the compatibility encoder.
        let canonical = Data("""
        {
          "bwMix" : {
            "aqua" : 0,
            "blue" : 0,
            "enabled" : true,
            "green" : 0,
            "magenta" : 0,
            "orange" : 0,
            "purple" : 0,
            "red" : 0,
            "yellow" : 0
          },
          "clarity" : 0,
          "hdr" : false,
          "masks" : [

          ],
          "tone" : {
            "blacks" : 0,
            "contrast" : 0,
            "exposure" : 0,
            "highlights" : 0,
            "shadows" : 0,
            "whites" : 0
          },
          "toning" : {
            "balance" : 0,
            "highlightHue" : 0,
            "highlightSaturation" : 0,
            "shadowHue" : 0,
            "shadowSaturation" : 0
          },
          "version" : 1,
          "whiteBalance" : {

          }
        }
        """.utf8)
        XCTAssertEqual(try EditState().jsonData(), canonical)

        let decoded = try EditState.decode(from: canonical)
        XCTAssertEqual(try decoded.jsonData(), canonical)
        XCTAssertEqual(decoded.fingerprint, EditState.fingerprint(ofEditJSON: canonical))
    }
}
