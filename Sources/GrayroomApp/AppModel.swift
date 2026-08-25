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
    /// The Library module's browser: which source the Folders panel has
    /// selected, which rows are open, what that leaves in the grid, and the
    /// grid's own highlight. It is a separate object because all of that is
    /// testable without a window — see `LibraryBrowserState`.
    let browser = LibraryBrowserState()
    /// The grid's current column count, which only the view knows; the arrow
    /// keys need it to know what "one row down" means.
    var libraryColumns = 1
    /// The width the grid was last laid out at while it was showing. It is what
    /// the grid is held at while the loupe has the window, so the panel going
    /// away does not reflow it — see `LibraryView`.
    var libraryGridWidth: Double = 0
    var libraryThumbnailSize: Double = ImportModel.defaultThumbnailSize
    /// The cell the grid should scroll into view the next time it draws —
    /// consumed by the view. This is what makes `g` from the develop view land
    /// on the photo you were just editing rather than at the top of the grid.
    var libraryScrollTarget: Int64?
    /// Where the grid is scrolled to, as its `ScrollView` reports it, and `nil`
    /// while there is no grid in the window at all. Nothing puts it back: the
    /// Library view stays in the window while Develop and the loupe are in
    /// front of it (see `RootView`, `LibraryView`), so the position is the
    /// scroll view's own and this is only a reading of it.
    var libraryGridScroll: GridScrollMetrics?
    /// The grid's pictures, development-aware — see `PreviewBuilder`.
    let previews = PreviewBuilder()
    /// The camera's own pictures, at loupe resolution, for photos that have
    /// never been developed — see `LoupeImageStore`.
    let loupeImages = LoupeImageStore()

    // MARK: Loupe

    /// What the loupe's canvas is drawing right now: the grid's 512 px preview
    /// at first, replaced by the loupe's own picture the moment it lands.
    private(set) var loupeTexture: MTLTexture?
    /// The size, in image pixels, of what the loupe is showing — the frame the
    /// canvas fits and zooms, which for a pipeline render is the decode's own
    /// size even while a draft pass is what is on screen.
    private(set) var loupeImageSize: CGSize = .zero
    /// Whether `loupeTexture` is the loupe's own picture rather than the grid
    /// preview standing in for it.
    private(set) var loupeIsFullResolution = false
    /// Why there is no picture, when there is none — a photo whose file the
    /// library has lost.
    private(set) var loupeMessage: String?
    /// Bumped on every photo change; a load that lands after the user has
    /// arrowed on is discarded.
    private var loupeGeneration = 0
    /// Whether the loupe's picture comes from the render loop (a developed
    /// photo) rather than from the camera's embedded preview.
    private var loupeUsesPipeline = false

    // MARK: Document

    private(set) var imageURL: URL?
    private(set) var previewSize: CGSize = .zero
    private(set) var fullSize: CGSize = .zero
    private(set) var cameraDescription: String = ""
    /// The lens the open photo was taken through, "" when the file does not say.
    private(set) var lensDescription: String = ""

    // MARK: Status

    private(set) var isDecoding = false
    private(set) var isRendering = false
    private(set) var isExporting = false
    private(set) var lastRenderMilliseconds: Double = 0
    private(set) var histogram = HistogramModel.empty
    /// Where SDR white falls on the histogram's axis while the HDR ceiling is in
    /// use, `nil` in SDR.
    var sdrWhiteMarker: Double? {
        HistogramModel.sdrWhiteMarkerPosition(
            displayWhite: hdrSuppression.displayEdit(store.edit).displayWhite)
    }
    /// Whether the system has asked for HDR content to be suppressed — the
    /// canvas drops to standard dynamic range and the loop renders the SDR
    /// rendition while it has.
    let hdrSuppression = HDRSuppression()
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
    /// The loupe's canvas — the same view class, so the loupe pans, zooms and
    /// reaches the display's headroom exactly as the develop view does. Only
    /// one of the two is ever in the window.
    private weak var loupeCanvas: CanvasNSView?

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
    private var similarTaskID: TaskCenter.BackgroundTask.ID?

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
            if let override = ProcessInfo.processInfo.environment["GRAYROOM_LIBRARY"],
               !override.isEmpty {
                library = try Library(path: override)
            } else {
                library = try Library.openDefault()
            }
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
        observeHDRSuppression()
    }

    /// Follow the system's HDR suppression: the canvases stop asking for
    /// headroom and the loop re-renders the SDR rendition, both ways round.
    private func observeHDRSuppression() {
        hdrSuppression.onChange = { [weak self] suppressed in
            guard let self else { return }
            self.canvas?.isHDREnabled = !suppressed
            self.loupeCanvas?.isHDREnabled = !suppressed
            self.requestRender(force: true)
        }
        let center = NotificationCenter.default
        for (name, suppressed) in [
            (NSNotification.Name.NSApplicationShouldBeginSuppressingHighDynamicRangeContent, true),
            (NSNotification.Name.NSApplicationShouldEndSuppressingHighDynamicRangeContent, false),
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.hdrSuppression.set(suppressed)
            }
        }
        hdrSuppression.set(NSApp?.applicationShouldSuppressHighDynamicRangeContent ?? false)
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
            // The Folders panel's counts are a picture of exactly this, and a
            // photo that is no longer there — or that the selected folder no
            // longer shows — is no longer selected.
            browser.rebuild(from: catalog.photos)
        } catch {
            errorMessage = "Could not read the library: \(error)"
        }
    }

    // MARK: The Folders panel, as the views address it

    var folders: FolderTree { browser.folders }

    /// Which source the Folders panel has selected. It is what the grid is
    /// filtered by, and it deliberately survives a trip through Develop.
    var folderSelection: FolderSelection {
        get { browser.selection }
        set { browser.selection = newValue }
    }

    var expandedFolders: Set<String> {
        get { browser.expandedFolders }
        set { browser.expandedFolders = newValue }
    }

    /// Whether the Folders panel is showing. The panel is Library-only — none
    /// of it applies to the one photo the develop view is editing.
    var isFolderSidebarVisible: Bool {
        get { browser.isSidebarVisible }
        set { browser.isSidebarVisible = newValue }
    }

    /// Whether the panel is actually on screen. The loupe never shows it — one
    /// photo fills the module's whole content area, as it does in Lightroom —
    /// without disturbing the preference above, so `g` comes back to the panel
    /// the way the user left it.
    var isFolderSidebarShowing: Bool { browser.isSidebarShowing }

    /// View › Show/Hide Folders, and ⌥⌘S. A no-op in the loupe, which has no
    /// panel to show: flipping a preference with nothing on screen to show for
    /// it is worse than doing nothing.
    func toggleFolderSidebar() {
        guard mode == .library, libraryViewMode == .grid else { return }
        isFolderSidebarVisible.toggle()
    }

    var visiblePhotoIDs: [Int64] { browser.visiblePhotoIDs }

    var visiblePhotos: [CatalogPhoto] { browser.visiblePhotos(from: catalog.photos) }

    func isVisible(_ id: Int64) -> Bool { browser.isVisible(id) }

    /// `g`. Comes back to the grid with the photo you were developing
    /// highlighted, and at the screenful the grid was left at.
    ///
    /// The folder the panel has selected is left alone: it is the module's
    /// state, not the photo's, and Lightroom keeps it across a trip to Develop.
    /// So the photo is only re-highlighted when the current folder is actually
    /// showing it.
    ///
    /// Nothing scrolls. The grid was never taken out of the window (see
    /// `RootView`), so it is already at the offset it was left at — asking for
    /// a cell to be scrolled into view here would *move* it.
    func showLibrary() {
        // From the loupe, this is the loupe's own way out — the photo the
        // arrows walked to has to be scrolled into view, wherever it is.
        if libraryViewMode == .loupe {
            showGrid()
            return
        }
        if let currentPhotoID, isVisible(currentPhotoID) {
            browser.selectPhotos([currentPhotoID])
        }
        clearLoupe()
        mode = .library
    }

    /// `d`. From the grid this opens the highlighted photo — in the loupe, the
    /// photo the loupe is showing, which is the same thing because the loupe
    /// *is* the selection. With nothing highlighted it just shows whatever is
    /// already open.
    func showDevelop() {
        if mode == .library, let id = highlightedPhotoIDs.first,
           id != currentPhotoID || imageURL == nil {
            openPhoto(id: id)
            return
        }
        _ = browser.exitLoupe()
        clearLoupe()
        guard imageURL != nil else { return }
        mode = .develop
    }

    // MARK: The loupe

    /// Grid or loupe — the two views of the Library module, as `g` and `e`
    /// switch between them in Lightroom.
    var libraryViewMode: LibraryViewMode { browser.viewMode }

    var loupePhotoID: Int64? { browser.loupePhotoID }

    var loupePhoto: CatalogPhoto? { loupePhotoID.flatMap { catalog.photo(id: $0) } }

    /// "3 / 11" — where this photo is in the filtered list, Lightroom's way.
    var loupePositionLabel: String { browser.loupePositionLabel }

    /// What the status bar says about the photo in the loupe. The same four
    /// facts the develop view names, read out of the catalog rather than off a
    /// decode: nothing here is open, and the library already knows all of it.
    var loupeName: String { loupePhoto?.originalName ?? "" }

    var loupeResolution: String {
        guard let photo = loupePhoto, let width = photo.width, let height = photo.height,
              width > 0, height > 0 else { return "" }
        return "\(width)×\(height)"
    }

    var loupeCameraDescription: String {
        loupePhoto.map { catalog.cameraDescription(of: $0) } ?? ""
    }

    var loupeLensDescription: String {
        loupePhoto.map { catalog.lensDescription(of: $0) } ?? ""
    }

    /// `e`, or Return in the grid. From the develop view it is Lightroom's `e`
    /// too: back to the Library, on the photo that was being developed.
    func showLoupe() {
        let fromDevelop = mode == .develop ? currentPhotoID : nil
        // A photo the selected folder does not show cannot be the loupe's — the
        // Folders panel's selection survives a trip through Develop, and the
        // loupe walks *that* list.
        let requested = fromDevelop.flatMap { isVisible($0) ? $0 : nil }
        guard browser.enterLoupe(on: requested) != nil else { return }
        mode = .library
        loadLoupeImage()
    }

    /// `g` or Esc, from the loupe: back to the grid, with the loupe's photo
    /// selected and scrolled into view.
    func showGrid() {
        libraryScrollTarget = browser.exitLoupe()
        clearLoupe()
        mode = .library
    }

    /// The left and right arrows in the loupe. Up and down do nothing: there
    /// are no rows here, and Lightroom's loupe walks one photo at a time.
    func stepLoupe(_ delta: Int) {
        let before = browser.loupePhotoID
        guard browser.stepLoupe(delta) != before else { return }
        loadLoupeImage()
    }

    /// The picture, in as many passes as it takes.
    ///
    /// # A developed photo is the real pipeline
    ///
    /// …run through the *same render loop the develop view uses*, not a copy of
    /// it. That is what makes `d`/`e` between the two views free: the loop
    /// already holds this photo's decode and its rendered frame, so the loupe
    /// only has to point its canvas at them. It is also what gives the loupe
    /// EDR and full resolution, neither of which an 8-bit `CGImage` can carry.
    ///
    /// # An undeveloped photo is the camera's own picture
    ///
    /// Exactly as in the grid: this app's defaults are black and white, and a
    /// frame nobody has edited must not turn grey just because it was looked
    /// at. So it goes on the same canvas — same zoom, same pan — with no
    /// pipeline over it at all (`LoupeImageStore`).
    ///
    /// # In the meantime
    ///
    /// Whatever the grid already has, scaled up: on screen in the same turn of
    /// the run loop the key was pressed in, and replaced the moment the real
    /// picture lands. Every callback is generation-guarded, so a load that
    /// arrives after the user has arrowed on is dropped.
    private func loadLoupeImage() {
        loupeGeneration += 1
        let generation = loupeGeneration
        loupeTexture = nil
        loupeImageSize = .zero
        loupeIsFullResolution = false
        loupeMessage = nil
        loupeUsesPipeline = false
        guard let photo = loupePhoto else { return }
        guard let url = photo.url else {
            loupeMessage = "\(photo.originalName) is not where the library left it"
            return
        }

        if photo.developmentFingerprint != nil {
            loupeUsesPipeline = true
            // The photo the develop view already has open: its decode and its
            // render are done, so this costs nothing and the loupe is full
            // resolution on this frame.
            if currentPhotoID != photo.id || imageURL == nil {
                // Walking the loupe opens photos, and opening one throws the
                // previous edit's undo history away. The autosave is a
                // one-second timer, so an arrow key pressed straight after a
                // slider move would otherwise lose it.
                if store.isDirty { persistEdit(announce: false) }
                open(url: url, knownPhotoID: photo.id)
            }
            pushLoupeRender()
        } else {
            loupeImages.image(for: photo) { [weak self] image in
                guard let self, self.loupeGeneration == generation else { return }
                guard let image, let texture = self.makeLoupeTexture(image) else {
                    if self.loupeTexture == nil {
                        self.loupeMessage = "\(photo.originalName) could not be read"
                    }
                    return
                }
                self.setLoupeTexture(texture, size: self.loupeFrameSize(of: texture),
                                     fullResolution: true)
            }
        }

        // The stand-in, if the real thing is not already up.
        guard !loupeIsFullResolution else { return }
        if let thumbnail = previews.cached(photo) {
            showLoupeStandIn(thumbnail)
        } else {
            previews.image(for: photo) { [weak self] image in
                guard let self, self.loupeGeneration == generation,
                      !self.loupeIsFullResolution, let image else { return }
                self.showLoupeStandIn(image)
            }
        }
    }

    /// Puts the render loop's current frame in the loupe — but only when it is
    /// a frame of *this* photo, rendered from the edit the photo actually has.
    ///
    /// That second half is what keeps this app's black-and-white defaults off
    /// the screen. `open(url:)` starts from an empty `EditState` and the stored
    /// development arrives a moment later on the library queue, so between the
    /// two the loop is rendering a picture that is not what this photo looks
    /// like. `developmentID` is what says the lookup has landed, and comparing
    /// the rendered edit against the one the app is holding is what says the
    /// render is of *that* edit and not of the empty one still in flight. Until
    /// both hold, the grid's 512 px preview stays up.
    private func pushLoupeRender() {
        guard loupeUsesPipeline, let photo = loupePhoto, currentPhotoID == photo.id,
              developmentID != nil, let texture = currentTexture, previewSize != .zero,
              lastRenderedEdit?.fingerprint == store.edit.fingerprint
        else { return }
        setLoupeTexture(texture, size: previewSize, fullResolution: true)
    }

    /// The grid's own 512 px preview, on the loupe's canvas, until the real
    /// picture lands.
    private func showLoupeStandIn(_ image: CGImage) {
        guard let texture = makeLoupeTexture(image) else { return }
        setLoupeTexture(texture, size: loupeFrameSize(of: texture), fullResolution: false)
    }

    /// The frame the loupe fits and zooms, for a picture that is not the
    /// pipeline's: the **photo's** size, not the texture's.
    ///
    /// A camera that embeds a 640 px preview of a 50 MP frame would otherwise
    /// put a postage stamp in the middle of the window, because fit never
    /// magnifies (`CanvasTransform.fitZoom`) — and the 512 px stand-in would sit
    /// smaller still and then jump. So the frame is the photo and the texture is
    /// whatever resolution of it is in hand, which is exactly the arrangement
    /// the develop view's draft pass already has: 1:1 means one *photo* pixel,
    /// the stand-in and the real picture share one frame, and a zoom set on one
    /// survives the other arriving.
    ///
    /// Scaled by the long edge rather than taken outright, so a preview whose
    /// aspect ratio differs slightly from the frame's is never stretched.
    private func loupeFrameSize(of texture: MTLTexture) -> CGSize {
        let w = Double(texture.width), h = Double(texture.height)
        guard w > 0, h > 0 else { return .zero }
        let own = CGSize(width: w, height: h)
        guard let photo = loupePhoto else { return own }
        let longEdge = Double(max(photo.width ?? 0, photo.height ?? 0))
        guard longEdge > max(w, h) else { return own }
        let scale = longEdge / max(w, h)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    private func makeLoupeTexture(_ image: CGImage) -> MTLTexture? {
        try? service?.metal.makeDisplayTexture(from: image)
    }

    private func setLoupeTexture(_ texture: MTLTexture, size: CGSize, fullResolution: Bool) {
        loupeTexture = texture
        loupeIsFullResolution = fullResolution
        // A new frame size refits — which is what the stand-in giving way to
        // the full-size picture is, and what stepping to the next photo is.
        if size != loupeImageSize {
            loupeImageSize = size
            loupeCanvas?.setImageSize(size)
        }
        loupeCanvas?.imageTexture = texture
    }

    private func clearLoupe() {
        loupeGeneration += 1
        loupeTexture = nil
        loupeImageSize = .zero
        loupeIsFullResolution = false
        loupeMessage = nil
        loupeUsesPipeline = false
        loupeCanvas?.imageTexture = nil
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
        browser.selectPhotos([id])
        _ = browser.exitLoupe()
        clearLoupe()
        open(url: URL(fileURLWithPath: path), knownPhotoID: id)
        mode = .develop
    }

    // MARK: Grid selection

    /// Every selection command spans the *visible* list — the folder the panel
    /// has selected, not the whole catalog — because that is what the user sees
    /// a range and an arrow key moving over. The rules themselves are in
    /// `LibraryBrowserState`, where they can be tested without a window.
    var librarySelection: LibrarySelection {
        get { browser.photoSelection }
        set { browser.photoSelection = newValue }
    }

    var highlightedPhotoIDs: [Int64] { browser.highlightedPhotoIDs }

    func isHighlighted(_ id: Int64) -> Bool { browser.isHighlighted(id) }

    func libraryClick(_ id: Int64, modifiers: GridClickModifiers) {
        browser.clickPhoto(id, modifiers: modifiers)
    }

    /// What a drag out of the grid carries for these photos: their originals,
    /// in grid order, skipping the ones whose files are not there — see
    /// `GridDragFiles`.
    func draggedFiles(for ids: [Int64]) -> [DraggedPhotoFile] {
        GridDragFiles.files(for: ids, from: catalog.photos)
            .map { DraggedPhotoFile(id: $0.id, url: $0.url) }
    }

    func moveLibraryHighlight(dx: Int, dy: Int) {
        libraryScrollTarget = browser.movePhotoHighlight(dx: dx, dy: dy, columns: libraryColumns)
    }

    /// Shift-arrow: the anchor stays put and the range grows from it.
    func extendLibraryHighlight(dx: Int, dy: Int) {
        libraryScrollTarget = browser.extendPhotoHighlight(dx: dx, dy: dy, columns: libraryColumns)
    }

    /// The status bar's photo count in the Library module — of what the grid is
    /// showing, so it follows the Folders panel the way Lightroom's does.
    var libraryCountLabel: String { browser.countLabel }

    func selectAllPhotos() {
        browser.selectAllPhotos()
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


    // MARK: Sort order

    /// View › Sort — Lightroom's Sort control, with its direction button.
    var sortKey: PhotoSortKey { catalog.sortKey }
    var sortAscending: Bool { catalog.sortAscending }

    func setSortKey(_ key: PhotoSortKey) { setSort(key, ascending: catalog.sortAscending) }

    func setSortAscending(_ ascending: Bool) { setSort(catalog.sortKey, ascending: ascending) }

    /// The catalog is the grid's order, and the browser's filtered list is a
    /// projection of it — so both move, and the highlighted photo is scrolled
    /// back to wherever the new order put it.
    func setSort(_ key: PhotoSortKey, ascending: Bool) {
        guard catalog.sortKey != key || catalog.sortAscending != ascending else { return }
        catalog.setSort(key, ascending: ascending)
        browser.rebuild(from: catalog.photos)
        libraryScrollTarget = browser.photoSelection.anchor
        statusMessage = "Sorted by \(key.title), "
            + (ascending ? "ascending" : "descending")
    }

    // MARK: Similar photos

    /// The photo Select Similar Photos measures from: the one in the loupe, or
    /// the grid's active cell.
    var similaritySubjectID: Int64? {
        if let id = browser.loupePhotoID { return id }
        return browser.photoSelection.anchor ?? highlightedPhotoIDs.first
    }

    /// Edit › Select Similar Photos: adds every photo within the default
    /// feature-print distance of the current one to the grid's highlight.
    ///
    /// The comparison reads every stored feature print and measures the subject
    /// against all of them, so it runs on the library queue with a task in the
    /// activity centre — never on the main thread.
    func selectSimilarPhotos() {
        guard mode == .library, let library, similarTaskID == nil else { return }
        guard let subject = similaritySubjectID else {
            statusMessage = "Select a photo first"
            return
        }
        let taskID = tasks.begin(title: "Finding similar photos")
        similarTaskID = taskID
        libraryQueue.async { [weak self] in
            let outcome = Result { () -> [Int64]? in
                guard try library.analysis(photoID: subject) != nil else { return nil }
                return try library.similarPhotos(to: subject).map(\.id)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tasks.finish(taskID)
                self.similarTaskID = nil
                switch outcome {
                case .success(let matches):
                    guard let matches else {
                        self.statusMessage = "That photo has not been analysed yet"
                        return
                    }
                    let added = self.browser.extendSelection(with: [subject] + matches)
                    self.statusMessage = added.count > 1
                        ? "Selected \(added.count) similar photos"
                        : "No similar photos"
                case .failure(let error):
                    self.errorMessage = "Could not compare photos: \(error)"
                }
            }
        }
    }

    // MARK: - Canvas wiring

    func makeCanvas() -> CanvasNSView {
        let view = makeBareCanvas()
        view.tool = tool
        view.brushSize = store.brush.size
        view.brushFeather = store.brush.feather
        canvas = view
        if previewSize != .zero { view.setImageSize(previewSize) }
        pushTextureToCanvas()
        return view
    }

    /// The loupe's canvas: the same view, read-only.
    ///
    /// Pan is the only tool — there is nothing here to paint into and no B&W mix
    /// to drag — so the brush and the targeted tool are simply never selected on
    /// it, and `canvasKeyCommand` refuses their keys while the Library is the
    /// module on screen. Everything else is deliberately identical to Develop's:
    /// the same EDR drawable, the same zoom gestures, the same double-click
    /// toggle.
    func makeLoupeCanvas() -> CanvasNSView {
        let view = makeBareCanvas()
        view.identifier = NSUserInterfaceItemIdentifier(AppModel.loupeCanvasIdentifier)
        view.tool = .pan
        loupeCanvas = view
        if loupeImageSize != .zero { view.setImageSize(loupeImageSize) }
        view.imageTexture = loupeTexture
        return view
    }

    /// How the loupe's canvas is told apart from the develop view's, which is
    /// the same class — the self-test has to be able to say "the develop canvas
    /// is not in the window" while the loupe is up.
    static let loupeCanvasIdentifier = "loupe-canvas"

    private func makeBareCanvas() -> CanvasNSView {
        guard let service else {
            // No Metal: hand back a stub so the app still shows its error.
            let device = MTLCreateSystemDefaultDevice()!
            return CanvasNSView(device: device, commandQueue: device.makeCommandQueue()!)
        }
        let view = CanvasNSView(device: service.metal.device,
                                commandQueue: service.metal.commandQueue)
        view.handler = self
        view.isHDREnabled = !hdrSuppression.isSuppressed
        return view
    }

    /// The canvas the zoom commands and the zoom percentage belong to: the
    /// loupe's while the Library is showing one, the develop view's otherwise.
    private var activeCanvas: CanvasNSView? {
        (mode == .library && browser.ownsCanvas) ? loupeCanvas : canvas
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
        // Never in a self-test: the file the *real* user last had open is
        // remembered in a preference that `CFFIXED_USER_HOME` does not
        // redirect, so reopening it here silently imports it into the
        // throwaway library the test is measuring — see
        // `SelfTest.startIfRequested`. A test that wants a document is given
        // one on the command line.
        guard !SelfTest.isRequested else { return }
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
        openChosenFile(url)
    }

    /// Everything File › Open… does once the panel has answered.
    ///
    /// Split out because `NSOpenPanel.runModal` cannot be answered from inside
    /// the process, so the self-test supplies the panel's *result* and drives
    /// the production path from here — the same arrangement the Import window's
    /// source panel already has.
    func openChosenFile(_ url: URL) {
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
        // The probe below is what fills these in, and it is asynchronous: left
        // standing they would name the *previous* photo's camera and lens for
        // as long as the new file takes to open.
        cameraDescription = ""
        lensDescription = ""
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
                let lensMake = info.lensMake ?? ""
                let lensModel = info.lensModel ?? ""
                self.lensDescription = lensModel.isEmpty
                    ? ""
                    : "\(lensMake) \(lensModel)".trimmingCharacters(in: .whitespaces)
            }
        }
        requestRender(force: true)
    }

    /// "Grayroom — Default Library", or the library's path when it is not the
    /// default one (`GRAYROOM_LIBRARY`).
    var windowTitle: String {
        guard let library else { return "Grayroom" }
        let isDefault = (try? Library.defaultURL().standardizedFileURL.path)
            == library.url.standardizedFileURL.path
        return "Grayroom — " + (isDefault ? "Default Library" : library.url.path)
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
        service.renderPreview(input: input, edit: hdrSuppression.displayEdit(edit),
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
        if let canvas {
            canvas.imageTexture = showBeforeAfter
                ? (beforeTexture ?? currentTexture) : currentTexture
            canvas.coverageTexture = coverageTexture
            canvas.showOverlay = showMaskOverlay && coverageTexture != nil && !showBeforeAfter
        }
        // The same frame is what the loupe shows for a developed photo — see
        // `pushLoupeRender`, which decides whether this one is that photo's.
        pushLoupeRender()
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
                    // The lookup is what the loupe was waiting for: with the
                    // development in hand, an already-finished render of it is
                    // this photo's picture.
                    self.pushLoupeRender()
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

    func zoomToFit() { activeCanvas?.zoomToFit() }
    func zoomToActualSize() { activeCanvas?.zoomToActualSize() }

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
        export(to: outputURL)
    }

    /// Everything Export does once the save panel has answered — see
    /// `openChosenFile` for why the panel and the work it starts are two
    /// methods.
    func export(to outputURL: URL) {
        guard let service, let url = imageURL else { return }
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
        // The loupe is read-only: it draws the same canvas, so the same keys
        // reach it, and the ones that would edit something are refused here
        // rather than in the view — the view is shared.
        if mode == .library {
            switch command {
            case .fit: zoomToFit()
            case .actualSize: zoomToActualSize()
            case .colorLabel(let raw):
                if let color = ColorLabel(rawValue: raw) { toggleColorLabel(color) }
            case .toggleBrush, .toggleTargeted, .sizeStep, .featherStep:
                break
            }
            return
        }
        switch command {
        case .toggleBrush:
            tool = (tool == .brush) ? .pan : .brush
        case .toggleTargeted:
            tool = (tool == .targeted) ? .pan : .targeted
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
        // "Before" is a comparison against an edit, and the loupe is not
        // editing anything.
        guard mode == .develop else { return }
        showBeforeAfter = held
    }
}
