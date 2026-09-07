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

    /// The neutral style is the pipeline's own rendition, so the colour
    /// treatment runs nothing in the mix slot.
    func testTheNeutralStyleRunsNoMixPass() throws {
        var edit = EditState()
        edit.treatment = .color
        XCTAssertEqual(try stages(edit), [.tone])
    }

    func testAColourStyleFillsTheMixSlot() throws {
        var edit = EditState()
        edit.treatment = .color
        edit.style = .chrome
        XCTAssertEqual(try stages(edit), [.tone, .mix])
    }

    /// `style` is only rendered under the colour treatment: a B&W edit that
    /// carries one renders exactly as it would with `.neutral`, pixel for pixel.
    func testTheStyleIsInertUnderTheBlackAndWhiteTreatment() throws {
        let (ctx, pipe) = try TestGPU.require()
        var styled = EditState()
        styled.style = .chrome
        XCTAssertEqual(try stages(styled), [.tone, .mix])

        let input = try ctx.makePatchTexture([(0.18, 0.18, 0.18), (0.40, 0.02, 0.02),
                                              (0.02, 0.02, 0.40), (0.90, 0.90, 0.90)])
        let a = try TextureReadback.read(
            pipe.render(input: input, edit: EditState(), upTo: .output).texture)
        let b = try TextureReadback.read(
            pipe.render(input: input, edit: styled, upTo: .output).texture)
        XCTAssertEqual(a.pixels, b.pixels)
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

    func testEverythingButTheMixer() throws {
        var edit = EditState()
        edit.treatment = .color
        edit.clarity = 30
        edit.toning.shadowSaturation = 40
        let planned = try stages(edit)
        XCTAssertEqual(planned, [.tone, .clarity, .toning])
        assertInPipelineOrder(planned)
    }
}
