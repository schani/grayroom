import AppKit
import CoreGraphics
import Foundation
import GrayroomCanvas
import GrayroomCore
import GrayroomUI
import Metal
import Observation
import UniformTypeIdentifiers

/// The app's single coordinator: which file is open, the render loop, the tools,
/// the sidecar autosave and the export.
///
/// Main-thread only by convention (like the rest of the UI); everything that
/// touches the GPU goes through `RenderService`, which hops to its own queues
/// and calls back on the main queue.
///
/// # The interactive loop
///
/// ```
/// slider / stroke / undo
///     -> EditStateStore.onChange(invalidation)
///     -> requestRender()            coalescing: keep only the newest EditState
///     -> [decode only if white balance changed]     full resolution, always
///     -> Pipeline.render on the cached linear texture      (background queue)
///     -> canvas.imageTexture = result; setNeedsDisplay     (main)
/// ```
///
/// There is no timer and no fixed debounce interval. A render request that
/// arrives while one is in flight replaces the pending one, so the loop
/// self-limits to whatever the GPU can actually do and never queues up stale
/// frames.
///
/// The decode is at **full resolution** — zoom above 100 % shows the file's own
/// pixels — which makes a render expensive enough that an edit the pipeline
/// cannot turn around in a frame is rendered twice: a reduced draft while the
/// gesture is live, then a refine at full resolution the moment nothing newer is
/// pending. `PreviewStrategy` owns that policy; `pump()` only executes it.
@Observable
final class AppModel {
    static let shared = AppModel()

    let store = EditStateStore()

    // MARK: Document

    private(set) var imageURL: URL?
    private(set) var previewSize: CGSize = .zero
    private(set) var fullSize: CGSize = .zero
    private(set) var cameraDescription: String = ""

    // MARK: Status

    private(set) var isDecoding = false
    private(set) var isRendering = false
    private(set) var isExporting = false
    private(set) var lastRenderMilliseconds: Double = 0
    private(set) var histogram = HistogramModel.empty
    var statusMessage: String?
    var errorMessage: String?

    // MARK: Tools

    var tool: CanvasTool = .pan {
        didSet {
            canvas?.tool = tool
            if tool == .brush, store.selectedMaskID == nil, !store.edit.masks.isEmpty {
                store.selectedMaskID = store.edit.masks.last?.id
            }
        }
    }
    var eraserActive = false { didSet { canvas?.eraserActive = eraserActive } }
    var showBeforeAfter = false { didSet { pushTextureToCanvas() } }
    var showMaskOverlay = false { didSet { requestRender(force: true) } }
    private(set) var zoomPercent: Double = 100

    // MARK: Export sheet

    var isExportSheetPresented = false
    var exportFormat: ExportFormat = .png16
    var exportQuality: Double = 0.92

    // MARK: Private state

    private var service: RenderService?
    private weak var canvas: CanvasNSView?

    private var decoded: DecodedImage?
    /// The decode reduced to `PreviewStrategy.draftLongEdge`, built once per
    /// decode. `nil` when the frame is already that small.
    private var draftTexture: MTLTexture?
    private var decodeKey: DecodeKey?
    private var currentTexture: MTLTexture?
    private var beforeTexture: MTLTexture?
    private var coverageTexture: MTLTexture?

    private var pendingEdit: EditState?
    /// The edit the last render was of — what a refine pass re-renders.
    private var lastRenderedEdit: EditState?
    /// `true` when what the canvas is showing came from the draft pass, i.e. a
    /// refine is owed as soon as the loop has nothing newer to do.
    private var lastRenderWasDraft = false
    private var renderInFlight = false
    private var autosaveTask: Task<Void, Never>?

    private struct TargetedSession {
        var baseline: [Double]
        var hue: Double?
        var delta: Double = 0
    }
    private var targeted: TargetedSession?

    private static let lastFileDefaultsKey = "GrayroomLastOpenedFile"

    init() {
        do {
            service = try RenderService()
        } catch {
            errorMessage = "Metal is unavailable: \(error)"
        }
        store.onChange = { [weak self] invalidation in
            self?.editChanged(invalidation)
        }
    }

    // MARK: - Canvas wiring

    func makeCanvas() -> CanvasNSView {
        guard let service else {
            // No Metal: hand back a stub so the app still shows its error.
            let device = MTLCreateSystemDefaultDevice()!
            return CanvasNSView(device: device, commandQueue: device.makeCommandQueue()!)
        }
        let view = CanvasNSView(device: service.metal.device,
                                commandQueue: service.metal.commandQueue)
        view.handler = self
        view.tool = tool
        view.brushSize = store.brush.size
        view.brushFeather = store.brush.feather
        canvas = view
        if previewSize != .zero { view.setImageSize(previewSize) }
        pushTextureToCanvas()
        return view
    }

