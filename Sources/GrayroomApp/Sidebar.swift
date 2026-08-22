import GrayroomCore
import GrayroomUI
import SwiftUI

/// Convenience bindings from the sidebar into the `EditStateStore`.
///
/// Every write goes through `store.update`, which is the *live* path: no undo
/// step, one render request. The undo step is registered by the slider's
/// `onEditingChanged` bracket instead, so a 300-event drag is one Cmd-Z.
extension AppModel {
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<EditState, T>) -> Binding<T> {
        Binding(get: { self.store.edit[keyPath: keyPath] },
                set: { newValue in self.store.update { $0[keyPath: keyPath] = newValue } })
    }

    /// A binding into the *selected* mask's adjustments, resolved by mask ID on
    /// every access. Never index-captured: SwiftUI can evaluate a stale binding
    /// after the mask it was built for is gone, and that must be a no-op, not
    /// an out-of-range trap.
    func maskBinding(_ keyPath: WritableKeyPath<MaskAdjustments, Double>) -> Binding<Double> {
        Binding(get: { self.store.maskAdjustment(keyPath) },
                set: { newValue in self.store.setMaskAdjustment(keyPath, to: newValue) })
    }

    func beginEdit() { store.beginGesture() }
    func endEdit(_ name: String) { store.endGesture(named: name) }
}

struct Sidebar: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HistogramView(model: model.histogram,
                              sdrWhiteMarker: model.sdrWhiteMarker)
                Divider()
                WhiteBalancePanel(model: model)
                Divider()
                TonePanel(model: model)
                Divider()
                BWMixPanel(model: model)
                Divider()
                ToningPanel(model: model)
                Divider()
                MasksPanel(model: model)
                if model.tool == .brush {
                    Divider()
                    BrushPanel(model: model)
                }
            }
            .padding(10)
        }
        .frame(width: 320)
        .background(.background)
    }
}

// MARK: - White balance

private struct WhiteBalancePanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "White Balance", trailing: AnyView(
                Button("As Shot") { model.store.resetWhiteBalanceToAsShot() }
                    .controlSize(.mini)
                    .disabled(model.store.isAsShotWhiteBalance)
            ))
            if model.store.isAsShotWhiteBalance {
                Text("As shot — changing either value re-decodes the RAW")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            SliderRow(title: "Temp", value: temperature, range: 2000...50000,
                      defaultValue: model.store.asShotTemperature, format: "%.0f K",
                      scale: .logarithmic,
                      trackGradient: LinearGradient(
                        colors: [.init(red: 0.45, green: 0.62, blue: 1.0),
                                 .white,
                                 .init(red: 1.0, green: 0.78, blue: 0.42)],
                        startPoint: .leading, endPoint: .trailing),
                      onBegin: model.beginEdit,
                      onEnd: { model.endEdit("Temperature") })
            SliderRow(title: "Tint", value: tint, range: -150...150,
                      defaultValue: model.store.asShotTint, format: "%.0f",
                      trackGradient: LinearGradient(
                        colors: [.init(red: 0.35, green: 0.85, blue: 0.35), .white,
                                 .init(red: 0.85, green: 0.4, blue: 0.9)],
                        startPoint: .leading, endPoint: .trailing),
                      onBegin: model.beginEdit,
                      onEnd: { model.endEdit("Tint") })
        }
    }

    /// `nil` in the edit means as-shot; the slider shows the as-shot number and
    /// pins **both** fields as soon as either is touched, so the sidecar is never
    /// half-specified.
    private var temperature: Binding<Double> {
        Binding(get: { model.store.effectiveTemperature },
                set: { v in
                    let tint = model.store.effectiveTint
                    model.store.update {
                        $0.whiteBalance.temperature = v
                        $0.whiteBalance.tint = tint
                    }
                })
    }

    private var tint: Binding<Double> {
        Binding(get: { model.store.effectiveTint },
                set: { v in
                    let temp = model.store.effectiveTemperature
                    model.store.update {
                        $0.whiteBalance.temperature = temp
                        $0.whiteBalance.tint = v
                    }
                })
    }
}

// MARK: - Tone + clarity

