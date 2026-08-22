import Metal
import XCTest
@testable import GrayroomCore

/// The two output points — the file transform and the display transform — and
/// the histogram tap they share.
///
/// The invariant that matters most here is negative: turning HDR on must change
/// nothing at all about a file render of an SDR edit. Everything else is about
/// where the extra range shows up and how the histogram reports it.
final class DisplayOutputTests: XCTestCase {

    private func hdrEdit(_ on: Bool) -> EditState {
        var e = EditState()
        e.bwMix.enabled = false          // neutral patches, no mixer in the way
        e.hdr = on
        return e
    }

    // MARK: - Display mode

    /// A scene value bright enough to be pushed past SDR white keeps its
    /// headroom in HDR and is clamped in SDR — and in both cases the display
    /// texture is **linear**, not sRGB-encoded.
    func testDisplayModeKeepsHeadroomOnlyInHDR() throws {
        let (ctx, pipe) = try TestGPU.require()
        // Scene 2.0 renders (through the baseline + shoulder) to ~0.96 linear
        // against an SDR ceiling and ~1.83 against the EDR one.
        let input = try ctx.makePatchTexture([(0.18, 0.18, 0.18), (2, 2, 2)], height: 2)

        let sdr = try TextureReadback.read(
            pipe.render(input: input, edit: hdrEdit(false), output: .display).texture)
        let hdr = try TextureReadback.read(
            pipe.render(input: input, edit: hdrEdit(true), output: .display).texture)

        let sdrBright = Double(sdr.rgb(x: 1, y: 0).0)
        let hdrBright = Double(hdr.rgb(x: 1, y: 0).0)
        XCTAssertLessThanOrEqual(sdrBright, 1.0)
        XCTAssertGreaterThan(hdrBright, 1.0)
        XCTAssertLessThan(hdrBright, ToneCurve.hdrDisplayWhite)
        XCTAssertEqual(hdrBright, ToneCurve.evaluateLinear(2, EditState.Tone(),
                                                           displayWhite: ToneCurve.hdrDisplayWhite),
                       accuracy: 3e-3)

        // Linear, not encoded: the mid patch must be the curve's linear output,
        // which is a long way from its sRGB encoding.
        let mid = Double(sdr.rgb(x: 0, y: 0).0)
        let expected = ToneCurve.evaluateLinear(0.18, EditState.Tone())
        XCTAssertEqual(mid, expected, accuracy: 2e-3)
        XCTAssertGreaterThan(sRGBEncodeReference(expected) - expected, 0.2,
                             "precondition: linear and encoded are far apart here")
    }

    /// The display transform is exactly "clamp at the ceiling": in SDR it is the
    /// same picture the file gets, one transfer function earlier. Pinning them
    /// against each other is what keeps the canvas honest about what an export
    /// would contain.
    func testTheSDRDisplayTextureIsTheFileTextureBeforeEncoding() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makeTexture(width: 32, height: 24) { x, y in
            (Float(x) / 8, Float(y) / 12, 0.3)
        }
        var edit = EditState()
        edit.tone = .init(exposure: 0.4, contrast: 30, highlights: -20)
        edit.toning = .init(shadowHue: 210, shadowSaturation: 20,
                            highlightHue: 40, highlightSaturation: 15)

        let file = try TextureReadback.read(pipe.render(input: input, edit: edit).texture)
        let display = try TextureReadback.read(
            pipe.render(input: input, edit: edit, output: .display).texture)

