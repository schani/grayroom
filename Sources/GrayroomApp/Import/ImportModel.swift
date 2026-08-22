import AppKit
import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomLibrary
import GrayroomUI
import Observation

/// One cell in the import grid: an `ImportEntry` plus the picture that arrives
/// for it later.
struct ImportItem: Identifiable {
    var entry: ImportEntry
    var thumbnail: CGImage?

    var id: URL { entry.url }
    var url: URL { entry.url }
    var filename: String { entry.filename }
    var captureDate: Date? { entry.captureDate }
    var status: ImportEntryStatus { entry.status }
    var alreadyImported: Bool { entry.alreadyImported }
    var checked: Bool { entry.checked }
}

/// The import window's state: what was found, what is ticked, what is
/// highlighted, and the background work that answers "is this already in the
/// library?".
///
/// Main-thread only by convention, like `AppModel`. The selection *rules* are
/// not here — they live in `GrayroomUI.ImportSelection`, which has no SwiftUI
/// dependency and can therefore be tested; this class is the thread discipline
/// and the I/O around them.
///
/// # The scan is two passes, and the split is the point
///
/// **Pass one** enumerates the folder and reads each file's EXIF capture date
/// from its header. That is a few hundred microseconds per file, so the grid is
/// on screen and usable almost immediately, with every cell `.pending`.
///
/// **Pass two** answers, per file, whether the library already has it — and
/// that means a **SHA-256 of the whole file**, because identity in this library
/// is the bytes, not the path. A path check would be cheap and wrong in both
/// directions: the same card mounted at a different volume path reads as new,
/// and a file replaced in place reads as old. So the honest answer costs a full
/// read of every file on the card, tens of gigabytes, and it dominates the
/// scan. Pass two therefore runs in scan order, batches its results, and stops
/// the moment the generation counter says the window has moved on — closing the
/// window must not leave a thread grinding through the rest of a card.
///
/// The hash it computes is kept in the entry, so the import that follows does
/// not pay for it twice.
///
/// # Batched main hops
///
/// Results are pushed to the main thread in groups of `resolutionBatchSize` or
/// every `resolutionBatchInterval`, whichever comes first. One hop per file
/// would be 2000 hops, each invalidating an `@Observable` property the whole
/// grid reads.
@Observable
final class ImportModel {
    /// Pixel size asked of ImageIO, independent of the display size — the
    /// slider then scales one decoded image instead of re-reading the card.
    private static let thumbnailPixelSize = 256
    private static let resolutionBatchSize = 8
    private static let resolutionBatchInterval: TimeInterval = 0.1

    static let minimumThumbnailSize: Double = 96
    static let maximumThumbnailSize: Double = 320

    // MARK: Injected

    /// Whether the library holds a photo with this SHA-256 (hex) that still has
    /// at least one location. Called on the scan queue, so whatever is behind
    /// it has to tolerate that (GRDB's pool does).
    var isHashImported: (String) -> Bool = { _ in false }
    /// Handed the checked entries — URL *and* hash — when the user presses
    /// Import.
    var onImport: ([ImportEntry]) -> Void = { _ in }
    /// Replaced by `AppModel` with the app's own; the default keeps this class
    /// usable on its own.
    var tasks = TaskCenter()

    // MARK: State

    private(set) var sourceURL: URL?
    var includeSubfolders = true {
        didSet { if oldValue != includeSubfolders { rescan() } }
    }
    private(set) var isScanning = false
    var thumbnailSize: Double = 160

    private var selection = ImportSelection()
    private var thumbnails: [URL: CGImage] = [:]

    private let queue = DispatchQueue(label: "grayroom.import", qos: .userInitiated)
    private let generation = GenerationCounter()

    /// One file's answer, as it travels from the scan queue to the main thread.
    private struct Resolution {
        var url: URL
        var status: ImportEntryStatus
        var hash: String?
        var thumbnail: CGImage?
    }

    // MARK: - Derived

    var items: [ImportItem] {
        selection.entries.map { ImportItem(entry: $0, thumbnail: thumbnails[$0.url]) }
    }

    var visibleItems: [ImportItem] {
        selection.visibleEntries.map { ImportItem(entry: $0, thumbnail: thumbnails[$0.url]) }
    }

    var totalCount: Int { selection.entries.count }
    var checkedCount: Int { selection.checkedCount }
    var checkedEntries: [ImportEntry] { selection.checkedEntries }
    var highlighted: Set<URL> { selection.highlighted }

    var sort: ImportSortOrder {
        get { selection.sort }
        set { selection.sort = newValue }
    }

    var hideImported: Bool {
        get { selection.hideImported }
        set { selection.hideImported = newValue }
    }

    // MARK: - Source

