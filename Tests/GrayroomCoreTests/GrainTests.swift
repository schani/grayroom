import Metal
import XCTest
@testable import GrayroomCore

final class GrainTests: XCTestCase {
    private static let sharedStage: Result<(MetalContext, GrainStage), Error> = Result {
        let context = try MetalContext()
        return (context, try GrainStage(context: context))
    }

    private func stage() throws -> (MetalContext, GrainStage) {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        // Do not use TestGPU.shared here: it intentionally turns shader compile
        // failures into skips, while a broken grain kernel must fail this suite.
        return try Self.sharedStage.get()
    }

    private func render(width: Int = 6000,
                        height: Int = 8,
                        value: Float = 0.18,
                        grain: EditState.Grain,
                        displayWhite: Double = 1) throws -> FloatImage {
        let (context, grainStage) = try stage()
        let input = try context.makeTexture(width: width, height: height) { _, _ in
            (value, value, value)
        }
        let output = try context.makeWorkingTexture(width: width, height: height)
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw MetalError.encoderFailed }
        try grainStage.encode(cb, source: input, destination: output, grain: grain,
                              displayWhite: displayWhite)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return try TextureReadback.read(output)
    }

    private func render(width: Int = 6000,
                        height: Int = 8,
                        rgb: (Float, Float, Float),
                        alpha: Float = 1,
                        grain: EditState.Grain,
                        displayWhite: Double = 1) throws -> FloatImage {
        let (context, grainStage) = try stage()
        let input = try context.makeRGBATexture(width: width, height: height) { _, _ in
            (rgb.0, rgb.1, rgb.2, alpha)
        }
        let output = try context.makeWorkingTexture(width: width, height: height)
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw MetalError.encoderFailed }
        try grainStage.encode(cb, source: input, destination: output, grain: grain,
                              displayWhite: displayWhite)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        return try TextureReadback.read(output)
    }

    private func channel(_ image: FloatImage) -> [Double] {
        (0..<image.height).flatMap { y in
            (0..<image.width).map { x in Double(image.rgb(x: x, y: y).0) }
        }
    }

    private func luminance(_ image: FloatImage) -> [Double] {
        (0..<image.height).flatMap { y in
            (0..<image.width).map { x in
                let rgb = image.rgb(x: x, y: y)
                return 0.2126 * Double(rgb.0) + 0.7152 * Double(rgb.1) + 0.0722 * Double(rgb.2)
            }
        }
    }

    private func luminance(_ rgb: (Float, Float, Float)) -> Float {
        0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
    }

    private func clamped(_ rgb: (Float, Float, Float), to ceiling: Float)
        -> (Float, Float, Float) {
        (min(max(rgb.0, 0), ceiling),
         min(max(rgb.1, 0), ceiling),
         min(max(rgb.2, 0), ceiling))
    }

    private func rgbValues(_ image: FloatImage) -> [Double] {
        (0..<image.height).flatMap { y in
            (0..<image.width).flatMap { x in
                let rgb = image.rgb(x: x, y: y)
                return [Double(rgb.0), Double(rgb.1), Double(rgb.2)]
            }
        }
    }

    private func meanRGB(_ image: FloatImage) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let rgb = image.rgb(x: x, y: y)
                r += Double(rgb.0)
                g += Double(rgb.1)
                b += Double(rgb.2)
            }
        }
        let count = Double(image.width * image.height)
        return (r / count, g / count, b / count)
    }

    private func meanDisplayedRGB(_ image: FloatImage) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let rgb = image.rgb(x: x, y: y)
                r += sRGBEncodeReference(Double(rgb.0))
                g += sRGBEncodeReference(Double(rgb.1))
                b += sRGBEncodeReference(Double(rgb.2))
            }
        }
        let count = Double(image.width * image.height)
        return (r / count, g / count, b / count)
    }

    private func saturation(_ rgb: (Double, Double, Double)) -> Double {
        let lo = min(rgb.0, min(rgb.1, rgb.2))
        let hi = max(rgb.0, max(rgb.1, rgb.2))
        return hi > 0 ? (hi - lo) / hi : 0
    }

    private func skyCases(displayWhite: Float)
        -> [(String, (Float, Float, Float))] {
        let w = displayWhite
        return [
            ("blue near white", (0.18 * w, 0.42 * w, 0.92 * w)),
            ("blue at white", (0.12 * w, 0.32 * w, 1.00 * w)),
            ("blue above white", (0.12 * w, 0.32 * w, 1.20 * w)),
            ("lavender near white", (0.54 * w, 0.46 * w, 0.92 * w)),
            ("lavender above white", (0.62 * w, 0.48 * w, 1.10 * w)),
            ("cyan near white", (0.08 * w, 0.55 * w, 0.94 * w)),
            ("cyan at white", (0.05 * w, 0.48 * w, 1.00 * w)),
            ("pale neutral", (0.92 * w, 0.92 * w, 0.92 * w)),
        ]
    }

    private func dimensions(scale: Double, height: Int = 8) -> (width: Int, height: Int) {
        (Int((GrainMapping.referenceWidth / scale).rounded()), height)
    }

    private func rgba(_ image: FloatImage, x: Int, y: Int) -> (Float, Float, Float, Float) {
        let i = (y * image.width + x) * 4
        return (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2], image.pixels[i + 3])
    }

    private func mean(_ xs: [Double]) -> Double {
        xs.reduce(0, +) / Double(xs.count)
    }

    private func standardDeviation(_ xs: [Double]) -> Double {
        let m = mean(xs)
        return sqrt(xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count))
    }

    private func horizontalCorrelation(_ image: FloatImage, lag: Int) -> Double {
        var a: [Double] = [], b: [Double] = []
        for y in 0..<image.height {
            for x in 0..<(image.width - lag) {
                a.append(Double(image.rgb(x: x, y: y).0))
                b.append(Double(image.rgb(x: x + lag, y: y).0))
            }
        }
        let am = mean(a), bm = mean(b)
        let covariance = zip(a, b).reduce(0) { $0 + ($1.0 - am) * ($1.1 - bm) }
        let av = a.reduce(0) { $0 + ($1 - am) * ($1 - am) }
        let bv = b.reduce(0) { $0 + ($1 - bm) * ($1 - bm) }
        return covariance / sqrt(av * bv)
    }

    private func verticalCorrelation(_ image: FloatImage, lag: Int) -> Double {
        var a: [Double] = [], b: [Double] = []
        for y in 0..<(image.height - lag) {
            for x in 0..<image.width {
                a.append(Double(image.rgb(x: x, y: y).0))
                b.append(Double(image.rgb(x: x, y: y + lag).0))
            }
        }
        return correlation(a, b)
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let am = mean(a), bm = mean(b)
        let covariance = zip(a, b).reduce(0) { $0 + ($1.0 - am) * ($1.1 - bm) }
        let av = a.reduce(0) { $0 + ($1 - am) * ($1 - am) }
        let bv = b.reduce(0) { $0 + ($1 - bm) * ($1 - bm) }
        return covariance / sqrt(av * bv)
    }

    func testAmountZeroIsBitIdenticalEvenWithNondefaultSize() throws {
        let (context, pipeline) = try TestGPU.require()
        let input = try context.makeTexture(width: 80, height: 64) { x, y in
            let value = Float(x + y + 1) / 200
            return (value, value * 0.8, value * 0.6)
        }
        let plain = try pipeline.render(input: input, edit: EditState(), upTo: .grain).texture
        var edit = EditState()
        edit.grain = .init(amount: 0, size: 100)
        let zero = try pipeline.render(input: input, edit: edit, upTo: .grain).texture
        XCTAssertEqual(try TextureReadback.read(plain).pixels,
                       try TextureReadback.read(zero).pixels)
    }

    func testGrainIsDeterministicMonochromaticAndPreservesAlpha() throws {
        let (context, grainStage) = try stage()
        let input = try context.makeRGBATexture(width: 6000, height: 8) { _, _ in
            (0.12, 0.24, 0.36, 0.4)
        }
        func run() throws -> FloatImage {
            let output = try context.makeWorkingTexture(width: input.width, height: input.height)
            guard let cb = context.commandQueue.makeCommandBuffer() else {
                throw MetalError.encoderFailed
            }
            try grainStage.encode(cb, source: input, destination: output,
                                  grain: .init(amount: 65, size: 40), displayWhite: 1)
            cb.commit(); cb.waitUntilCompleted()
            if let error = cb.error { throw error }
            return try TextureReadback.read(output)
        }

        let first = try run(), second = try run()
        for y in 0..<first.height {
            for x in 0..<first.width {
                let a = rgba(first, x: x, y: y), b = rgba(second, x: x, y: y)
                XCTAssertEqual(a.0, b.0)
                XCTAssertEqual(a.1, b.1)
                XCTAssertEqual(a.2, b.2)
                XCTAssertEqual(a.3, b.3)
                XCTAssertEqual(Double(a.1 / a.0), 2, accuracy: 0.015)
                XCTAssertEqual(Double(a.2 / a.0), 3, accuracy: 0.025)
                XCTAssertEqual(a.3, Float(Float16(0.4)))
            }
        }
    }

    func testSaturatedSkyGrainRemainsVisibleAtNativeAndReducedScales() throws {
        let cases: [((Float, Float, Float), Double, Double)] = [
            ((0.12, 0.32, 1.0), 1, 1),
            ((0.05, 0.48, 1.0), 1, 1),
            ((0.12, 0.32, 1.2), 1, 1),
            ((0.12, 0.32, 1.0), 4, 1),
            ((0.05, 0.48, 1.0), 4, 1),
            ((0.12, 0.32, 1.2), 4, 1),
            ((0.48, 1.28, 4.0), 1, 4),
            ((0.20, 1.92, 4.0), 1, 4),
            ((0.48, 1.28, 4.8), 1, 4),
        ]
        let grain = EditState.Grain(amount: 100, size: 70)

        for (patch, scale, displayWhite) in cases {
            let size = dimensions(scale: scale)
            let colored = try render(width: size.width, height: size.height,
                                     rgb: patch, grain: grain, displayWhite: displayWhite)
            let visibleBase = clamped(patch, to: Float(displayWhite))
            let y = luminance(visibleBase)
            let neutral = try render(width: size.width, height: size.height,
                                     rgb: (y, y, y), grain: grain,
                                     displayWhite: displayWhite)
            let coloredLuminance = luminance(colored)
            let coloredSD = standardDeviation(coloredLuminance)
            let neutralSD = standardDeviation(luminance(neutral))
            let channels = rgbValues(colored)

            XCTAssertGreaterThan(coloredSD, 0.001,
                                 "patch \(patch), scale \(scale), white \(displayWhite)")
            XCTAssertGreaterThan(coloredSD, neutralSD * 0.5,
                                 "patch \(patch), scale \(scale), white \(displayWhite), neutral SD \(neutralSD)")
            XCTAssertEqual(mean(coloredLuminance), Double(y),
                           accuracy: 0.006 * displayWhite,
                           "patch \(patch), scale \(scale), white \(displayWhite)")
            XCTAssertGreaterThanOrEqual(channels.min()!, -0.001)
            XCTAssertLessThanOrEqual(channels.max()!, displayWhite + 0.001)
        }
    }

    func testSkyGrainPreservesAverageColorAcrossSDRHDRAndScale() throws {
        for displayWhite in [Float(1), Float(4)] {
            for (name, patch) in skyCases(displayWhite: displayWhite) {
                let reference = clamped(patch, to: displayWhite)
                let referenceRGB = (Double(reference.0), Double(reference.1),
                                    Double(reference.2))
                for scale in [1.0, 4.0] {
                    for amount in [25.0, 100.0] {
                        let size = dimensions(scale: scale)
                        let image = try render(width: size.width, height: size.height,
                                               rgb: patch,
                                               grain: .init(amount: amount, size: 70),
                                               displayWhite: Double(displayWhite))
                        let average = meanRGB(image)
                        let tolerance = Double(displayWhite) * 0.008
                        let context = "\(name), W \(displayWhite), scale \(scale), amount \(amount)"

                        XCTAssertEqual(average.0, referenceRGB.0,
                                       accuracy: tolerance, context)
                        XCTAssertEqual(average.1, referenceRGB.1,
                                       accuracy: tolerance, context)
                        XCTAssertEqual(average.2, referenceRGB.2,
                                       accuracy: tolerance, context)
                        XCTAssertEqual(saturation(average), saturation(referenceRGB),
                                       accuracy: 0.02, context)
                        let channels = rgbValues(image)
                        XCTAssertTrue(channels.allSatisfy(\.isFinite), context)
                        XCTAssertGreaterThanOrEqual(channels.min()!, -0.001, context)
                        XCTAssertLessThanOrEqual(channels.max()!,
                                                 Double(displayWhite) + 0.001, context)
                    }
                }
            }
        }
    }

    func testDisplayedSDRSkyColorDoesNotWashOut() throws {
        for (name, patch) in skyCases(displayWhite: 1) {
            let visible = clamped(patch, to: 1)
            let reference = (sRGBEncodeReference(Double(visible.0)),
                             sRGBEncodeReference(Double(visible.1)),
                             sRGBEncodeReference(Double(visible.2)))
            for amount in [25.0, 100.0] {
                let image = try render(rgb: patch,
                                       grain: .init(amount: amount, size: 70))
                let displayed = meanDisplayedRGB(image)
                let context = "\(name), amount \(amount)"

                XCTAssertEqual(saturation(displayed), saturation(reference),
                               accuracy: 0.025, context)
                if reference.2 - reference.0 > 0.05 {
                    let expectedHue = (reference.1 - reference.0)
                                    / (reference.2 - reference.0)
                    let displayedHue = (displayed.1 - displayed.0)
                                     / (displayed.2 - displayed.0)
                    XCTAssertEqual(displayedHue, expectedHue, accuracy: 0.025, context)
                }
            }
        }
    }

    func testSkyGrainAmountControlsAStableVisiblePattern() throws {
        for displayWhite in [Float(1), Float(4)] {
            for (name, patch) in skyCases(displayWhite: displayWhite) {
                for scale in [1.0, 4.0] {
                    let size = dimensions(scale: scale)
                    let low = try render(width: size.width, height: size.height,
                                         rgb: patch,
                                         grain: .init(amount: 25, size: 70),
                                         displayWhite: Double(displayWhite))
                    let high = try render(width: size.width, height: size.height,
                                          rgb: patch,
                                          grain: .init(amount: 100, size: 70),
                                          displayWhite: Double(displayWhite))
                    let lowY = luminance(low)
                    let highY = luminance(high)
                    let context = "\(name), W \(displayWhite), scale \(scale)"

                    XCTAssertGreaterThan(standardDeviation(lowY),
                                         Double(displayWhite) * 0.0002, context)
                    XCTAssertGreaterThan(standardDeviation(highY),
                                         standardDeviation(lowY) * 1.5, context)
                    XCTAssertGreaterThan(correlation(lowY, highY), 0.98, context)
                }
            }
        }
    }

    func testAmountControlsVisibleSkyGrainAtNativeAndReducedScales() throws {
        let patches: [(Float, Float, Float)] = [
            (0.12, 0.32, 1.0),
            (0.05, 0.48, 1.0),
        ]
        for scale in [1.0, 4.0] {
            for patch in patches {
                let size = dimensions(scale: scale)
                let low = try render(width: size.width, height: size.height, rgb: patch,
                                     grain: .init(amount: 25, size: 70))
                let high = try render(width: size.width, height: size.height, rgb: patch,
                                      grain: .init(amount: 100, size: 70))
                let lowSD = standardDeviation(luminance(low))
                let highSD = standardDeviation(luminance(high))

                XCTAssertGreaterThan(lowSD, 0.001, "patch \(patch), scale \(scale)")
                XCTAssertGreaterThan(highSD, lowSD * 1.5,
                                     "patch \(patch), scale \(scale), low SD \(lowSD), high SD \(highSD)")
            }
        }
    }

    func testColorPipelineAppliesGrainWhenBWMixIsDisabled() throws {
        let (context, pipeline) = try TestGPU.require()
        let patch: (Float, Float, Float) = (0.12, 0.32, 1.0)
        let input = try context.makeTexture(width: 6000, height: 8) { _, _ in
            patch
        }
        let y = luminance(patch)
        let neutralInput = try context.makeTexture(width: 6000, height: 8) { _, _ in
            (y, y, y)
        }
        var edit = EditState()
        edit.bwMix.enabled = false
        edit.grain = .init(amount: 100, size: 70)

        let first = try TextureReadback.read(
            pipeline.render(input: input, edit: edit, upTo: .output, output: .display).texture)
        let second = try TextureReadback.read(
            pipeline.render(input: input, edit: edit, upTo: .output, output: .display).texture)
        let neutral = try TextureReadback.read(
            pipeline.render(input: neutralInput, edit: edit,
                            upTo: .output, output: .display).texture)

        let coloredSD = standardDeviation(luminance(first))
        XCTAssertGreaterThan(coloredSD, 0.001)
        XCTAssertGreaterThan(coloredSD, standardDeviation(luminance(neutral)) * 0.5)
        XCTAssertEqual(first.pixels, second.pixels)
        for value in first.pixels { XCTAssertTrue(value.isFinite) }
    }

    func testOutOfGamutSkyGrainIsDeterministicFiniteAndPreservesAlpha() throws {
        let grain = EditState.Grain(amount: 100, size: 70)
        let first = try render(width: 6000, height: 8, rgb: (0.12, 0.32, 1.2), alpha: 0.37,
                               grain: grain)
        let second = try render(width: 6000, height: 8, rgb: (0.12, 0.32, 1.2), alpha: 0.37,
                                grain: grain)

        XCTAssertEqual(first.pixels, second.pixels)
        for value in first.pixels { XCTAssertTrue(value.isFinite) }
        for y in 0..<first.height {
            for x in 0..<first.width {
                XCTAssertEqual(rgba(first, x: x, y: y).3, Float(Float16(0.37)))
            }
        }
    }

    func testAmountControlsStrengthWithoutMovingMeanDensity() throws {
        let low = channel(try render(grain: .init(amount: 20, size: 35)))
        let high = channel(try render(grain: .init(amount: 80, size: 35)))
        XCTAssertGreaterThan(standardDeviation(high), standardDeviation(low) * 3.2)
        XCTAssertEqual(mean(low), 0.18, accuracy: 0.001)
        XCTAssertEqual(mean(high), 0.18, accuracy: 0.002)
    }

    func testSizeControlsSpatialCorrelation() throws {
        let fine = try render(grain: .init(amount: 60, size: 0))
        let coarse = try render(grain: .init(amount: 60, size: 100))
        XCTAssertGreaterThan(horizontalCorrelation(coarse, lag: 1),
                             horizontalCorrelation(fine, lag: 1) + 0.25)
    }

    func testSizeZeroIsSinglePixelGrainAtOneHundredMegapixels() throws {
        let image = try render(width: 11_608, height: 64,
                               grain: .init(amount: 100, size: 0))
        let values = channel(image)

        XCTAssertGreaterThan(standardDeviation(values), 0.01)
        XCTAssertEqual(mean(values), 0.18, accuracy: 0.003)
        XCTAssertTrue(values.allSatisfy(\.isFinite))
        XCTAssertLessThan(abs(horizontalCorrelation(image, lag: 1)), 0.1)
        XCTAssertLessThan(abs(verticalCorrelation(image, lag: 1)), 0.1)
    }

    func testSizeMappingIsRelativeToImageWidth() {
        XCTAssertEqual(GrainMapping.radiusFraction(size: 0), 0.25 / 6000,
                       accuracy: 1e-12)
        for size in [25.0, 40.0, 70.0, 100.0] {
            XCTAssertEqual(GrainMapping.radiusFraction(size: size),
                           0.65 * exp2(size / 39.3) / 6000, accuracy: 1e-12,
                           "size \(size)")
        }
        let belowDefault = stride(from: 0.0, through: 25.0, by: 0.25)
            .map { GrainMapping.radiusFraction(size: $0) }
        for pair in zip(belowDefault, belowDefault.dropFirst()) {
            XCTAssertGreaterThan(pair.1, pair.0)
        }
        XCTAssertEqual(GrainMapping.radiusFraction(size: -10),
                       GrainMapping.radiusFraction(size: 0))
        XCTAssertEqual(GrainMapping.radiusFraction(size: 110),
                       GrainMapping.radiusFraction(size: 100))
    }

    func testPureBlackAndDisplayWhiteAreProtectedIncludingHDR() throws {
        for (value, white) in [(Float(0), 1.0), (Float(1), 1.0), (Float(4), 4.0)] {
            let result = try render(width: 64, height: 64, value: value,
                                    grain: .init(amount: 100, size: 100),
                                    displayWhite: white)
            for pixel in channel(result) { XCTAssertEqual(pixel, Double(value), accuracy: 0.0001) }
        }
    }

    func testNearWhiteGrainDoesNotClipOrShiftMeanIncludingHDR() throws {
        for (value, white) in [(Float(0.75), 1.0), (Float(0.9), 1.0),
                               (Float(3), 4.0), (Float(3.6), 4.0)] {
            let values = channel(try render(width: 6000, height: 16, value: value,
                                            grain: .init(amount: 100, size: 70),
                                            displayWhite: white))
            XCTAssertLessThanOrEqual(values.max()!, white + 0.001)
            XCTAssertGreaterThanOrEqual(values.min()!, 0)
            XCTAssertEqual(mean(values), Double(value), accuracy: 0.006)
        }
    }

    func testMinifiedGrainTracksAveragedFullResolutionVariance() throws {
        let grain = EditState.Grain(amount: 75, size: 100)
        let full = try render(width: 6000, height: 96, grain: grain)
        let fullValues = channel(full)

        for factor in [2, 4, 12] {
            let width = 6000 / factor
            let height = 96 / factor
            var averaged = [Double](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0
                    for yy in 0..<factor {
                        for xx in 0..<factor {
                            sum += fullValues[(y * factor + yy) * 6000 + x * factor + xx]
                        }
                    }
                    averaged[y * width + x] = sum / Double(factor * factor)
                }
            }
            let direct = channel(try render(width: width, height: height, grain: grain))
            let referenceSD = standardDeviation(averaged)
            XCTAssertEqual(standardDeviation(direct), referenceSD,
                           accuracy: max(0.0004, referenceSD * 0.32), "factor \(factor)")
            XCTAssertEqual(mean(direct), mean(averaged), accuracy: 0.002, "factor \(factor)")
        }
    }

    func testGrainFieldUsesNormalizedWidthWhenResized() throws {
        let grain = EditState.Grain(amount: 75, size: 100)
        let full = try render(width: 6000, height: 96, grain: grain)
        let reduced = try render(width: 3000, height: 48, grain: grain)
        var averaged = [Double](repeating: 0, count: 3000 * 48)
        for y in 0..<48 {
            for x in 0..<3000 {
                var sum = 0.0
                for yy in 0..<2 {
                    for xx in 0..<2 {
                        sum += Double(full.rgb(x: x * 2 + xx, y: y * 2 + yy).0)
                    }
                }
                averaged[y * 3000 + x] = sum * 0.25
            }
        }

        let resizedCorrelation = correlation(averaged, channel(reduced))
        XCTAssertGreaterThan(resizedCorrelation, 0.98)
    }

    func testGrainFieldDependsOnWidthNotHeight() throws {
        let grain = EditState.Grain(amount: 75, size: 100)
        let short = try render(width: 6000, height: 48, grain: grain)
        let tall = try render(width: 6000, height: 96, grain: grain)

        for y in 0..<short.height {
            for x in 0..<short.width {
                XCTAssertEqual(short.rgb(x: x, y: y).0, tall.rgb(x: x, y: y).0)
            }
        }
    }

    func testSmallAndDefaultGrainAreAttenuatedWhenUnresolvable() throws {
        for size in [0.0, 25.0] {
            let grain = EditState.Grain(amount: 75, size: size)
            let fullSD = standardDeviation(channel(try render(width: 6000, height: 32,
                                                              grain: grain)))
            let reducedSD = standardDeviation(channel(try render(width: 1500, height: 8,
                                                                 grain: grain)))
            XCTAssertLessThan(reducedSD, fullSD * 0.55, "size \(size)")
        }
    }

    func testNearNativeScaleTransitionIsContinuousInStrength() throws {
        let grain = EditState.Grain(amount: 70, size: 100)
        let native = standardDeviation(channel(try render(width: 6000, height: 8,
                                                          grain: grain)))
        for scale in [1.001, 1.02] {
            let width = Int((6000 / scale).rounded())
            let scaled = standardDeviation(channel(try render(width: width, height: 8,
                                                              grain: grain)))
            XCTAssertEqual(scaled, native, accuracy: native * 0.05, "scale \(scale)")
        }
    }

    func testLargeGrainGentlySoftensFineSourceDetail() throws {
        let (context, grainStage) = try stage()
        let width = 6000, height = 8
        let input = try context.makeTexture(width: width, height: height) { x, _ in
            let v: Float = x.isMultiple(of: 2) ? 0.14 : 0.22
            return (v, v, v)
        }
        func projection(size: Double) throws -> Double {
            let output = try context.makeWorkingTexture(width: width, height: height)
            guard let cb = context.commandQueue.makeCommandBuffer() else {
                throw MetalError.encoderFailed
            }
            try grainStage.encode(cb, source: input, destination: output,
                                  grain: .init(amount: 100, size: size), displayWhite: 1)
            cb.commit(); cb.waitUntilCompleted()
            let image = try TextureReadback.read(output)
            var sum = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let sign = x.isMultiple(of: 2) ? -1.0 : 1.0
                    sum += (Double(image.rgb(x: x, y: y).0) - 0.18) * sign
                }
            }
            return sum / Double(width * height)
        }
        XCTAssertLessThan(try projection(size: 100), try projection(size: 25) * 0.9)
    }
}
