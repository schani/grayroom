import AppKit
import CoreGraphics
import Foundation
import GrayroomCanvas
import GrayroomCore
import GrayroomLibrary
import GrayroomUI
import Metal
import Observation
import UniformTypeIdentifiers

/// The app's single coordinator: which file is open, the render loop, the tools,
/// the library autosave and the export.
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

    // MARK: Mode

    /// Lightroom's two modules, and its two keys for them: `g` for the grid,
    /// `d` for the develop view.
    enum Mode: String, Equatable {
        case library
        case develop
    }

    /// The app opens on the library, the way Lightroom does — except when it
    /// was launched *at* a file (an argument, or a double-click in the Finder),
    /// which is a request to develop that file and nothing else.
    var mode: Mode = .library

    // MARK: Library

    /// Every photo in the library, in RAM, in grid order.
    let catalog = PhotoCatalog()
    /// What the grid's ring is around.
    var librarySelection = LibrarySelection()
    /// The grid's current column count, which only the view knows; the arrow
    /// keys need it to know what "one row down" means.
    var libraryColumns = 1
    var libraryThumbnailSize: Double = ImportModel.defaultThumbnailSize
    /// The cell the grid should scroll into view the next time it draws —
    /// consumed by the view. This is what makes `g` from the develop view land
    /// on the photo you were just editing rather than at the top of the grid.
    var libraryScrollTarget: Int64?
    /// The grid's pictures, development-aware — see `PreviewBuilder`.
    let previews = PreviewBuilder()

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
    /// Where SDR white falls on the histogram's axis while the HDR ceiling is in
    /// use, `nil` in SDR.
    var sdrWhiteMarker: Double? {
        HistogramModel.sdrWhiteMarkerPosition(displayWhite: store.edit.displayWhite)
    }
    var statusMessage: String?
    var errorMessage: String?

    /// Every long-running background job, with its progress and its cancel
    /// button — see `ActivityIndicator`.
    let tasks = TaskCenter()

    // MARK: Import

    let importModel = ImportModel()

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
    /// When the user last moved something. Grid previews stay off the GPU for
    /// `editingQuietPeriod` after it.
    private var lastEditAt = Date.distantPast
    static let editingQuietPeriod: TimeInterval = 0.5
    private var autosaveTask: Task<Void, Never>?

    /// The library, opened once at launch. `nil` means it could not be opened —
    /// the app still edits, it just does not persist.
    private var library: Library?
    /// The development the open image's edits are written to, once it exists.
    private var developmentID: Int64?
    /// The open photo's library id — the bridge between the two modes: what
    /// `g` re-highlights in the grid, and what a colour key labels while the
    /// develop view is up.
    private(set) var currentPhotoID: Int64?
    /// Bumped on every `open(url:)`; a lookup that lands after the user has
    /// moved on to another file is discarded.
    private var openGeneration = 0
    /// The library work (hash, import, development lookup) runs here so a 50 MB read
    /// never lands on the main thread.
    private let libraryQueue = DispatchQueue(label: "grayroom.library", qos: .userInitiated)
    /// The import in flight, if any — one at a time.
    private var importTaskID: TaskCenter.BackgroundTask.ID?

    private struct TargetedSession {
        var baseline: [Double]
        var hue: Double?
        var delta: Double = 0
    }
    private var targeted: TargetedSession?

    static let lastFileDefaultsKey = "GrayroomLastOpenedFile"

    init() {
        do {
            service = try RenderService()
        } catch {
            errorMessage = "Metal is unavailable: \(error)"
        }
        do {
            library = try Library.openDefault()
        } catch {
            errorMessage = "Could not open the library: \(error). Edits will not be saved."
            // No catalog, no grid: without a library there is nothing to show
            // in the library mode, so the app opens straight into develop.
            mode = .develop
        }
        // Derived data, in its own database beside the library: losing it costs
        // time and nothing else. A library that would not open has no previews
        // either, and the grid falls back to reading each file directly.
        if let library {
            do {
                let store = try PreviewStore.open(for: library)
                library.previewStore = store
                previews.previews = store
            } catch {
                errorMessage = "Could not open the preview store: \(error)"
            }
        }
        reloadCatalog()
        store.onChange = { [weak self] invalidation in
            self?.editChanged(invalidation)
        }
        importModel.tasks = tasks
        previews.tasks = tasks
        previews.library = library
        previews.render = { [weak self] url, edit, done in
            guard let service = self?.service else {
                done(nil)
                return
            }
            service.renderGridPreview(url: url, edit: edit,
                                      maxDimension: PreviewBuilder.pixelSize) { result in
                done(try? result.get())
            }
        }
        // A grid preview is a whole decode. Held back while the develop view is
        // busy, it costs nothing; run in the middle of a slider drag it is a
        // visible stall on the frame the user is dragging.
        previews.isEditingActive = { [weak self] in
            guard let self else { return false }
            return self.renderInFlight
                || Date().timeIntervalSince(self.lastEditAt) < AppModel.editingQuietPeriod
        }
        // Identity in this library is the file's bytes, so "already imported"
        // is a hash question, not a path question — and it takes both halves:
        // a photo the library knows but has no location for is one whose files
        // are all gone, and adding this one back is exactly right.
        if let library {
            importModel.isHashImported = { hex in
                guard let photo = ((try? library.photo(withHashHexString: hex)) ?? nil),
                      let photoID = photo.id
                else { return false }
                return ((try? library.locations(for: photoID)) ?? []).isEmpty == false
            }
        }
        importModel.onImport = { [weak self] entries in self?.runImport(entries) }
    }

    // MARK: - Import

    /// Adds the chosen files to the library on `libraryQueue`, reporting into
    /// the activity centre as it goes.
    ///
    /// The scan has already hashed every one of these files, so the hashes come
    /// along rather than being recomputed — which is most of the work. It still
    /// runs one file at a time (the bottleneck is the disk, not the CPU) and
    /// checks the task's cancel flag between files.
    func runImport(_ entries: [ImportEntry]) {
        guard let library, !entries.isEmpty, importTaskID == nil else { return }
        let urls = entries.map(\.url)
        var hashes: [URL: String] = [:]
        for entry in entries where entry.hash != nil {
            hashes[entry.url.standardizedFileURL] = entry.hash
        }
        let taskID = tasks.begin(title: "Importing photos", total: urls.count, cancellable: true)
        importTaskID = taskID
        statusMessage = nil
        libraryQueue.async { [weak self] in
            let importer = Importer(library: library)
            var added = 0
            var existing = 0
            var failed = 0
            importer.importFiles(urls, precomputedHashes: hashes, progress: { finished, _, outcome in
                switch outcome {
                case .success(let result):
                    if result.isNewPhoto { added += 1 } else { existing += 1 }
                case .failure:
                    failed += 1
                }
                DispatchQueue.main.async { [weak self] in
                    self?.tasks.update(taskID, completed: finished,
                                       detail: urls[finished - 1].lastPathComponent)
                }
            }, isCancelled: { [weak self] in
                guard let self else { return true }
                return self.tasks.isCancelled(taskID)
            })
            let cancelled = self?.tasks.isCancelled(taskID) ?? false
            let summary = AppModel.importSummary(added: added, existing: existing, failed: failed)
            DispatchQueue.main.async {
                guard let self else { return }
                self.tasks.finish(taskID)
                self.importTaskID = nil
                self.statusMessage = cancelled ? "Import cancelled — " + summary : summary
                // The photos that just arrived belong in the grid.
                self.reloadCatalog()
            }
        }
    }

    static func importSummary(added: Int, existing: Int, failed: Int) -> String {
        var message = "Imported \(added)"
        var notes: [String] = []
        if existing > 0 { notes.append("\(existing) already in library") }
        if failed > 0 { notes.append("\(failed) failed") }
        if !notes.isEmpty { message += " (" + notes.joined(separator: ", ") + ")" }
        return message
    }

    // MARK: - Library mode

    /// Re-reads the whole catalog. Cheap enough to do outright: five statements
    /// against a local SQLite file, and the result is what the grid holds.
    func reloadCatalog() {
        guard let library else { return }
        do {
            try catalog.load(from: library)
            // A photo that is no longer there is no longer selected.
            librarySelection.retain(Set(catalog.ids))
        } catch {
            errorMessage = "Could not read the library: \(error)"
        }
    }

    /// `g`. Comes back to the grid with the photo you were developing
    /// highlighted and scrolled into view.
    func showLibrary() {
        if let currentPhotoID, catalog.index(of: currentPhotoID) != nil {
            librarySelection.select([currentPhotoID])
            libraryScrollTarget = currentPhotoID
        }
        mode = .library
    }

    /// `d`. From the grid this opens the highlighted photo; with nothing
    /// highlighted it just shows whatever is already open.
    func showDevelop() {
        if mode == .library, let id = highlightedPhotoIDs.first,
           id != currentPhotoID || imageURL == nil {
            openPhoto(id: id)
            return
        }
        guard imageURL != nil else { return }
        mode = .develop
    }

    /// Opens a photo the catalog already knows.
    ///
    /// The difference from `open(url:)` is the hash: the photo's identity is
    /// its row id, which we have, so there is no reason to read 50 MB off the
    /// disk to rediscover it.
    func openPhoto(id: Int64) {
        guard let photo = catalog.photo(id: id) else { return }
        guard let path = photo.firstLocation else {
            errorMessage = "\(photo.originalName) has no file on disk"
            return
        }
        librarySelection.select([id])
        open(url: URL(fileURLWithPath: path), knownPhotoID: id)
        mode = .develop
    }

    // MARK: Grid selection

    var highlightedPhotoIDs: [Int64] { librarySelection.ordered(in: catalog.ids) }

    func isHighlighted(_ id: Int64) -> Bool { librarySelection.contains(id) }

    func libraryClick(_ id: Int64, modifiers: GridClickModifiers) {
        librarySelection.click(id, modifiers: modifiers, order: catalog.ids)
    }

    func moveLibraryHighlight(dx: Int, dy: Int) {
        librarySelection.moveHighlight(dx: dx, dy: dy, columns: libraryColumns,
                                       order: catalog.ids)
        libraryScrollTarget = librarySelection.anchor
    }

    /// Shift-arrow: the anchor stays put and the range grows from it.
    func extendLibraryHighlight(dx: Int, dy: Int) {
        librarySelection.extendHighlight(dx: dx, dy: dy, columns: libraryColumns,
                                         order: catalog.ids)
        libraryScrollTarget = librarySelection.cursor
    }

    /// The grid's bottom-bar count.
    var libraryCountLabel: String {
        let total = catalog.count
        let photos = "\(total) photo" + (total == 1 ? "" : "s")
        let selected = librarySelection.count
        return selected == 0 ? photos : "\(photos) · \(selected) selected"
    }

    func selectAllPhotos() {
        librarySelection.select(catalog.ids)
    }

    func stepLibraryThumbnailSize(_ steps: Int) {
        libraryThumbnailSize = min(max(libraryThumbnailSize + Double(steps) * 32,
                                       ImportModel.minimumThumbnailSize),
                                   ImportModel.maximumThumbnailSize)
    }

    // MARK: Colour labels

    /// What a colour key applies to: the highlight in the grid, the open photo
    /// in the develop view.
    var colorLabelTargets: [Int64] {
        if mode == .library { return highlightedPhotoIDs }
        return currentPhotoID.map { [$0] } ?? []
    }

    /// The open photo's label, for the develop view's status dot.
    var currentColorLabel: ColorLabel {
        currentPhotoID.flatMap { catalog.photo(id: $0)?.color } ?? .unlabeled
    }

    /// Lightroom's `6`–`9`: setting the colour a photo already has clears it.
    ///
    /// With several photos highlighted the toggle is all-or-nothing — the key
    /// clears only when *every* one of them already carries that colour, which
    /// is what makes "label the lot" work on a mixed selection instead of
    /// flipping half of it back.
    func toggleColorLabel(_ color: ColorLabel) {
        let ids = colorLabelTargets
        guard !ids.isEmpty else { return }
        let allHave = ids.allSatisfy { catalog.photo(id: $0)?.color == color }
        setColorLabel(allHave ? .unlabeled : color)
    }

    /// The menu's items, and the second half of the toggle: no toggling, just
    /// this label onto whatever is selected.
    func setColorLabel(_ color: ColorLabel) {
        let ids = colorLabelTargets
        guard !ids.isEmpty, let library else { return }
        do {
            try catalog.setColor(color, for: ids, in: library)
            let what = ids.count == 1
                ? (catalog.photo(id: ids[0])?.originalName ?? "1 photo")
                : "\(ids.count) photos"
            statusMessage = color == .unlabeled
                ? "Cleared the colour label on \(what)"
                : "Labelled \(what) \(color.name)"
        } catch {
            errorMessage = "Could not set the colour label: \(error)"
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
    ///
    /// Only the command line switches modules. Being launched at a file is a
    /// request to develop that file; silently reopening yesterday's file is
    /// not, so it loads in the background while the library grid stays up.
    func openInitialDocument() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            open(url: URL(fileURLWithPath: path))
            mode = .develop
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
        panel.message = "Open a photo"
        var types: [UTType] = [.rawImage, .jpeg, .tiff, .png]
        for identifier in ["com.adobe.raw-image", "public.heic", "public.heif"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        panel.allowedContentTypes = types
        if let current = imageURL {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
        // Choosing a file by hand means developing it.
        mode = .develop
    }

    /// `knownPhotoID` is the library row this file is already known to be, when
    /// the caller knows it (the grid does). It skips the hash — the only reason
    /// opening a file has ever needed to read all of it.
    func open(url: URL, knownPhotoID: Int64? = nil) {
        guard let service else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File not found: \(url.path)"
            return
        }
        autosaveTask?.cancel()
        service.clearMaskCache()
        imageURL = url
        currentPhotoID = knownPhotoID
        developmentID = nil
        openGeneration += 1
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

        store.replace(EditState(), named: nil)
        store.selectedMaskID = nil
        store.markSaved()
        loadFromLibrary(url: url, generation: openGeneration, knownPhotoID: knownPhotoID)

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
        lastEditAt = Date()
        requestRender()
        // A state that came from the library is not dirty, and rewriting the
        // development just because it was read would be silly.
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

    // MARK: - Library

    /// Hash the file, import it if the library has never seen it, and adopt its
    /// first development.
    ///
    /// All of that runs off the main thread: hashing a 50 MB RAW is tens of
    /// milliseconds, which is a visible hitch on a window that is also trying to
    /// start a decode. The consequence is that the first decode uses as-shot
    /// white balance and a second one follows if the stored edit overrode it.
    ///
    /// `knownPhotoID` short-circuits the hash: a photo opened from the grid is
    /// already identified, and re-reading the whole file to find out what it is
    /// would be the slowest part of opening it.
    private func loadFromLibrary(url: URL, generation: Int, knownPhotoID: Int64? = nil) {
        guard let library else { return }
        libraryQueue.async {
            let outcome = Result {
                () -> (photoID: Int64, isNew: Bool, first: Development?) in
                if let knownPhotoID {
                    return (knownPhotoID, false, try library.developments(for: knownPhotoID).first)
                }
                let hash = try FileHash.sha256(of: url)
                let photoID: Int64
                var isNew = false
                if let existing = try library.photo(withHash: hash), let id = existing.id {
                    photoID = id
                } else {
                    photoID = try Importer(library: library).importFile(at: url).photoID
                    isNew = true
                }
                return (photoID, isNew, try library.developments(for: photoID).first)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                switch outcome {
                case .failure(let error):
                    self.errorMessage = "Could not read the library: \(error)"
                case .success(let (photoID, isNew, first)):
                    self.currentPhotoID = photoID
                    self.developmentID = first?.id
                    // Opening a file the library had never seen imports it, so
                    // the grid has to learn about it.
                    if isNew || self.catalog.index(of: photoID) == nil { self.reloadCatalog() }
                    // An edit the user has already started beats a stored one:
                    // the lookup lost the race, it does not get to win it.
                    if let first, !self.store.isDirty {
                        self.store.replace(first.edit, named: nil)
                        self.store.selectedMaskID = first.edit.masks.first?.id
                        self.store.markSaved()
                        self.requestRender(force: true)
                    } else if self.store.isDirty {
                        self.persistEdit(announce: false)
                    }
                }
            }
        }
    }

    private func scheduleAutosave() {
        guard imageURL != nil, library != nil else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistEdit(announce: false)
        }
    }

    /// Cmd-S: write the edit to the library right now.
    func saveNow() {
        autosaveTask?.cancel()
        persistEdit(announce: true)
    }

    /// Writes the current edit to the photo's development, creating development #1 the
    /// first time there is something to store.
    ///
    /// A no-op while the library lookup is still in flight — it finishes by
    /// calling back here if the edit is dirty by then.
    private func persistEdit(announce: Bool) {
        guard let library, imageURL != nil, let photoID = currentPhotoID else { return }
        let edit = store.edit
        do {
            if let developmentID {
                _ = try library.updateDevelopment(id: developmentID, edit: edit)
            } else {
                developmentID = try library.addDevelopment(photoID: photoID, edit: edit).id
                // The grid draws a badge for "has a development", so the count
                // it holds has to move the moment one is created.
                catalog.setDevelopmentCount(
                    max(catalog.photo(id: photoID)?.developmentCount ?? 0, 1), for: photoID)
            }
            store.markSaved()
            // The grid is now showing a picture of the edit *before* this one.
            // Moving the fingerprint is what tells the cell so; dropping the
            // cached image and asking for the new one now is what makes `g`
            // land on the edited look rather than on a stale frame that
            // refreshes a second later.
            catalog.setDevelopmentFingerprint(edit.fingerprint, for: photoID)
            previews.invalidate(photoID: photoID)
            if let photo = catalog.photo(id: photoID) {
                previews.image(for: photo) { _ in }
            }
            if announce { statusMessage = "Saved to the library" }
        } catch {
            errorMessage = "Could not save the edit: \(error)"
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
        statusMessage = nil
        // Indeterminate: a full-resolution render reports nothing until it is
        // done, and inventing a fake percentage would be worse than a bar that
        // says only "still going".
        let taskID = tasks.begin(title: "Exporting \(outputURL.lastPathComponent)")
        service.export(url: url, edit: store.edit, to: outputURL,
                       format: exportFormat, quality: exportQuality) { [weak self] result in
            guard let self else { return }
            self.isExporting = false
            self.tasks.finish(taskID)
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
        case .colorLabel(let raw):
            if let color = ColorLabel(rawValue: raw) { toggleColorLabel(color) }
        }
    }

    func canvasBeforeAfterHeld(_ held: Bool) {
        showBeforeAfter = held
    }
}
