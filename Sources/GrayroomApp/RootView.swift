import GrayroomCanvas
import GrayroomCore
import GrayroomLibrary
import SwiftUI

/// The window, in either of the app's two modules.
///
/// **Library** (`g`) is the grid, full width — there is no develop sidebar
/// because none of it applies to a selection of photos. **Develop** (`d`) is
/// the canvas left/centre with a fixed 320 pt scrollable sidebar right. Both
/// keep the toolbar on top and the one-line status bar at the bottom, so the
/// activity indicator and the error line never move.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(model: model)
            Divider()
            switch model.mode {
            case .library:
                LibraryView(model: model)
            case .develop:
                develop
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

    private var develop: some View {
        HStack(spacing: 0) {
            ZStack {
                CanvasView(model: model)
                if model.imageURL == nil {
                    VStack(spacing: 8) {
                        Text("Grayroom").font(.largeTitle)
                        Text("Open a RAW file (⌘O), or the library (G)")
                            .foregroundStyle(.secondary)
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
    }
}

private struct Toolbar: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            // Lightroom's spot for it: top-left, in the identity plate. Draws
            // nothing at all when there is no background work.
            ActivityIndicator(tasks: model.tasks)

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a RAW file (⌘O)")

            Button {
                guard let url = ImportModel.presentSourcePanel() else { return }
                model.importModel.setSource(url)
                openWindow(id: "import")
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Add a folder of photos to the library (⇧⌘I)")

            Divider().frame(height: 16)

            Picker("", selection: Binding(get: { model.mode }, set: {
                $0 == .library ? model.showLibrary() : model.showDevelop()
            })) {
                Text("Library").tag(AppModel.Mode.library)
                Text("Develop").tag(AppModel.Mode.develop)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("Library (G) · Develop (D)")

            // Everything past here edits one image, so it is only up in the
            // develop view. Hidden rather than disabled: a greyed-out brush
            // next to a grid of photos is noise, not information.
            if model.mode == .develop {
                developTools
            }

            Spacer()

            if model.isRendering || model.isDecoding {
                ProgressView().controlSize(.small)
            }
            Button {
                model.presentExportSheet()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.imageURL == nil || model.mode == .library)
            .help("Export at full resolution (⌘E)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var developTools: some View {
        Group {
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
        }
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
            // The colour label of the photo on the canvas. The grid shows this
            // by tinting the whole cell; here there is only one photo, so it is
            // a dot — and without it, 6/7/8/9 in the develop view would be a
            // keystroke with no visible effect at all.
            if model.currentColorLabel != .unlabeled {
                Circle()
                    .fill(LibraryCell.swatch(model.currentColorLabel))
                    .frame(width: 8, height: 8)
                    .help("Colour label: \(model.currentColorLabel.name)")
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
