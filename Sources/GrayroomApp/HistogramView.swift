import GrayroomUI
import SwiftUI

/// 256-bin luminance histogram of the current output, with Lightroom's clipping
/// triangles. The bins come straight from the pipeline's histogram tap — the GPU
/// already counted them while rendering the frame, so this costs one `Path`.
struct HistogramView: View {
    let model: HistogramModel
    /// Normalised x of the SDR-white marker, or `nil` in SDR. See
    /// `HistogramModel.sdrWhiteMarkerPosition`.
    var sdrWhiteMarker: Double?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ClipTriangle(pointsLeft: true, lit: model.shadowClipping)
                    .help(String(format: "Shadow clipping: %.2f%%",
                                 model.shadowClippedFraction * 100))
                Spacer()
                ClipTriangle(pointsLeft: false, lit: model.highlightClipping)
                    .help(String(format: "Highlight clipping: %.2f%%",
                                 model.highlightClippedFraction * 100))
            }
            Canvas { context, size in
                let w = size.width, h = size.height
                // Zone grid at quarter stops of the display range.
                var grid = Path()
                for i in 1..<4 {
                    let x = w * Double(i) / 4
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: h))
                }
                context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

                guard model.heights.count == 256 else { return }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: h))
                for (i, v) in model.heights.enumerated() {
                    let x = w * Double(i) / 255
                    path.addLine(to: CGPoint(x: x, y: h - v * h))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
                context.fill(path, with: .color(.white.opacity(0.75)))

                // In HDR the axis runs to the EDR ceiling, so mark where SDR
                // white is: everything to its right is headroom an SDR export
                // would clip.
                if let marker = sdrWhiteMarker {
                    var line = Path()
                    let x = w * marker
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: h))
                    context.stroke(line, with: .color(.orange.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .frame(height: 90)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

private struct ClipTriangle: View {
    let pointsLeft: Bool
    let lit: Bool

    var body: some View {
        Path { p in
            if pointsLeft {
                p.move(to: CGPoint(x: 0, y: 5))
                p.addLine(to: CGPoint(x: 9, y: 0))
                p.addLine(to: CGPoint(x: 9, y: 10))
            } else {
                p.move(to: CGPoint(x: 9, y: 5))
                p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 10))
            }
            p.closeSubpath()
        }
        .fill(lit ? (pointsLeft ? Color.blue : Color.red) : Color.secondary.opacity(0.3))
        .frame(width: 9, height: 10)
    }
}
