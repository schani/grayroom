import CoreGraphics
import Foundation

/// What the interactive loop should render next.
public enum PreviewRenderStep: Equatable, Sendable {
    /// Render the pending edit reduced to this long edge, without a histogram,
    /// and push it to the canvas.
    case draft(longEdge: Int)
    /// Render at the decode's own resolution, with the histogram.
    case full
    /// Nothing to do.
    case idle
}

/// The draft-then-refine policy of the interactive preview.
///
/// The app decodes at full resolution — the canvas above 100 % shows the file's
/// own pixels, not a magnified proxy — but the full pipeline at 24 MP costs
/// ~26 ms without clarity and ~120 ms with it, and 120 ms is well past the point
/// where a slider drag stops feeling attached to the mouse. So an expensive edit
/// renders twice: a reduced **draft** that keeps the drag responsive, then, as
/// soon as the drag pauses, a **refine** of the same edit at full resolution.
///
/// The refine is what the histogram, the mask overlay and the eye finally see;
/// the draft only ever exists between two frames of a gesture.
public enum PreviewStrategy {
    /// Long edge of a draft render. ~3 MP at 3:2, a few ms of pipeline.
    public static let draftLongEdge = 2560

    /// Above this many pixels even a clarity-free full pipeline is too slow to
    /// drag against (a 100 MP frame runs ~90 ms), so those images draft too.
    public static let directRenderPixelLimit = 30_000_000

    /// The long edge a draft of `fullSize` should render at, or `nil` when the
    /// edit is cheap enough to go straight to full resolution.
    ///
    /// `clarityActive` is `EditState.clarityActive` — the same predicate the
    /// pipeline uses to decide whether to run the clarity stage at all.
    public static func draftLongEdge(fullSize: CGSize, clarityActive: Bool) -> Int? {
        let w = Int(fullSize.width.rounded()), h = Int(fullSize.height.rounded())
        guard w > 0, h > 0 else { return nil }
        // Nothing to reduce: the frame is already at or below the draft edge.
        guard max(w, h) > draftLongEdge else { return nil }
        guard clarityActive || w * h > directRenderPixelLimit else { return nil }
        return draftLongEdge
    }

    /// The render loop's decision, as a pure function of its three inputs.
    ///
    /// A newer edit always wins: it drafts (or renders directly, when the edit
    /// is cheap). Only once nothing is pending does an outstanding draft get
    /// refined — which is why a fast drag never pays for a refine it would have
    /// thrown away.
    public static func nextStep(hasPendingEdit: Bool,
                                lastRenderWasDraft: Bool,
                                draftLongEdge: Int?) -> PreviewRenderStep {
        if hasPendingEdit {
            if let edge = draftLongEdge { return .draft(longEdge: edge) }
            return .full
        }
        return lastRenderWasDraft ? .full : .idle
    }
}