    // MARK: - Opening files

    /// A file named on the command line wins; otherwise reopen whatever was open
    /// last time. There is no document architecture — one window, one image.
    func openInitialDocument() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            open(url: URL(fileURLWithPath: path))
            return
        }
        if let path = UserDefaults.standard.string(forKey: AppModel.lastFileDefaultsKey),
           FileManager.default.fileExists(atPath: path) {
            open(url: URL(fileURLWithPath: path))
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Open a RAW file"
        var types: [UTType] = [.rawImage]
        if let dng = UTType("com.adobe.raw-image") { types.append(dng) }
        panel.allowedContentTypes = types
        if let current = imageURL {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        guard let service else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File not found: \(url.path)"
            return
        }
        autosaveTask?.cancel()
        service.clearMaskCache()
        imageURL = url
        decoded = nil
        draftTexture = nil
        decodeKey = nil
        currentTexture = nil
        beforeTexture = nil
        coverageTexture = nil
        lastRenderedEdit = nil
        lastRenderWasDraft = false
        histogram = .empty
        statusMessage = nil
        errorMessage = nil
        UserDefaults.standard.set(url.path, forKey: AppModel.lastFileDefaultsKey)

        // Sidecar first, so the very first decode already has the right WB.
        let sidecar = EditState.sidecarURL(forRAW: url)
        var edit = EditState()
        if FileManager.default.fileExists(atPath: sidecar.path) {
            do {
                edit = try EditState.load(from: sidecar)
                statusMessage = "Loaded \(sidecar.lastPathComponent)"
            } catch {
                errorMessage = "Could not read \(sidecar.lastPathComponent): \(error)"
            }
        }
        store.replace(edit, named: nil)
        store.selectedMaskID = edit.masks.first?.id
        store.markSaved()

        service.probe(url: url) { [weak self] result in
            guard let self else { return }
            if case .success(let info) = result {
                self.fullSize = info.orientedSize
                self.store.asShotTemperature = info.asShotTemperature
                self.store.asShotTint = info.asShotTint
                let make = info.cameraMake ?? ""
                let model = info.cameraModel ?? ""
                self.cameraDescription = "\(make) \(model)".trimmingCharacters(in: .whitespaces)
            }
        }
        requestRender(force: true)
    }

    var windowTitle: String {
        guard let imageURL else { return "Grayroom" }
        var parts = [imageURL.lastPathComponent]
        parts.append(String(format: "%.0f%%", zoomPercent))
        if lastRenderMilliseconds > 0 {
            parts.append(String(format: "%.1f ms", lastRenderMilliseconds))
        }
        return parts.joined(separator: " — ")
    }

    // MARK: - Render loop

    private func editChanged(_ invalidation: RenderInvalidation) {
        guard invalidation != .none else { return }
        requestRender()
        // A state that came from disk is not dirty, and rewriting the sidecar
        // just because it was read would be silly.
        if store.isDirty { scheduleAutosave() }
    }

    /// Ask for a render of the current edit. Coalescing: the newest request
    /// wins, so a fast slider drag never queues up stale frames. `force` exists
    /// only to make the call site's intent readable — a request whose edit is
    /// unchanged still re-renders, which is what the mask overlay toggle needs.
    func requestRender(force: Bool = false) {
        guard service != nil, imageURL != nil else { return }
        pendingEdit = store.edit
        pump()
    }

    /// `true` when rendering `edit` at the decode's own resolution would be too
    /// slow to drag against, so the loop should show a draft first.
    private func shouldDraft(_ edit: EditState) -> Bool {
        // `fullSize` (from the probe) stands in until the first decode lands.
        let size = previewSize == .zero ? fullSize : previewSize
        return PreviewStrategy.draftLongEdge(fullSize: size,
                                             clarityActive: edit.clarityActive) != nil
    }

    private func nextStep() -> PreviewRenderStep {
        let candidate = pendingEdit ?? lastRenderedEdit
        let edge = candidate.flatMap { shouldDraft($0) ? PreviewStrategy.draftLongEdge : nil }
        return PreviewStrategy.nextStep(hasPendingEdit: pendingEdit != nil,
                                        lastRenderWasDraft: lastRenderWasDraft,
                                        draftLongEdge: edge)
    }

    private func pump() {
        guard !renderInFlight, let service, let url = imageURL else { return }
        let step = nextStep()
        guard step != .idle, let edit = pendingEdit ?? lastRenderedEdit else { return }
        pendingEdit = nil
        lastRenderedEdit = edit
        renderInFlight = true

        let key = DecodeKey(url: url, edit: edit, maxDimension: nil)
        if key != decodeKey || decoded == nil {
            isDecoding = true
            service.decode(url: url, edit: edit, maxDimension: nil,
                           draftLongEdge: PreviewStrategy.draftLongEdge) { [weak self] result in
                guard let self else { return }
                self.isDecoding = false
                switch result {
                case .failure(let error):
                    self.errorMessage = "Decode failed: \(error)"
                    self.renderInFlight = false
                    self.pendingEdit = nil
                    self.lastRenderWasDraft = false
                case .success(let decode):
                    let image = decode.image
                    self.decoded = image
                    self.draftTexture = decode.draft
                    self.decodeKey = key
                    self.store.asShotTemperature = image.asShotTemperature
                    self.store.asShotTint = image.asShotTint
                    let size = CGSize(width: image.width, height: image.height)
                    if size != self.previewSize {
                        self.previewSize = size
                        self.canvas?.setImageSize(size)
                    }
                    self.beforeTexture = nil
                    service.renderDefaults(input: image.texture) { [weak self] result in
                        if case .success(let t) = result {
                            self?.beforeTexture = t
                            if self?.showBeforeAfter == true { self?.pushTextureToCanvas() }
                        }
                    }
                    // The frame's real size is only known now, so ask again.
                    self.runPipeline(edit, draft: self.shouldDraft(edit))
                }
                self.pump()
            }
        } else {
            runPipeline(edit, draft: step != .full)
        }
    }

    /// One pipeline run. A draft renders from the reduced input and skips the
    /// histogram; a refine renders from the decode itself and computes it. Both
    /// rasterise the overlay at *their* input's resolution, so the overlay never
    /// covers a different extent than the image underneath it.
    private func runPipeline(_ edit: EditState, draft: Bool) {
        guard let service, let decoded else {
            renderInFlight = false
            return
        }
        let input = (draft ? draftTexture : nil) ?? decoded.texture
        let isDraft = input !== decoded.texture
        isRendering = true
        let coverageIndex = showMaskOverlay ? store.selectedMaskIndex : nil
        service.renderPreview(input: input, edit: edit,
                              coverageMaskIndex: coverageIndex,
                              computeHistogram: !isDraft) { [weak self] result in
            guard let self else { return }
            self.isRendering = false
            self.renderInFlight = false
            switch result {
            case .failure(let error):
                self.errorMessage = "Render failed: \(error)"
                self.lastRenderWasDraft = false
            case .success(let preview):
                self.currentTexture = preview.texture
                self.coverageTexture = preview.coverage
                self.lastRenderMilliseconds = preview.milliseconds
                if let h = preview.histogram { self.histogram = HistogramModel(h) }
                self.lastRenderWasDraft = isDraft
                self.pushTextureToCanvas()
            }
            self.pump()
        }
    }

    private func pushTextureToCanvas() {
        guard let canvas else { return }
        canvas.imageTexture = (showBeforeAfter ? (beforeTexture ?? currentTexture) : currentTexture)
        canvas.coverageTexture = coverageTexture
        canvas.showOverlay = showMaskOverlay && coverageTexture != nil && !showBeforeAfter
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        guard let url = imageURL else { return }
        autosaveTask?.cancel()
        let edit = store.edit
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try edit.save(to: EditState.sidecarURL(forRAW: url))
                self.store.markSaved()
            } catch {
                self.errorMessage = "Could not write sidecar: \(error)"
            }
        }
    }

    /// Cmd-S: write the sidecar right now.
    func saveSidecarNow() {
        guard let url = imageURL else { return }
        autosaveTask?.cancel()
        do {
            try store.edit.save(to: EditState.sidecarURL(forRAW: url))
            store.markSaved()
            statusMessage = "Saved \(EditState.sidecarURL(forRAW: url).lastPathComponent)"
        } catch {
            errorMessage = "Could not write sidecar: \(error)"
        }
    }

    // MARK: - Brush

    func updateBrush(_ mutate: (inout BrushParams) -> Void) {
        var b = store.brush
        mutate(&b)
        b.size = BrushSizing.clampSize(b.size)
        store.brush = b
        canvas?.brushSize = b.size
        canvas?.brushFeather = b.feather
    }

    /// Brush diameter in pixels of the *full-resolution* image, which is the
    /// number that means something across zoom levels and exports.
    var brushDiameterPixels: Double {
        let reference = fullSize == .zero ? previewSize : fullSize
        return BrushSizing.diameterPixels(size: store.brush.size, imageSize: reference)
    }

    // MARK: - Zoom commands

    func zoomToFit() { canvas?.zoomToFit() }
    func zoomToActualSize() { canvas?.zoomToActualSize() }

    // MARK: - Export

    func presentExportSheet() {
        guard imageURL != nil else { return }
        isExportSheetPresented = true
    }

    func runExport() {
        guard let service, let url = imageURL else { return }
        isExportSheetPresented = false
        let panel = NSSavePanel()
        panel.message = "Export the full-resolution render"
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent
            + "." + exportFormat.fileExtension
        if let type = UTType(filenameExtension: exportFormat.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExporting = true
        statusMessage = "Exporting \(outputURL.lastPathComponent)…"
        service.export(url: url, edit: store.edit, to: outputURL,
                       format: exportFormat, quality: exportQuality) { [weak self] result in
            guard let self else { return }
            self.isExporting = false
            switch result {
            case .success(let output):
                self.statusMessage = "Exported \(outputURL.lastPathComponent) "
                    + "(\(output.width)×\(output.height))"
            case .failure(let error):
                self.errorMessage = "Export failed: \(error)"
            }
        }
    }
}

