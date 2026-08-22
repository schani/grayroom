import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCore

/// Decode → pipeline → encoded file, for a standard image rather than a RAW.
///
/// The RAW end-to-end test proves the chain works for sensor data; this proves
/// the *dispatch* did not leave the non-RAW path connected to nothing.
final class StandardImageEndToEndTests: XCTestCase {
    func testJPEGRendersToAPNG() throws {
        let (ctx, pipeline) = try TestGPU.require()
        let codes = (0..<32).map { UInt8($0 * 8) }
        let input = try SyntheticImage.write(patches: codes, to: "e2e.jpg", type: .jpeg,
                                             height: 16)

        let decoded = try ImageDecoder(metal: ctx).decode(url: input)
        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 16)
        // A standard image has no as-shot illuminant to report; the decode says
        // so rather than inventing one.
        XCTAssertEqual(decoded.asShotTemperature, 6500)
        XCTAssertEqual(decoded.asShotTint, 0)

        var edit = EditState()
        edit.tone.exposure = 0.5
        let output = try pipeline.render(input: decoded.texture, edit: edit)

        let url = SyntheticImage.directory.appendingPathComponent("e2e.png")
        try ImageWriter.write(texture: output.texture, to: url, format: .png16)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let written = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(written.width, 32)
        XCTAssertEqual(written.height, 16)
    }
}
