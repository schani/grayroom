import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomLibrary
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCLI

/// `render`, `mask-preview` and `probe` run end to end over a real (synthetic)
/// image file, so the whole decode → pipeline → ImageIO path is exercised the
/// way a user would.
final class RenderCommandTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }
    private var input: URL!

    override func setUpWithError() throws {
        try requireRenderer()
        temp = try TempLibrary()
        input = try temp.writeImage("frame.jpg", width: 64, height: 48)
    }

    override func tearDown() {
        temp?.tearDown()
        temp = nil
        input = nil
    }

    private func out(_ name: String) -> URL {
        temp.directory.appendingPathComponent(name)
    }

    /// (width, height, bits per component, colour space name) of a written file.
    private func describeImage(_ url: URL) throws -> (Int, Int, Int, String?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height, image.bitsPerComponent,
                image.colorSpace?.name as String?)
    }

    // MARK: - render, happy path

    func testRenderWritesAPNGAndReportsWhatItDid() throws {
        let output = out("o.png")
        let result = try temp.run(["render", input.path, "-o", output.path])

        let (w, h, bits, space) = try describeImage(output)
        XCTAssertEqual([w, h], [64, 48])
        XCTAssertEqual(bits, 8)
        XCTAssertEqual(space, CGColorSpace.sRGB as String)

        XCTAssertTrue(result.stderr.contains("edit source: defaults"), result.stderr)
        XCTAssertTrue(result.stderr.contains("wrote \(output.path) (64x48, png)"), result.stderr)
        XCTAssertTrue(result.stderr.contains("white balance: 6500 K / tint 0.00"), result.stderr)
    }

    /// Every format writes the bit depth and file type it promises, and all of
    /// them are tagged sRGB.
    func testEveryExportFormatWritesItsOwnBitDepthAndType() throws {
        let expected: [(ExportFormat, Int, UTType)] = [
            (.png, 8, .png), (.png16, 16, .png), (.jpeg, 8, .jpeg), (.tiff16, 16, .tiff),
        ]
        for (format, bits, type) in expected {
            let output = out("o-\(format.rawValue).\(format.fileExtension)")
            try temp.run(["render", input.path, "-o", output.path,
                          "--format", format.rawValue])

            let (_, _, actualBits, space) = try describeImage(output)
            XCTAssertEqual(actualBits, bits, "\(format.rawValue)")
            XCTAssertEqual(space, CGColorSpace.sRGB as String, "\(format.rawValue)")

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, type.identifier,
                           "\(format.rawValue)")
        }
    }

    func testMaxDimensionCapsTheLongEdgeAndTheParentDirectoryIsCreated() throws {
        let output = out("deep/nested/o.png")
        try temp.run(["render", input.path, "-o", output.path, "--max-dimension", "32"])
        let (w, h, _, _) = try describeImage(output)
        XCTAssertEqual(max(w, h), 32)
        XCTAssertEqual([w, h], [32, 24], "the aspect ratio is kept")
    }

    /// `--set` reaches the pipeline, not just the JSON: +2 EV is a visibly
    /// brighter file.
    func testSetOverridesChangeTheRenderedPixels() throws {
        let dark = out("dark.png")
        let bright = out("bright.png")
        try temp.run(["render", input.path, "-o", dark.path])
        try temp.run(["render", input.path, "-o", bright.path, "--set", "tone.exposure=2"])

        XCTAssertGreaterThan(try meanCode(bright), try meanCode(dark) + 10)
    }

    func testHistogramIsPrintedOnlyWhenAsked() throws {
        let quiet = try temp.run(["render", input.path, "-o", out("a.png").path])
        XCTAssertFalse(quiet.stderr.contains("pixels="), quiet.stderr)

        let loud = try temp.run(["render", input.path, "-o", out("b.png").path, "--histogram"])
        XCTAssertTrue(loud.stderr.contains("pixels=\(64 * 48)"), loud.stderr)
        XCTAssertTrue(loud.stderr.contains("highlightClipped="), loud.stderr)
        XCTAssertTrue(loud.stderr.contains("+----"), "the ascii plot: \(loud.stderr)")
    }

    func testSaveEditWritesTheEffectiveEditToDisk() throws {
        let editPath = out("effective.json")
        try temp.run(["render", input.path, "-o", out("o.png").path,
                      "--set", "clarity=33", "--save-edit", editPath.path])

        let saved = try EditState.load(from: editPath)
        XCTAssertEqual(saved.clarity, 33)
    }

    // MARK: - render --save

    func testSaveWritesTheEffectiveEditBackToTheLibrary() throws {
        let photoID = try temp.importFile(input)
        let result = try temp.run(["render", input.path, "-o", out("o.png").path,
                                   "--set", "tone.exposure=0.75", "--save"])

        let developments = try library.developments(for: photoID)
        XCTAssertEqual(developments.map(\.ordinal), [1])
        XCTAssertEqual(developments[0].edit.tone.exposure, 0.75)
        XCTAssertTrue(result.stderr.contains("saved to photo \(photoID) development #1"),
                      result.stderr)
    }

    /// `--save` on a file the library has never seen imports it first, so the
    /// edit always has somewhere to go.
    func testSaveImportsAFileTheLibraryHasNeverSeen() throws {
        XCTAssertEqual(try library.photos().count, 0)
        try temp.run(["render", input.path, "-o", out("o.png").path,
                      "--set", "tone.exposure=0.5", "--save"])

        let photo = try XCTUnwrap(library.photos().first)
        XCTAssertEqual(try library.developments(for: try XCTUnwrap(photo.id))
            .map(\.edit.tone.exposure), [0.5])
    }

    func testTheLibraryDevelopmentIsTheDefaultEditSource() throws {
        let photoID = try temp.importFile(input)
        try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1.25))

        let result = try temp.run(["render", input.path, "-o", out("o.png").path])
        XCTAssertTrue(result.stderr.contains("library development #1"), result.stderr)
    }

    func testAnEditFileBeatsTheLibraryDevelopment() throws {
        let photoID = try temp.importFile(input)
        try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1.25))
        let editFile = out("edit.json")
        try distinctiveEdit(exposure: -1).save(to: editFile)

        let result = try temp.run(["render", input.path, "-o", out("o.png").path,
                                   "--edit", editFile.path])
        XCTAssertTrue(result.stderr.contains("edit source: \(editFile.path)"), result.stderr)
    }

    // MARK: - render failures

    func testRenderOfAMissingInputFails() {
        temp.assertFails(["render", "/nope/missing.dng", "-o", out("o.png").path],
                           contains: "input file not found")
    }

    func testRenderOfAnUndecodableFileFails() throws {
        let garbage = try temp.writeFile("garbage.jpg", Data(repeating: 0x33, count: 512))
        XCTAssertThrowsError(try temp.run(["render", garbage.path, "-o", out("o.png").path]))
    }

    func testAnExplicitDevelopmentThatDoesNotExistFails() throws {
        try temp.importFile(input)
        temp.assertFails(["render", input.path, "-o", out("o.png").path,
                            "--development", "3"],
                           contains: "has no development #3")
    }

    func testAMissingEditFileFails() {
        temp.assertFails(["render", input.path, "-o", out("o.png").path,
                            "--edit", "/nope/edit.json"],
                           contains: "edit file not found")
    }

    func testABadSetKeyFails() {
        temp.assertFails(["render", input.path, "-o", out("o.png").path,
                            "--set", "tone.nope=1"],
                           contains: "unknown edit key")
    }

    func testOutOfRangeOptionsAreRejectedAtParseTime() {
        for args in [["render", "a.dng", "-o", "o.png", "--max-dimension", "8"],
                     ["render", "a.dng", "-o", "o.png", "--quality", "1.5"],
                     ["render", "a.dng", "-o", "o.png", "--quality", "-0.1"],
                     ["render", "a.dng", "-o", "o.png", "--development", "0"],
                     ["mask-preview", "a.dng", "-o", "m.png", "--max-dimension", "8"],
                     ["mask-preview", "a.dng", "-o", "m.png", "--mask", "-1"]] {
            XCTAssertThrowsError(try Grayroom.parseAsRoot(args), "\(args)")
        }
    }

    // MARK: - mask-preview

    func testMaskPreviewWritesGrayscaleCoverage() throws {
        let editFile = out("masked.json")
        try maskedEdit().save(to: editFile)
        let output = out("mask.png")

        let result = try temp.run(["mask-preview", input.path, "-o", output.path,
                                   "--edit", editFile.path])

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [64, 48])
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 8, "one channel, not RGB")

        XCTAssertTrue(result.stderr.contains("(64x48, grayscale)"), result.stderr)
        XCTAssertTrue(result.stderr.contains("masks: 1 (1 enabled)"), result.stderr)

        // The stroke sits in the top-left quadrant, so that is where the
        // coverage is and the far corner is untouched.
        let gray = try grayPixels(output, width: 64, height: 48)
        XCTAssertGreaterThan(gray[6 * 64 + 6], 200)
        XCTAssertEqual(gray[44 * 64 + 60], 0)
    }

    /// With no masks the coverage is all zero — and the mean the command
    /// reports says so.
    func testMaskPreviewOfAnEditWithNoMasksIsEmptyCoverage() throws {
        let output = out("mask.png")
        let result = try temp.run(["mask-preview", input.path, "-o", output.path])

        XCTAssertTrue(result.stderr.contains("masks: 0 (0 enabled)"), result.stderr)
        XCTAssertTrue(result.stderr.contains("mean coverage 0.0000"), result.stderr)
        XCTAssertEqual(try grayPixels(output, width: 64, height: 48).max(), 0)
    }

    func testMaskPreviewIndexOutOfRangeFails() throws {
        let editFile = out("masked.json")
        try maskedEdit().save(to: editFile)
        temp.assertFails(["mask-preview", input.path, "-o", out("m.png").path,
                            "--edit", editFile.path, "--mask", "4"],
                           contains: "--mask 4 but the edit has 1 mask(s)")
    }

    func testMaskPreviewOfAMissingInputFails() {
        temp.assertFails(["mask-preview", "/nope/missing.dng", "-o", out("m.png").path],
                           contains: "input file not found")
    }

    // MARK: - probe

    func testProbeOfAStandardImageReportsNotRAW() throws {
        let out = try runGrayroom(["probe", input.path]).stdout
        XCTAssertTrue(out.contains("raw:                  no"), out)
        XCTAssertTrue(out.contains("nativeSize:           64 x 48"), out)
        XCTAssertTrue(out.contains("orientedSize:         64 x 48"), out)
        XCTAssertTrue(out.contains("orientation:          1 (up)"), out)
        XCTAssertTrue(out.contains("asShotTemperature:    6500.0 K"), out)
        XCTAssertTrue(out.contains("decoderVersion:       ImageIO"), out)
        XCTAssertTrue(out.contains("lensCorrection:       unsupported"), out)
    }

    func testProbeOfARealRAWReportsRAWAndItsCamera() throws {
        guard let dng = testDataURL("L1000003.DNG") else {
            throw XCTSkip("no test DNG available")
        }
        let out = try runGrayroom(["probe", dng.path]).stdout
        XCTAssertTrue(out.contains("raw:                  yes"), out)
        XCTAssertTrue(out.contains("make:"), out)
        XCTAssertTrue(out.contains("model:"), out)
        // A RAW picks a decoder version and lists the alternatives; a rendered
        // image reports "ImageIO" and no list at all.
        XCTAssertFalse(out.contains("decoderVersion:       ImageIO"), out)
        XCTAssertFalse(out.contains("supportedDecoders:    \n"), out)
        // This frame is shot portrait, so the oriented size is the transpose of
        // the sensor's.
        let native = try XCTUnwrap(field(out, "nativeSize"))
        let oriented = try XCTUnwrap(field(out, "orientedSize"))
        XCTAssertEqual(oriented, native.split(separator: " ").reversed().joined(separator: " "))
    }

    func testProbeOfAMissingFileFails() {
        XCTAssertThrowsError(try runGrayroom(["probe", "/nope/missing.dng"]))
    }

    // MARK: - Helpers

    /// The value of one `probe` line, by its label.
    private func field(_ output: String, _ label: String) -> String? {
        output.split(separator: "\n")
            .first { $0.hasPrefix(label + ":") }
            .map { String($0.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    private func maskedEdit() -> EditState {
        var edit = EditState()
        edit.masks = [Mask(name: "A",
                           adjustments: MaskAdjustments(exposure: 1),
                           strokes: [Stroke(brush: BrushParams(size: 0.25, feather: 20),
                                            polyline: [(0.1, 0.1), (0.15, 0.15)])])]
        return edit
    }

    /// The mean 8-bit code of a written RGB file.
    private func meanCode(_ url: URL) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var acc = 0.0
        for i in 0..<(w * h) { acc += Double(bytes[i * 4]) }
        return acc / Double(w * h)
    }

    /// The single-channel codes of a grayscale PNG, row-major from the top.
    private func grayPixels(_ url: URL, width: Int, height: Int) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
