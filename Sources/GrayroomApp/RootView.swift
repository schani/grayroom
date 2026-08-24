import GrayroomCanvas
import GrayroomCore
import GrayroomLibrary
import SwiftUI

/// The window, in either of the app's two modules.
///
/// **Library** (`g`) is the Folders panel left and the grid right — there is no
/// develop sidebar because none of it applies to a selection of photos — or, on
/// `e`, the loupe with the whole window to itself, panel collapsed.
/// **Develop** (`d`) is the canvas left/centre with a fixed 320 pt scrollable
/// sidebar right. Both hang their controls in the window's own title bar and
/// keep the one-line status bar at the bottom, so the activity indicator and
/// the error line never move.
///
/// # Why the Library is never taken out of the window
///
/// The two modules are a `ZStack` and not a `switch`, with the Library merely
/// made invisible while Develop is frontmost. The grid is an `NSScrollView`,
/// and a scroll view that is torn down and rebuilt starts at the top: `g` from
/// Develop would paint at least one frame of the grid scrolled to zero before
/// anything could put it back, whatever the something was. Keeping the view
/// mounted means the clip view is the *same object* with the *same* offset when
/// the grid comes back — there is nothing to save and nothing to restore.
///
/// Develop stays conditional, so its canvas really does leave the window (the
/// self-test asserts exactly that, by walking the view tree), and its textures
/// go with it.
struct RootView: View {
    @Bindable var model: AppModel
    /// Held here rather than in the toolbar builder: `ToolbarContent` is not a
    /// `View` and has no environment to read `openWindow` out of.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LibraryView(model: model)
                    .opacity(model.mode == .library ? 1 : 0)
                    // Nothing behind Develop may take a click: the grid's cells
                    // are `ClickCatcher` views, and one of those under the
                    // canvas would select a photo when the user meant to paint.
                    .allowsHitTesting(model.mode == .library)
                    .accessibilityHidden(model.mode != .library)
                if model.mode == .develop {
                    develop
                }
            }
            Divider()
            StatusBar(model: model)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .navigationTitle(model.windowTitle)
        .toolbar { toolbar }
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

    /// The window's own toolbar — a real `NSToolbar` in the title bar, which is
    /// why the title text itself is off (`.unified(showsTitle: false)`, see
    /// `GrayroomApp`): the window has one bar across the top, not a title
    /// followed by a row of buttons.
    ///
    /// Leading placement for everything that is always there, so a develop-only
    /// control appearing at the end of the group never moves Import or the
    /// module picker.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                guard let url = ImportModel.presentSourcePanel() else { return }
                model.importModel.setSource(url)
                openWindow(id: "import")
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .help("Add a folder of photos to the library (⇧⌘I)")
            .controlProbe("toolbar-import")

            Picker("", selection: Binding(get: { model.mode }, set: {
                SelfTest.note("mode picker -> \($0.rawValue)")
                $0 == .library ? model.showLibrary() : model.showDevelop()
            })) {
                Text("Library").tag(AppModel.Mode.library)
                Text("Develop").tag(AppModel.Mode.develop)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("Library (G) · Develop (D)")
            .controlProbe("mode-picker")

            // Everything past here edits one image, so it is only up in the
            // develop view. Hidden rather than disabled: a greyed-out brush
            // next to a grid of photos is noise, not information.
            if model.mode == .develop {
                developTools
            }

            // A flexible space, so Export sits at the far end of the bar the
            // way it sat at the far end of the row it replaces. Without it
            // AppKit packs every item against the leading edge — there is no
            // title left in the middle to push them apart.
            Spacer()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isRendering || model.isDecoding {
                ProgressView().controlSize(.small)
            }
            Button {
                model.presentExportSheet()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.imageURL == nil || model.mode == .library)
            .help("Export at full resolution (⌘E)")
            .controlProbe("toolbar-export")
        }
    }

    @ViewBuilder
    private var developTools: some View {
        Group {
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
            .labelStyle(.titleAndIcon)
            .help("Show the unedited decode (or hold \\)")

            Button("Fit") { model.zoomToFit() }.help("Zoom to fit (0)")
            Button("1:1") { model.zoomToActualSize() }.help("Zoom to 100 % (1)")
            Text(String(format: "%.0f%%", model.zoomPercent))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
    }
}

/// The one line across the bottom of the window, in both modules.
///
/// It is one bar and not two: the grid used to carry its own count and size
/// slider in a strip of its own, directly above this one, which put two
/// horizontal rules and two rows of 11 pt text under the photos and made the
/// window's furniture jump by a row every time `g`/`d` was pressed. So each
/// module puts its own identity at the two ends — the grid's count and size
/// slider, the open photo's name, resolution, camera and colour label — and
/// everything that belongs to the app rather than to a module (the activity
/// indicator, the status/error line, the render timer, the saved dot) stays put
/// across the switch.
///
/// The height is **pinned** for the same reason: the size slider is taller than
/// a line of text, so a bar that sized itself to its contents would be two
/// points shorter in Develop and would move the canvas under the pointer.
private struct StatusBar: View {
    @Bindable var model: AppModel