// MARK: - Canvas input

extension AppModel: CanvasInputHandler {
    func canvasTransformChanged(_ transform: CanvasTransform) {
        zoomPercent = transform.zoomPercent
    }

    func canvasBeginStroke(atNormalized p: CGPoint, pressure: Double, erase: Bool) {
        if store.selectedMaskID == nil {
            store.addMask()
            statusMessage = "Created \(store.selectedMask?.name ?? "a mask") to paint into"
        }
        _ = store.beginStroke(at: p, pressure: pressure, erase: erase)
    }

    func canvasExtendStroke(toNormalized p: CGPoint, pressure: Double) {
        store.extendStroke(to: p, pressure: pressure, imageSize: previewSize)
    }

    func canvasEndStroke() {
        store.endStroke()
    }

    func canvasBeginTargeted(atNormalized p: CGPoint) {
        guard let service, let decoded else { return }
        store.beginGesture()
        targeted = TargetedSession(baseline: store.edit.bwMix.sliderValues, hue: nil)
        // The draft input, when there is one: this samples a small neighbourhood
        // to get one hue out of it, and running the pipeline at full resolution
        // for that would put a visible hitch on the mouse-down that starts the
        // drag. It does widen the footprint — the fixed 5x5 tap covers ~12x12
        // full-resolution pixels — which for the "what colour is this thing I
        // clicked on" question this answers is if anything the better window.
        let input = draftTexture ?? decoded.texture
        service.sampleLinearRGB(input: input, edit: store.edit,
                                normalized: p) { [weak self] result in
            guard let self, var session = self.targeted else { return }
            guard case .success(let rgb) = result else { return }
            let (hue, saturation) = TATBandMath.hueSaturation(linearRGB: rgb)
            if saturation < 0.02 {
                self.statusMessage = "That pixel is neutral — the B&W mix cannot move it"
                session.hue = nil
            } else {
                session.hue = hue
                self.statusMessage = String(format: "Targeted: hue %.0f°, saturation %.2f",
                                            hue, saturation)
            }
            self.targeted = session
            self.applyTargeted()
        }
    }

