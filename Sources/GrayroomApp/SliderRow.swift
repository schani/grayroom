import SwiftUI

/// One labelled slider, with Lightroom's two habits:
///
/// * the drag is **one** undo step (`onEditingChanged` brackets it), and
/// * double-clicking the label resets that one control to its default.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var defaultValue: Double = 0
    var format: String = "%.0f"
    /// Optional non-linear mapping (the temperature slider is logarithmic).
    var scale: SliderScale = .linear
    var trackGradient: LinearGradient?
    let onBegin: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        onBegin()
                        value = defaultValue
                        onEnd()
                    }
                    .help("Double-click to reset")
                Spacer(minLength: 4)
                Text(String(format: format, value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value == defaultValue ? .secondary : .primary)
            }
            ZStack {
                if let trackGradient {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(trackGradient)
                        .frame(height: 4)
                        .padding(.horizontal, 2)
                }
                Slider(value: scaledBinding, in: scale.mapped(range)) { editing in
                    if editing { onBegin() } else { onEnd() }
                }
                .controlSize(.small)
            }
        }
    }

    private var scaledBinding: Binding<Double> {
        Binding(get: { scale.forward(value) },
                set: { value = scale.inverse($0) })
    }
}

/// How a slider's position maps to its value.
enum SliderScale {
    case linear
    /// Equal travel per octave — what a 2000…50000 K temperature control needs
    /// if the useful daylight range is not to be squashed into the first 10 %.
    case logarithmic

    func forward(_ v: Double) -> Double {
        switch self {
        case .linear: return v
        case .logarithmic: return log(max(v, 1e-6))
        }
    }

    func inverse(_ v: Double) -> Double {
        switch self {
        case .linear: return v
        case .logarithmic: return exp(v)
        }
    }

    func mapped(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        forward(range.lowerBound)...forward(range.upperBound)
    }
}

/// A section header for the sidebar.
struct PanelHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.top, 2)
    }
}
