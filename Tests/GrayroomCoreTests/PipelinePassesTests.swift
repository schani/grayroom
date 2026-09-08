import Metal
import XCTest
@testable import GrayroomCore

/// What `Pipeline.passes(for:)` plans for an edit: order, and which stages are
/// left out because they would be the identity.
final class PipelinePassesTests: XCTestCase {

    private func stages(_ edit: EditState) throws -> [Pipeline.Stage] {
        let (_, pipe) = try TestGPU.require()
        return pipe.passes(for: edit, maps: nil, width: 64, height: 64).map(\.stage)
    }

    private func assertInPipelineOrder(_ stages: [Pipeline.Stage],
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(stages, stages.sorted { $0.rawValue < $1.rawValue }, file: file, line: line)
    }

    func testDefaultEditIsToneAndMix() throws {
        XCTAssertEqual(try stages(EditState()), [.tone, .mix])
    }

    func testMixDisabledLeavesToneAlone() throws {
        var edit = EditState()
        edit.bwMix.enabled = false
        XCTAssertEqual(try stages(edit), [.tone])
    }

    func testClarityAddsItsPassBeforeTheMixer() throws {
        var edit = EditState()
        edit.clarity = 30
        let planned = try stages(edit)
        XCTAssertEqual(planned, [.tone, .clarity, .mix])
        assertInPipelineOrder(planned)
    }

    func testToningAddsItsPassAfterTheMixer() throws {
        var edit = EditState()
        edit.toning.shadowSaturation = 40
        let planned = try stages(edit)
        XCTAssertEqual(planned, [.tone, .mix, .toning])
        assertInPipelineOrder(planned)
    }

    func testGrainAddsItsPassAfterToning() throws {
        var edit = EditState()
        edit.toning.shadowSaturation = 40
        edit.grain.amount = 35
        let planned = try stages(edit)
        XCTAssertEqual(planned, [.tone, .mix, .toning, .grain])
        assertInPipelineOrder(planned)
    }

    func testEverythingButTheMixer() throws {
        var edit = EditState()
        edit.bwMix.enabled = false
        edit.clarity = 30
        edit.toning.shadowSaturation = 40
        let planned = try stages(edit)
        XCTAssertEqual(planned, [.tone, .clarity, .toning])
        assertInPipelineOrder(planned)
    }
}