    func canvasDragTargeted(dragPixels: Double) {
        guard targeted != nil else { return }
        targeted?.delta = TATBandMath.delta(forDragPixels: dragPixels)
        applyTargeted()
    }

    func canvasEndTargeted() {
        if targeted?.hue != nil {
            store.endGesture(named: "Targeted B&W Adjustment")
        }
        targeted = nil
    }

    private func applyTargeted() {
        guard let session = targeted, let hue = session.hue else { return }
        let sliders = TATBandMath.applying(delta: session.delta, hueDegrees: hue,
                                           to: session.baseline)
        store.update { $0.bwMix.setSliderValues(sliders) }
    }

    func canvasKeyCommand(_ command: CanvasKeyCommand) {
        switch command {
        case .toggleBrush:
            tool = (tool == .brush) ? .pan : .brush
        case .toggleTargeted:
            tool = (tool == .targeted) ? .pan : .targeted
        case .toggleEraser:
            eraserActive.toggle()
        case .sizeStep(let n):
            updateBrush { $0.size = BrushSizing.adjustedSize($0.size, steps: n) }
            statusMessage = String(format: "Brush %.0f px", brushDiameterPixels)
        case .featherStep(let n):
            updateBrush { $0.feather = BrushSizing.adjustedFeather($0.feather, steps: n) }
            statusMessage = String(format: "Feather %.0f", store.brush.feather)
        case .fit:
            zoomToFit()
        case .actualSize:
            zoomToActualSize()
        }
    }

    func canvasBeforeAfterHeld(_ held: Bool) {
        showBeforeAfter = held
    }
}
