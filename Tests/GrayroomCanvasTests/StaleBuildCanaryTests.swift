import Foundation
import XCTest

/// A canary for the failure mode that made a *correct* fix look broken: a build
/// in which `swift build` reports success, object files called `<Name>.o` appear
/// in the **package root** instead of `<Name>.swift.o` in
/// `.build/<triple>/debug/<Target>.build/`, and the linked executable silently
/// keeps the previous code.
///
/// It happened twice in this repo (2026-08-05 23:28, when the canvas coordinate
/// fix was compiled but never linked, and again on 08-06 07:31). Both times the
/// only visible symptom was "the bug you just fixed is still there". The stray
/// objects are the fingerprint, so fail loudly on them rather than let the next
/// person debug a binary that does not match the source.
///
/// If this fires: `rm -rf .build; rm -f ./*.o ./*.d ./*.swiftdeps*; swift build`.
final class StaleBuildCanaryTests: XCTestCase {
    func testNoStrayObjectFilesInThePackageRoot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GrayroomCanvasTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let stray = names.filter {
            $0.hasSuffix(".o") || $0.hasSuffix(".d")
                || $0.hasSuffix(".swiftdeps") || $0.hasSuffix(".swiftdeps~")
        }.sorted()
        XCTAssertTrue(stray.isEmpty,
                      "SwiftPM dropped compiler outputs into \(root.path): \(stray). "
                      + "The linked binaries may not match the sources — "
                      + "`rm -rf .build; rm -f ./*.o ./*.d ./*.swiftdeps*; swift build` before trusting a test run.")
    }
}