        var worst = 0.0
        for y in 0..<24 {
            for x in 0..<32 {
                let d = display.rgb(x: x, y: y)
                let f = file.rgb(x: x, y: y)
                worst = max(worst, abs(sRGBEncodeReference(Double(d.0)) - Double(f.0)))
                worst = max(worst, abs(sRGBEncodeReference(Double(d.1)) - Double(f.1)))
                worst = max(worst, abs(sRGBEncodeReference(Double(d.2)) - Double(f.2)))
            }
        }
        // Half-float quantisation of both textures, nothing more.
        XCTAssertLessThan(worst, 2e-3)
    }

    /// The file path is the default and is untouched by any of this: same
    /// kernel, same clamp, `hdr` not consulted by the output stage at all.
    func testFileModeIsUnchangedAndAlwaysSDR() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture([(0.05, 0.05, 0.05), (0.18, 0.18, 0.18),
                                              (2, 2, 2), (64, 64, 64)], height: 2)
        let sdrFile = try TextureReadback.read(
            pipe.render(input: input, edit: hdrEdit(false)).texture)
        for i in 0..<4 {
            let (r, g, b) = sdrFile.rgb(x: i, y: 0)
            for c in [r, g, b] {
                XCTAssertGreaterThanOrEqual(Double(c), 0)
                XCTAssertLessThanOrEqual(Double(c), 1)
            }
        }
        // sRGB-encoded, i.e. well above the linear value in the midtones.
        XCTAssertEqual(Double(sdrFile.rgb(x: 1, y: 0).0),
                       sRGBEncodeReference(ToneCurve.evaluateLinear(0.18, EditState.Tone())),
                       accuracy: 2e-3)

        // An HDR edit exported to a file is that rendition *clipped*: the curve
        // rolls off into headroom the file cannot hold, so the brights land on
        // 1.0. That is the documented deviation, asserted rather than implied.
        let hdrFile = try TextureReadback.read(
            pipe.render(input: input, edit: hdrEdit(true)).texture)
        XCTAssertEqual(Double(hdrFile.rgb(x: 2, y: 0).0), 1.0, accuracy: 1e-3)
        XCTAssertLessThan(Double(sdrFile.rgb(x: 2, y: 0).0), 0.999)
        // ... and below the shoulder knee the two files agree exactly.
        XCTAssertEqual(hdrFile.rgb(x: 0, y: 0).0, sdrFile.rgb(x: 0, y: 0).0)
    }

    // MARK: - Histogram tap

    /// The tap reads the linear image and scales by the ceiling, so "highlight
    /// clipped" means "at or above what the output can show". A pixel that sits
    /// between SDR white and the EDR ceiling is clipped in SDR and is not in
    /// HDR; one driven past the ceiling is clipped in both.
    func testTheHistogramScalesWithTheDisplayCeiling() throws {
        let (ctx, pipe) = try TestGPU.require()
        // black
        // | scene 46 — the top of the LUT domain, where the shoulder has run
        //   all the way into its asymptote: 0.9994 linear against the SDR
        //   ceiling (encoded 255, clipped) and 3.34 against the EDR one (0.84
        //   of the ceiling, comfortably inside the plot)
        // | scene 1000 — past the domain, so the endpoint gain extrapolates it
        //   above *either* ceiling
        let input = try ctx.makePatchTexture([(0, 0, 0), (46, 46, 46), (1000, 1000, 1000)],
                                             height: 2)

        let sdr = try XCTUnwrap(pipe.render(input: input, edit: hdrEdit(false),
                                            output: .display, computeHistogram: true).histogram)
        let hdr = try XCTUnwrap(pipe.render(input: input, edit: hdrEdit(true),
                                            output: .display, computeHistogram: true).histogram)

        XCTAssertEqual(sdr.pixelCount, 6)
        XCTAssertEqual(sdr.bins.reduce(0, +), 6)
        XCTAssertEqual(hdr.bins.reduce(0, +), 6)

        // Shadows are the same in both: the ceiling does not move the floor.
        XCTAssertEqual(sdr.shadowClippedPixels, 2)
        XCTAssertEqual(hdr.shadowClippedPixels, 2)
        XCTAssertEqual(sdr.bins[0], 2)
        XCTAssertEqual(hdr.bins[0], 2)

        // In SDR both bright patches are against the ceiling.
        XCTAssertEqual(sdr.highlightClippedPixels, 4)
        XCTAssertEqual(sdr.bins[255], 4)

        // In HDR only the one that is genuinely past W is.
        XCTAssertEqual(hdr.highlightClippedPixels, 2)
        XCTAssertEqual(hdr.bins[255], 2)
        // ... and the other has moved back into the plot, at sRGBEncode(Y/W).
        let y = ToneCurve.evaluateLinear(46, EditState.Tone(),
                                         displayWhite: ToneCurve.hdrDisplayWhite)
        XCTAssertGreaterThan(y, 1.0)
        XCTAssertLessThan(y, ToneCurve.hdrDisplayWhite)
        let bin = min(Int(sRGBEncodeReference(y / ToneCurve.hdrDisplayWhite) * 256), 255)
        XCTAssertEqual(hdr.bins[bin - 1] + hdr.bins[bin] + hdr.bins[bin + 1], 2)
    }

    /// A **file** render reports the file: the ceiling is SDR white whatever
    /// `hdr` says, because that is what the exported bytes will hold.
    func testAFileHistogramAlwaysMeasuresAgainstSDRWhite() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture([(1, 1, 1)], height: 2)
        let h = try XCTUnwrap(pipe.render(input: input, edit: hdrEdit(true),
                                          computeHistogram: true).histogram)
        XCTAssertEqual(h.highlightClippedPixels, 2)
        XCTAssertEqual(h.bins[255], 2)
    }

    /// The linear tap is arithmetically the old output-referred one at `W = 1`.
    /// It is computed at float precision instead of after the encoded value's
    /// half-float round trip, so a bin may move by an ulp — hence "almost every
    /// pixel", not "every pixel".
    func testTheLinearTapReproducesTheOutputReferredHistogram() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makeTexture(width: 128, height: 96) { x, y in
            let v = Float(x + y) / 200 + 0.002
            return (v, v * 0.9, v * 1.1)
        }
        var edit = EditState()
        edit.tone = .init(exposure: 0.5, contrast: 20)
        let h = try XCTUnwrap(pipe.render(input: input, edit: edit,
                                          computeHistogram: true).histogram)

        // Reference: bin the *file* texture exactly as the old kernel did.
        let file = try TextureReadback.read(pipe.render(input: input, edit: edit).texture)
        var reference = [Int](repeating: 0, count: 256)
        for y in 0..<file.height {
            for x in 0..<file.width {
                let (r, g, b) = file.rgb(x: x, y: y)
                let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                reference[min(Int(min(max(luma, 0), 1) * 256), 255)] += 1
            }
        }
        var moved = 0
        for i in 0..<256 { moved += abs(Int(h.bins[i]) - reference[i]) }
        XCTAssertEqual(h.bins.reduce(0, +), UInt32(file.width * file.height))
        XCTAssertLessThan(Double(moved) / Double(2 * file.width * file.height), 0.02,
                          "the linear tap disagrees with the output-referred one by more "
                          + "than half-float rounding")
    }
}