    /// Tall enough for the tallest thing either module puts in the bar, which
    /// is the size slider.
    static let contentHeight: Double = 20

    var body: some View {
        HStack(spacing: 12) {
            if model.mode == .library {
                if model.libraryViewMode == .loupe {
                    loupeIdentity
                } else {
                    Text(model.libraryCountLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                        .controlProbe("library-count")
                }
            } else {
                developIdentity
            }
            Spacer()
            if let error = model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            } else if let status = model.statusMessage {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            // Background work, to the left of the render timer. Deliberately
            // not Lightroom's top-left identity plate: down here it never
            // competes with the toolbar for the user's eye.
            ActivityIndicator(tasks: model.tasks)
            if model.lastRenderMilliseconds > 0 {
                Text(String(format: "%.1f ms", model.lastRenderMilliseconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // The size of a thumbnail means nothing in the loupe, which is
            // showing exactly one photo.
            if model.mode == .library, model.libraryViewMode == .grid {
                thumbnailSizeSlider
            }
            Circle()
                .fill(model.store.isDirty ? Color.orange : Color.green.opacity(0.6))
                .frame(width: 7, height: 7)
                .help(model.store.isDirty ? "Unsaved changes" : "Saved to the library")
        }
        .frame(height: StatusBar.contentHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Which photo is on the canvas — develop only. In the library there is no
    /// one photo, and the grid says all of this per cell.
    @ViewBuilder
    private var developIdentity: some View {
        Text(model.imageURL?.lastPathComponent ?? "No image")
            .font(.system(size: 11, weight: .medium))
            .controlProbe("develop-name")
        if model.previewSize != .zero {
            Text(String(format: "%.0f×%.0f",
                        model.previewSize.width, model.previewSize.height))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        if !model.cameraDescription.isEmpty {
            Text(model.cameraDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .controlProbe("develop-camera")
        }
        // The glass, after the body that carried it and in the same secondary
        // weight — a file that does not name its lens gets no label at all
        // rather than a dash, exactly as the camera does.
        if !model.lensDescription.isEmpty {
            Text(model.lensDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .controlProbe("develop-lens")
        }
        // The colour label of the photo on the canvas. The grid shows this by
        // tinting the whole cell, so this dot is develop's only sign of one —
        // and without it, 6/7/8/9 in the develop view would be a keystroke with
        // no visible effect at all.
        if model.currentColorLabel != .unlabeled {
            Circle()
                .fill(LibraryCell.swatch(model.currentColorLabel))
                .frame(width: 8, height: 8)
                .help("Colour label: \(model.currentColorLabel.name)")
        }
    }

    /// The loupe's end of the bar: the photo it is showing, said the way the
    /// develop view says it — and Lightroom's position in the filtered list,
    /// "3 / 11", where the grid puts its count.
    @ViewBuilder
    private var loupeIdentity: some View {
        Text(model.loupePositionLabel)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
            .controlProbe("loupe-position")
        Text(model.loupeName)
            .font(.system(size: 11, weight: .medium))
            .controlProbe("loupe-name")
        if !model.loupeResolution.isEmpty {
            Text(model.loupeResolution)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .controlProbe("loupe-resolution")
        }
        if !model.loupeCameraDescription.isEmpty {
            Text(model.loupeCameraDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .controlProbe("loupe-camera")
        }
        if !model.loupeLensDescription.isEmpty {
            Text(model.loupeLensDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .controlProbe("loupe-lens")
        }
        if let photo = model.loupePhoto, photo.color != .unlabeled {
            Circle()
                .fill(LibraryCell.swatch(photo.color))
                .frame(width: 8, height: 8)
                .help("Colour label: \(photo.color.name)")
                .controlProbe("loupe-color")
        }
        // The loupe zooms, so it says what it is zoomed to. The develop view
        // puts this in the title bar next to its Fit and 1:1 buttons; the loupe
        // has no buttons of its own — 0 and 1 are the whole interface — so the
        // number goes where the rest of the loupe's identity is.
        Text(String(format: "%.0f%%", model.zoomPercent))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
            .help("Zoom to fit (0) · 100 % (1) · double-click toggles")
            .controlProbe("loupe-zoom")
    }

    /// Lightroom's thumbnail-size slider, at the trailing end of the grid's own
    /// bar — the same control `+`/`-` step from the keyboard.
    @ViewBuilder
    private var thumbnailSizeSlider: some View {
        Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
        Slider(value: $model.libraryThumbnailSize,
               in: ImportModel.minimumThumbnailSize...ImportModel.maximumThumbnailSize)
            .controlSize(.small)
            .frame(width: 140)
            .controlProbe("library-thumbnail-size")
        Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
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
            .controlProbe("export-format")
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
                    .controlProbe("export-cancel")
                Button("Choose File…") { model.runExport() }
                    .keyboardShortcut(.defaultAction)
                    .controlProbe("export-choose")
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