    /// The directory panel behind "Choose…" and File › Import….
    ///
    /// Files stay where they are — this is Lightroom's "Add", not "Copy" — so
    /// the panel only ever picks the folder to look in.
    static func presentSourcePanel(startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of RAW files to add to the library"
        panel.prompt = "Choose"
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func setSource(_ url: URL) {
        sourceURL = url
        rescan()
    }

    func chooseSource() {
        guard let url = ImportModel.presentSourcePanel(startingAt: sourceURL) else { return }
        setSource(url)
    }

    // MARK: - Scanning

    func rescan() {
        let mine = generation.next()
        selection.setEntries([])
        thumbnails = [:]
        guard let source = sourceURL else {
            isScanning = false
            return
        }
        isScanning = true
        let recursive = includeSubfolders
        let isHashImported = self.isHashImported
        let tasks = self.tasks
        // The counter is captured by value, not read back through `self`: the
        // scan runs off the main thread and `self` is a main-thread-only
        // `@Observable`.
        let counter = generation
        // Begun here, on the main thread, rather than once the file count is
        // known: the resolve loop polls this id to see whether it has been
        // cancelled, so it has to exist before any background work starts. The
        // total arrives with the first main hop and the bar is indeterminate
        // until then — which is honest, because enumerating a deep card is
        // itself not instant.
        let taskID = tasks.begin(title: "Scanning \(source.lastPathComponent)", cancellable: true)
        queue.async { [weak self] in
            let urls = (try? ImportScanner.scan(directory: source, recursive: recursive)) ?? []
            let entries = urls.map {
                ImportEntry(url: $0, captureDate: ImageDecoder.captureDate(url: $0))
            }
            DispatchQueue.main.async {
                guard let self, counter.current == mine else { return }
                self.selection.setEntries(entries)
                tasks.update(taskID, completed: 0, total: urls.count)
            }
            self?.resolve(urls, generation: mine, counter: counter,
                          tasks: tasks, taskID: taskID, isHashImported: isHashImported)
        }
    }

    /// Pass two: hash, ask the library, decode the preview — in scan order,
    /// batched, and abandoned the moment the window moves on or the task is
    /// cancelled.
    private func resolve(_ urls: [URL], generation mine: Int, counter: GenerationCounter,
                         tasks: TaskCenter, taskID: TaskCenter.BackgroundTask.ID,
                         isHashImported: (String) -> Bool) {
        var batch: [Resolution] = []
        var lastFlush = Date()
        var done = 0

        func flush() {
            guard !batch.isEmpty else { return }
            let payload = batch
            let finished = done
            batch = []
            lastFlush = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self, counter.current == mine else { return }
                for resolution in payload {
                    self.selection.resolve(resolution.url, status: resolution.status,
                                           hash: resolution.hash)
                    if let thumbnail = resolution.thumbnail {
                        self.thumbnails[resolution.url] = thumbnail
                    }
                }
                tasks.update(taskID, completed: finished,
                             detail: payload.last?.url.lastPathComponent)
            }
        }

        for url in urls {
            guard counter.current == mine, !tasks.isCancelled(taskID) else { break }
            let hash = try? FileHash.sha256HexString(of: url)
            let status: ImportEntryStatus
            if let hash, isHashImported(hash) {
                status = .alreadyImported
            } else {
                // A file that cannot even be read is offered as new; the import
                // will report the real error.
                status = .new
            }
            done += 1
            batch.append(Resolution(url: url, status: status, hash: hash,
                                    thumbnail: EmbeddedPreview.thumbnail(
                                        url: url,
                                        maxPixelSize: ImportModel.thumbnailPixelSize)))
            if batch.count >= ImportModel.resolutionBatchSize
                || Date().timeIntervalSince(lastFlush) >= ImportModel.resolutionBatchInterval {
                flush()
            }
        }
        flush()
        DispatchQueue.main.async { [weak self] in
            tasks.finish(taskID)
            guard let self, counter.current == mine else { return }
            self.isScanning = false
        }
    }

    // MARK: - Selection commands

    func isHighlighted(_ url: URL) -> Bool { selection.highlighted.contains(url) }

    func click(_ url: URL, modifiers: ImportClickModifiers) {
        selection.click(url, modifiers: modifiers)
    }

    func toggleCheckbox(_ url: URL) { selection.toggleCheckbox(url) }
    func setCheckedForHighlighted(_ value: Bool) {
        selection.setChecked(value, forHighlighted: true)
    }
    func toggleHighlighted() { selection.toggleHighlighted() }
    func checkAll() { selection.checkAll() }
    func uncheckAll() { selection.uncheckAll() }
    func moveHighlight(dx: Int, dy: Int, columns: Int) {
        selection.moveHighlight(dx: dx, dy: dy, columns: columns)
    }

    func stepThumbnailSize(_ steps: Int) {
        thumbnailSize = min(max(thumbnailSize + Double(steps) * 32,
                                ImportModel.minimumThumbnailSize),
                            ImportModel.maximumThumbnailSize)
    }

    // MARK: - Finishing

    func runImport() {
        let entries = checkedEntries
        guard !entries.isEmpty else { return }
        onImport(entries)
    }

    /// Stops the scan; the window keeps whatever it has, so reopening it does
    /// not always start from nothing.
    func stopScanning() {
        _ = generation.next()
        isScanning = false
    }
}

/// A counter readable from any thread, so background loops can notice that the
/// work they are doing has been superseded.
///
/// `NSLock` rather than a serial queue: this is read once per file inside a
/// loop whose other steps are a file hash and a JPEG decode, and a queue hop
/// per read would be the wrong shape of cost for a two-word check.
final class GenerationCounter {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
