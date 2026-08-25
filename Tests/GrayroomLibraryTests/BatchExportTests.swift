import CoreGraphics
import Foundation
import GrayroomCore
import ImageIO
import XCTest
@testable import GrayroomLibrary

/// Exporting several photos into one folder: what the files are called, which
/// development each one is rendered through, and the loop itself.
final class BatchExportTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp?.tearDown()
        temp = nil
    }

    private func destination(_ name: String = "out") throws -> URL {
        let url = temp.directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func renderer() throws -> Renderer {
        guard let renderer = try? Renderer() else {
            throw XCTSkip("no Metal device / shader compilation failed")
        }
        return renderer
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - Naming

    func testAFreeNameIsUsedAsItIs() {
        XCTAssertEqual(ExportNaming.fileName(stem: "L1000003", extension: "png",
                                             isTaken: { _ in false }),
                       "L1000003.png")
    }

    /// Lightroom's rule: the second file is "-2", never an overwrite.
    func testATakenNameGetsANumberedSuffix() {
        let taken: Set<String> = ["a.png", "a-2.png", "a-3.png"]
        XCTAssertEqual(ExportNaming.fileName(stem: "a", extension: "png",
                                             isTaken: { taken.contains($0) }),
                       "a-4.png")
    }

    func testTheStemKeepsEverythingButTheLastExtension() {
        XCTAssertEqual(ExportNaming.stem(ofFileName: "a.b.DNG"), "a.b")
        XCTAssertEqual(ExportNaming.stem(ofFileName: "no-extension"), "no-extension")
    }

    /// A file already in the folder counts as taken, and so does one this same
    /// batch has just written.
    func testTwoPhotosWithOneNameDoNotOverwriteEachOtherOrWhatIsThere() throws {
        let renderer = try renderer()
        let directory = try destination()
        let a = try temp.writeJPEG("one/frame.jpg", width: 32, height: 24)
        let b = try temp.writeJPEG("two/frame.jpg", width: 40, height: 24)
        try "not an export".write(to: directory.appendingPathComponent("frame.png"),
                                  atomically: true, encoding: .utf8)

        let jobs = [ExportJob(source: a, edit: EditState()),
                    ExportJob(source: b, edit: EditState())]
        let result = BatchExport.run(jobs, to: directory, format: .png, quality: 0.92,
                                     renderer: renderer)

        XCTAssertEqual(result.failures.map(\.stem), [])
        XCTAssertEqual(result.written.map(\.lastPathComponent), ["frame-2.png", "frame-3.png"])
        XCTAssertEqual(try names(in: directory), ["frame-2.png", "frame-3.png", "frame.png"])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("frame.png"),
                                  encoding: .utf8), "not an export")
    }

    // MARK: - Which development

    /// The rule the Library grid draws by: development #1 — the photo's lowest
    /// ordinal — or, with no development at all, the neutral decode.
    func testAJobTakesDevelopmentNumberOne() throws {
        let file = try temp.writeJPEG("frame.jpg", width: 32, height: 24)
        let id = try Importer(library: library, probe: stubProbe()).importFile(at: file).photoID

        var jobs = try BatchExport.jobs(forPhotoIDs: [id], in: library)
        XCTAssertEqual(jobs.map(\.stem), ["frame"])
        XCTAssertEqual(jobs.first?.source?.path, file.path)
        XCTAssertEqual(jobs.first?.edit, EditState(), "an undeveloped photo exports neutral")

        var first = EditState()
        first.tone.exposure = 2
        var second = EditState()
        second.tone.exposure = -2
        try library.addDevelopment(photoID: id, edit: first)
        try library.addDevelopment(photoID: id, edit: second)

        jobs = try BatchExport.jobs(forPhotoIDs: [id], in: library)
        XCTAssertEqual(jobs.first?.edit, first)
    }

    /// …and that is the edit that reaches the file: the same photo exported
    /// before and after a +2 EV development comes out measurably brighter.
    func testTheExportedFileIsRenderedThroughThatDevelopment() throws {
        let renderer = try renderer()
        let file = try temp.writeJPEG("frame.jpg", width: 32, height: 24)
        let id = try Importer(library: library, probe: stubProbe()).importFile(at: file).photoID
        let directory = try destination()

        func export() throws -> URL {
            let jobs = try BatchExport.jobs(forPhotoIDs: [id], in: library)
            let result = BatchExport.run(jobs, to: directory, format: .png, quality: 0.92,
                                         renderer: renderer)
            XCTAssertEqual(result.failures.map(\.message), [])
            return try XCTUnwrap(result.written.first)
        }

        let neutral = try export()
        var brighter = EditState()
        brighter.tone.exposure = 2
        try library.addDevelopment(photoID: id, edit: brighter)
        let developed = try export()

        XCTAssertEqual([neutral, developed].map(\.lastPathComponent),
                       ["frame.png", "frame-2.png"])
        XCTAssertGreaterThan(try meanLuminance(of: developed), try meanLuminance(of: neutral))
    }

    // MARK: - The loop

    func testABatchOfTwoWritesBothAndReportsProgress() throws {
        let renderer = try renderer()
        let directory = try destination()
        let importer = Importer(library: library, probe: stubProbe())
        let a = try importer.importFile(at: temp.writeJPEG("a.jpg", width: 32, height: 24)).photoID
        let b = try importer.importFile(at: temp.writeJPEG("b.jpg", width: 40, height: 30)).photoID

        var reported: [(Int, String)] = []
        let jobs = try BatchExport.jobs(forPhotoIDs: [a, b], in: library)
        let result = BatchExport.run(jobs, to: directory, format: .png, quality: 0.92,
                                     renderer: renderer,
                                     progress: { reported.append(($0, $1)) })

        XCTAssertFalse(result.isCancelled)
        XCTAssertEqual(result.failures.map(\.stem), [])
        XCTAssertEqual(try names(in: directory), ["a.png", "b.png"])
        XCTAssertEqual(reported.map(\.0), [1, 2])
        XCTAssertEqual(reported.map(\.1), ["a.png", "b.png"])

        let sizes = try result.written.map { url -> [Int] in
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return [image.width, image.height]
        }
        XCTAssertEqual(sizes, [[32, 24], [40, 30]], "full resolution, not a preview")
    }

    /// A photo the library has no file for is one failure, not the end of the
    /// batch.
    func testAPhotoWithNoFileFailsAndTheRestAreStillWritten() throws {
        let renderer = try renderer()
        let directory = try destination()
        let jobs = [ExportJob(source: nil, edit: EditState(), stem: "lost"),
                    ExportJob(source: try temp.writeJPEG("a.jpg", width: 32, height: 24),
                              edit: EditState())]

        let result = BatchExport.run(jobs, to: directory, format: .png, quality: 0.92,
                                     renderer: renderer)

        XCTAssertEqual(result.written.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(result.failures.map(\.stem), ["lost"])
        XCTAssertTrue(result.failures[0].message.contains("no file"), result.failures[0].message)
        XCTAssertEqual(try names(in: directory), ["a.png"])
    }

    /// The name a failed job would have used is left free for the next one.
    func testAFailedJobDoesNotClaimItsName() throws {
        let renderer = try renderer()
        let directory = try destination()
        let jobs = [ExportJob(source: nil, edit: EditState(), stem: "a"),
                    ExportJob(source: try temp.writeJPEG("a.jpg", width: 32, height: 24),
                              edit: EditState())]

        let result = BatchExport.run(jobs, to: directory, format: .png, quality: 0.92,
                                     renderer: renderer)

        XCTAssertEqual(result.written.map(\.lastPathComponent), ["a.png"])
    }

    func testCancellationStopsBeforeTheNextFile() throws {
        let renderer = try renderer()
        let directory = try destination()
        var done = 0
        let jobs = try (0..<3).map { i in
            ExportJob(source: try temp.writeJPEG("f\(i).jpg", width: 32, height: 24 + i),
                      edit: EditState())
        }

        let result = BatchExport.run(jobs, to: directory, format: .png, quality: 0.92,
                                     renderer: renderer,
                                     isCancelled: { done >= 1 },
                                     progress: { finished, _ in done = finished })

        XCTAssertTrue(result.isCancelled)
        XCTAssertEqual(result.written.map(\.lastPathComponent), ["f0.png"])
        XCTAssertEqual(try names(in: directory), ["f0.png"])
    }

    private func meanLuminance(of url: URL) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        for i in 0..<(w * h) {
            total += (0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1])
                + 0.0722 * Double(pixels[i * 4 + 2])) / 255
        }
        return total / Double(w * h)
    }
}
