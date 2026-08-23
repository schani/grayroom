import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomUI
import ImageIO
import UniformTypeIdentifiers

/// Two levels of thumbnail cache for the library grid: `NSCache` in front,
/// JPEGs on disk behind.
///
/// # Why both
///
/// The expensive step is reaching the file at all — an embedded-preview read of
/// a 100 MB RAW on an external card is milliseconds *at best* and can be a
/// spin-up. Once paid, the answer is a 256 px picture that never changes,
/// because the key is the file's SHA-256: the same bytes always produce the
/// same thumbnail, and different bytes are a different photo. So it is written
/// to `~/Library/Caches/Grayroom/thumbnails/<hash>.jpg`, where it survives
/// relaunches and where the system may evict it under disk pressure — a cache
/// directory is exactly the right place for something reconstructible.
///
/// The memory level in front of it exists because scrolling re-asks for the
/// same cells constantly, and 256 px JPEG decode is still ~1 ms. `NSCache`'s
/// cost limit is set from the images' real footprint (`bytesPerRow × height`),
/// so 256 MB is about a thousand thumbnails, and the system evicts under memory
/// pressure without any policy of ours.
///
/// # Coalescing and cancellation
///
/// Requests are coalesced per photo id: ten cells asking for the same photo
/// while it is being built queue their completions behind the one job. And the
/// caller passes `isStillNeeded`, checked on the worker just before the
/// expensive part — the grid answers `false` for a cell that has been scrolled
/// off, so a fast flick through ten thousand frames does not leave a queue of
/// thousands of dead reads behind it.
///
/// # Threading
///
/// `thumbnail(for:isStillNeeded:completion:)` is called on the main thread and
/// its completion always lands on the main thread. The queue is serial: this is
/// disk-bound work, and running four of it in parallel against one SSD (or, in
/// the case that matters, one SD card) mostly buys thrash.
final class ThumbnailCache {
    /// The long edge asked of ImageIO. Matches the import grid's, so the two
    /// windows do not build two different pictures of the same file.
    static let pixelSize = 256
    private static let jpegQuality: Double = 0.85
    /// ~1000 thumbnails at 256×256 RGBA.
    private static let memoryLimitBytes = 256 * 1024 * 1024

    private let memory = NSCache<NSNumber, CGImage>()
    private let directory: URL
    private let queue = DispatchQueue(label: "grayroom.thumbnails", qos: .utility)
    private let fileManager = FileManager.default

    /// Where the "Building thumbnails" row comes from. Replaced by `AppModel`
    /// with the app's own, the way `ImportModel`'s is; the default keeps this
    /// class usable on its own.
    var tasks = TaskCenter()
    private var taskID: TaskCenter.BackgroundTask.ID?
    /// Completions waiting on a job that is already running, per photo id.
    private var pending: [Int64: [(CGImage?) -> Void]] = [:]
    /// How many jobs this run of the queue has been given and finished; the
    /// pair is the task's total/completed and both reset when it drains.
    private var enqueued = 0
    private var completed = 0
    /// Photos ImageIO could not produce a picture for — asking again on every
    /// scroll would re-open a missing or broken file forever.
    private var failed: Set<Int64> = []

    init(directory: URL? = nil) {
        self.directory = directory ?? ThumbnailCache.defaultDirectory()
        memory.totalCostLimit = ThumbnailCache.memoryLimitBytes
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    static func defaultDirectory() -> URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches
            .appendingPathComponent("Grayroom", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// What the cache can answer without any work — what a cell draws on its
    /// first body evaluation.
    func cached(_ id: Int64) -> CGImage? { memory.object(forKey: NSNumber(value: id)) }

    /// The thumbnail for one photo, from memory if it is there and from the
    /// background otherwise.
    ///
    /// `isStillNeeded` is polled on the worker immediately before the expensive
    /// read; returning `false` abandons the request (the completion is called
    /// with `nil`, and nothing is cached).
    func thumbnail(for photo: CatalogPhoto,
                   isStillNeeded: @escaping () -> Bool = { true },
                   completion: @escaping (CGImage?) -> Void) {
        let id = photo.id
        if let image = cached(id) {
            completion(image)
            return
        }
        if failed.contains(id) {
            completion(nil)
            return
        }
        // Already being built: ride along rather than reading the file twice.
        if pending[id] != nil {
            pending[id]?.append(completion)
            return
        }
        pending[id] = [completion]
        enqueued += 1
        if taskID == nil {
            taskID = tasks.begin(title: "Building thumbnails", total: enqueued)
        }
        tasks.update(taskID!, completed: completed, total: enqueued)

        let path = photo.firstLocation
        let cacheURL = self.cacheURL(forHashHex: photo.hashHexString)
        queue.async { [weak self] in
            guard let self else { return }
            guard isStillNeeded() else {
                DispatchQueue.main.async { self.deliver(nil, for: id, remember: false) }
                return
            }
            let image: CGImage?
            if let onDisk = ThumbnailCache.readJPEG(at: cacheURL) {
                image = onDisk
            } else if let path,
                      let built = EmbeddedPreview.thumbnail(
                          url: URL(fileURLWithPath: path),
                          maxPixelSize: ThumbnailCache.pixelSize) {
                ThumbnailCache.writeJPEG(built, to: cacheURL)
                image = built
            } else {
                image = nil
            }
            DispatchQueue.main.async { self.deliver(image, for: id, remember: true) }
        }
    }

    /// Whether this photo has no picture to show *and never will* — no path at
    /// all, or a path ImageIO could not read. That is the exclamation badge; a
    /// thumbnail that simply has not arrived yet is not this.
    func isMissing(_ photo: CatalogPhoto) -> Bool {
        photo.firstLocation == nil || failed.contains(photo.id)
    }

    // MARK: - Private

    private func deliver(_ image: CGImage?, for id: Int64, remember: Bool) {
        if let image {
            memory.setObject(image, forKey: NSNumber(value: id), cost: ThumbnailCache.cost(image))
        } else if remember {
            // Remembered for the session: a file that is not there now will not
            // be there on the next scroll either, and re-asking ImageIO on
            // every cell reuse is how a broken photo costs more than a good one.
            failed.insert(id)
        }
        let waiting = pending.removeValue(forKey: id) ?? []
        completed += 1
        if let taskID {
            if pending.isEmpty {
                tasks.finish(taskID)
                self.taskID = nil
                enqueued = 0
                completed = 0
            } else {
                tasks.update(taskID, completed: completed, total: enqueued)
            }
        }
        for callback in waiting { callback(image) }
    }

    private func cacheURL(forHashHex hex: String) -> URL {
        directory.appendingPathComponent(hex.isEmpty ? "unhashed" : hex)
            .appendingPathExtension("jpg")
    }

    static func cost(_ image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, 1)
    }

    private static func readJPEG(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