private struct TonePanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Tone", trailing: AnyView(
                Toggle("HDR", isOn: Binding(
                    get: { model.store.edit.hdr },
                    set: { v in model.store.perform("HDR") { $0.hdr = v } }))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .help("Roll the highlights off into the display's extended range "
                          + "instead of SDR white. Preview only — export is always SDR.")
            ))
            if model.store.edit.hdr {
                Text("HDR preview — the export clips above the histogram's SDR mark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            SliderRow(title: "Exposure", value: model.binding(\.tone.exposure),
                      range: -5...5, format: "%+.2f EV",
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Exposure") })
            SliderRow(title: "Contrast", value: model.binding(\.tone.contrast),
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Contrast") })
            SliderRow(title: "Highlights", value: model.binding(\.tone.highlights),
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Highlights") })
            SliderRow(title: "Shadows", value: model.binding(\.tone.shadows),
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Shadows") })
            SliderRow(title: "Whites", value: model.binding(\.tone.whites),
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Whites") })
            SliderRow(title: "Blacks", value: model.binding(\.tone.blacks),
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Blacks") })
            PanelHeader(title: "Presence")
            // Global clarity is positive-only; per-mask deltas keep the full
            // ±100 range (a mask may reduce clarity below the global value).
            SliderRow(title: "Clarity", value: model.binding(\.clarity),
                      range: 0...100,
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Clarity") })
        }
    }
}

// MARK: - B&W mix

private struct BWMixPanel: View {
    let model: AppModel

    /// Approximate on-screen colours for the eight band centres, so the panel
    /// reads at a glance. Purely decorative.
    private static let swatches: [Color] = BWMixBands.centers.map {
        Color(hue: $0 / 360, saturation: 0.85, brightness: 0.95)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "B&W Mix", trailing: AnyView(
                Toggle("B&W", isOn: Binding(
                    get: { model.store.edit.bwMix.enabled },
                    set: { v in model.store.perform(v ? "Enable B&W" : "Disable B&W") {
                        $0.bwMix.enabled = v
                    } }))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
            ))
            if !model.store.edit.bwMix.enabled {
                Text("Colour passthrough — the mixer and the targeted tool do nothing")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(BWMixBands.names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 6) {
                    Circle()
                        .fill(BWMixPanel.swatches[index])
                        .frame(width: 8, height: 8)
                    SliderRow(title: name,
                              value: model.binding(\.bwMix[band: index]),
                              onBegin: model.beginEdit,
                              onEnd: { model.endEdit("\(name) Mix") })
                }
            }
        }
    }
}

// MARK: - Toning

private struct ToningPanel: View {
    let model: AppModel

    private static let hueTrack = LinearGradient(
        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            Color(hue: $0, saturation: 0.9, brightness: 0.95)
        },
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Toning")
            Text("Shadows").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            SliderRow(title: "Hue", value: model.binding(\.toning.shadowHue),
                      range: 0...360, format: "%.0f°", trackGradient: ToningPanel.hueTrack,
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Shadow Hue") })
            SliderRow(title: "Saturation", value: model.binding(\.toning.shadowSaturation),
                      range: 0...100,
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Shadow Saturation") })
            Text("Highlights").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            SliderRow(title: "Hue", value: model.binding(\.toning.highlightHue),
                      range: 0...360, format: "%.0f°", trackGradient: ToningPanel.hueTrack,
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Highlight Hue") })
            SliderRow(title: "Saturation", value: model.binding(\.toning.highlightSaturation),
                      range: 0...100,
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Highlight Saturation") })
            SliderRow(title: "Balance", value: model.binding(\.toning.balance),
                      onBegin: model.beginEdit, onEnd: { model.endEdit("Toning Balance") })
        }
    }
}

// MARK: - Masks

private struct MasksPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Masks", trailing: AnyView(
                Button("+ New Mask") {
                    model.store.addMask()
                    model.tool = .brush
                }
                .controlSize(.mini)
            ))

            if model.store.edit.masks.isEmpty {
                Text("No masks. Add one, then paint with the brush (B).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            ForEach(model.store.edit.masks) { mask in
                MaskRow(model: model, mask: mask)
            }

            if let selected = model.store.selectedMask {
                Divider()
                Toggle("Show overlay", isOn: Binding(get: { model.showMaskOverlay },
                                                     set: { model.showMaskOverlay = $0 }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                SliderRow(title: "Exposure",
                          value: model.maskBinding(\.exposure),
                          range: -4...4, format: "%+.2f EV",
                          onBegin: model.beginEdit, onEnd: { model.endEdit("Mask Exposure") })
                SliderRow(title: "Contrast",
                          value: model.maskBinding(\.contrast),
                          onBegin: model.beginEdit, onEnd: { model.endEdit("Mask Contrast") })
                SliderRow(title: "Highlights",
                          value: model.maskBinding(\.highlights),
                          onBegin: model.beginEdit, onEnd: { model.endEdit("Mask Highlights") })
                SliderRow(title: "Shadows",
                          value: model.maskBinding(\.shadows),
                          onBegin: model.beginEdit, onEnd: { model.endEdit("Mask Shadows") })
                SliderRow(title: "Clarity",
                          value: model.maskBinding(\.clarity),
                          onBegin: model.beginEdit, onEnd: { model.endEdit("Mask Clarity") })
                Text("\(selected.strokes.count) stroke(s)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MaskRow: View {
    let model: AppModel
    let mask: Mask

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { mask.enabled },
                                     set: { model.store.setMaskEnabled(id: mask.id, $0) }))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .labelsHidden()
            Text(mask.name)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Button {
                model.store.deleteMask(id: mask.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(model.store.selectedMaskID == mask.id
                    ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture {
            model.store.selectedMaskID = mask.id
            model.tool = .brush
        }
    }
}

// MARK: - Brush

private struct BrushPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Brush", trailing: AnyView(
                Toggle("Eraser", isOn: Binding(get: { model.eraserActive },
                                               set: { model.eraserActive = $0 }))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
            ))
            SliderRow(title: "Size", value: sizeBinding,
                      range: BrushSizing.sizeRange.lowerBound...BrushSizing.sizeRange.upperBound,
                      defaultValue: 0.05, format: "%.3f",
                      onBegin: {}, onEnd: {})
            Text(String(format: "%.0f px at full resolution", model.brushDiameterPixels))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            SliderRow(title: "Feather", value: brushBinding(\.feather), range: 0...100,
                      defaultValue: 50, onBegin: {}, onEnd: {})
            SliderRow(title: "Flow", value: brushBinding(\.flow), range: 0...100,
                      defaultValue: 100, onBegin: {}, onEnd: {})
            SliderRow(title: "Density", value: brushBinding(\.density), range: 0...100,
                      defaultValue: 100, onBegin: {}, onEnd: {})
            Text("[ ] size · shift-[ ] feather · E eraser · option-drag erases")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { model.store.brush.size },
                set: { v in model.updateBrush { $0.size = v } })
    }

    private func brushBinding(_ keyPath: WritableKeyPath<BrushParams, Double>) -> Binding<Double> {
        Binding(get: { model.store.brush[keyPath: keyPath] },
                set: { v in model.updateBrush { $0[keyPath: keyPath] = v } })
    }
}
