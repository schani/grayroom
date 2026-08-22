import GrayroomCanvas
import GrayroomCore
import SwiftUI

/// Window layout: canvas left/centre, a fixed 320 pt scrollable sidebar right, a
/// thin toolbar on top and a one-line status bar at the bottom.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(model: model)
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    CanvasView(model: model)
                    if model.imageURL == nil {
                        VStack(spacing: 8) {
                            Text("Grayroom").font(.largeTitle)
                            Text("Open a RAW file (⌘O)").foregroundStyle(.secondary)
                        }
                    }
                    if model.isDecoding || model.isExporting {
                        ProgressView()
                            .controlSize(.large)
                            .padding(14)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Sidebar(model: model)
            }
            Divider()
            StatusBar(model: model)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .navigationTitle(model.windowTitle)
        .sheet(isPresented: $model.isExportSheetPresented) {
            ExportSheet(model: model)
        }
    }
}

private struct Toolbar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a RAW file (⌘O)")

            Divider().frame(height: 16)

            Picker("", selection: Binding(get: { model.tool }, set: { model.tool = $0 })) {
                Image(systemName: "hand.raised").tag(CanvasTool.pan)
                Image(systemName: "paintbrush").tag(CanvasTool.brush)
                Image(systemName: "target").tag(CanvasTool.targeted)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .help("Pan · Brush (B) · Targeted B&W adjustment (T)")

            Toggle(isOn: Binding(get: { model.showBeforeAfter },
                                 set: { model.showBeforeAfter = $0 })) {
                Label("Before", systemImage: "rectangle.righthalf.inset.filled")
            }
            .toggleStyle(.button)
            .help("Show the unedited decode (or hold \\)")

            Divider().frame(height: 16)

            Button("Fit") { model.zoomToFit() }.help("Zoom to fit (0)")
            Button("1:1") { model.zoomToActualSize() }.help("Zoom to 100 % (1)")
            Text(String(format: "%.0f%%", model.zoomPercent))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Spacer()

            if model.isRendering || model.isDecoding {
                ProgressView().controlSize(.small)
            }
            Button {
                model.presentExportSheet()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.imageURL == nil)
            .help("Export at full resolution (⌘E)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.imageURL?.lastPathComponent ?? "No image")
                .font(.system(size: 11, weight: .medium))
            if model.previewSize != .zero {
                Text(String(format: "%.0f×%.0f",
                            model.previewSize.width, model.previewSize.height))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !model.cameraDescription.isEmpty {
                Text(model.cameraDescription).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let error = model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            } else if let status = model.statusMessage {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.lastRenderMilliseconds > 0 {
                Text(String(format: "%.1f ms", model.lastRenderMilliseconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Circle()
                .fill(model.store.isDirty ? Color.orange : Color.green.opacity(0.6))
                .frame(width: 7, height: 7)
                .help(model.store.isDirty ? "Unsaved changes" : "Saved to the library")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct ExportSheet: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.headline)
            Text("Renders the full pipeline at full resolution from a fresh decode.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("Format", selection: Binding(get: { model.exportFormat },
                                                set: { model.exportFormat = $0 })) {
                Text("PNG (8-bit)").tag(ExportFormat.png)
                Text("PNG (16-bit)").tag(ExportFormat.png16)
                Text("JPEG").tag(ExportFormat.jpeg)
                Text("TIFF (16-bit)").tag(ExportFormat.tiff16)
            }
            .frame(width: 260)
            if model.exportFormat == .jpeg {
                HStack {
                    Text("Quality").font(.system(size: 11))
                    Slider(value: Binding(get: { model.exportQuality },
                                          set: { model.exportQuality = $0 }), in: 0.1...1)
                    Text(String(format: "%.2f", model.exportQuality))
                        .font(.system(size: 11, design: .monospaced))
                }
                .frame(width: 260)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.isExportSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose File…") { model.runExport() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
