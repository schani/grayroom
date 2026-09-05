import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomLibrary
import GrayroomUI
import ImageIO
import UniformTypeIdentifiers

/// Which picture a photo is supposed to be showing.
///
/// A photo with no development shows the camera's embedded preview; a photo with
/// one shows *that* development, rendered. The fingerprint is carried in the
/// case rather than compared separately so that "is what I have in memory still
/// right" is one `==`.
enum PreviewKind: Equatable {
    case embedded
    case rendered(Data)

    init(developmentFingerprint: Data?) {
        self = developmentFingerprint.map(PreviewKind.rendered) ?? .embedded
    }

    var source: PreviewSource {
        switch self {
        case .embedded: return .embedded
        case .rendered: return .rendered
        }
    }

    var fingerprint: Data? {
        switch self {
        case .embedded: return nil
        case .rendered(let f): return f
        }
    }
}

/// The library grid's pictures: `NSCache` in front, `previews.sqlite` behind,
/// and the decoder or the whole pipeline behind that.
///
/// # Development-aware
///
/// The grid shows what the photo *looks like*, which for a developed photo is
/// not what the camera's embedded JPEG says. So a preview is one of two things —
/// the embedded preview for a photo with no development, this app's pipeline run
/// over development #1 for a photo with one — and the row remembers which,
/// together with the `EditState.fingerprint` it was rendered from. Saving an
/// edit moves that fingerprint, the stored preview stops matching, and the cell
/// rebuilds. Deleting the development moves it back to `nil` and the cell falls
/// back to the embedded preview, by the same rule and with no code of its own.
///
/// # Why three levels
///
/// A rendered preview costs a full RAW decode — the better part of a second for
/// a 100 MP frame — so it is stored, in `previews.sqlite`, at 512 px. The
/// embedded ones are stored in the same place for the same reason as before: an
/// embedded-preview read of a file on an external card is milliseconds at best
/// and can be a spin-up. `NSCache` in front of that exists because scrolling
/// re-asks for the same cells constantly and a 512 px JPEG decode is still a
/// millisecond or two; its cost limit is the images' real footprint, so 256 MB
/// is a few hundred previews and the system evicts under memory pressure without
/// any policy of ours.
///
/// # Order and contention
///
/// Requests are coalesced per photo id, and the queue is a **stack**: the newest
/// request is served first, because the newest request is the one from the cell
/// the user is looking at right now. A flick through ten thousand frames
/// therefore does not have to work through everything it flew past before it
/// gets to where it landed — and `isStillNeeded`, polled on the worker, throws
/// away the ones it flew past.
///
/// Rendered previews are held back while the user is editing (`isEditingActive`)
/// so that a grid rebuild triggered by an autosave cannot land on the GPU in the
/// middle of a slider drag. Embedded ones are not: they touch no GPU at all.
///
/// # Threading
///
/// `image(for:isStillNeeded:completion:)` is called on the main thread and its
/// completion always lands there. One job runs at a time.
final class PreviewBuilder {
    /// The long edge of a stored preview. Big enough for the largest grid cell
    /// at 2× and for a loupe view later; small enough that a whole library of
    /// them is tens of megabytes.
    static let pixelSize = 512
    private static let jpegQuality: Double = 0.85
    /// ~400 previews at 512×512 RGBA.
    private static let memoryLimitBytes = 256 * 1024 * 1024
    /// How long to sit on a rendered preview after the last edit, and how long
    /// to wait before asking again.
    private static let editingBackoff: TimeInterval = 0.5

    private let memory = NSCache<NSNumber, CGImage>()
    /// What the cached image is a picture of. `NSCache` may drop the image
    /// without telling us, which only makes this stale, not wrong: the lookup
    /// asks the cache too.
    private var memoryKind: [Int64: PreviewKind] = [:]
    private let queue = DispatchQueue(label: "grayroom.previews", qos: .utility)

    /// Where the "Building previews" row comes from. Replaced by `AppModel` with
    /// the app's own; the default keeps this class usable on its own.
    var tasks = TaskCenter()
    /// The developments to render from. Without it every photo falls back to its
    /// embedded preview.
    var library: Library?
    /// Where the JPEGs live. Without it every preview is rebuilt every launch.
    var previews: PreviewStore?
    /// Renders one photo through the real pipeline, off the interactive queue.
    /// `nil` back means the app has no Metal.
    var render: ((URL, EditState, @escaping (CGImage?) -> Void) -> Void)?
    /// Whether the user is editing right now, in which case a rendered preview
    /// waits its turn.
    var isEditingActive: () -> Bool = { false }

    private struct Request {
        let id: Int64
        /// The photo's content hash — how `previews.sqlite` keys its rows, so
        /// that a re-import under a new rowid still finds its picture.
        let hash: Data
        let url: URL?
        let kind: PreviewKind
    }

    private var taskID: TaskCenter.BackgroundTask.ID?
    /// Completions waiting on a job, per photo id.
    private var pending: [Int64: [(CGImage?) -> Void]] = [:]
    /// What each pending job is for, and the order to serve them in — newest
    /// last, popped from the back.
    private var requests: [Int64: Request] = [:]
    private var order: [Int64] = []
    /// Per photo, the caller's "is this cell still on screen" test.
    private var isStillNeeded: [Int64: () -> Bool] = [:]
    private var inFlight = false
    private var retryScheduled = false
    /// How many jobs this run of the queue has been given and finished; the pair
    /// is the task's total/completed and both reset when it drains.
    private var enqueued = 0
    private var completed = 0
    /// Photos nothing could produce a picture for — asking again on every scroll
    /// would re-open a missing or broken file forever.
    private var failed: Set<Int64> = []
    /// Photos whose *render* failed. Their embedded preview is still fine, and
    /// showing the undeveloped picture beats showing a warning triangle.
    private var renderFailed: Set<Int64> = []

    init() {
        memory.totalCostLimit = PreviewBuilder.memoryLimitBytes
    }

    /// What the cache can answer without any work — what a cell draws on its
    /// first body evaluation. `nil` when what is cached is a picture of an older
    /// edit.
    func cached(_ photo: CatalogPhoto) -> CGImage? {
        guard memoryKind[photo.id] == PreviewKind(developmentFingerprint:
                                                    photo.developmentFingerprint)
        else { return nil }
        return memory.object(forKey: NSNumber(value: photo.id))
    }

    /// The preview for one photo, from memory if it is there and from the
    /// background otherwise.
    ///
    /// `isStillNeeded` is polled on the worker immediately before the expensive
    /// part; returning `false` abandons the request (the completion is called
    /// with `nil`, and nothing is cached).
    func image(for photo: CatalogPhoto,
               isStillNeeded: @escaping () -> Bool = { true },
               completion: @escaping (CGImage?) -> Void) {
        let id = photo.id
        if let image = cached(photo) {
            completion(image)
            return
        }
        if failed.contains(id) {
            completion(nil)
            return
        }
        let request = Request(id: id, hash: photo.hash, url: photo.url,
                              kind: PreviewKind(developmentFingerprint:
                                                  photo.developmentFingerprint))

        if pending[id] != nil {
            pending[id]?.append(completion)
            // Asked for again means looked at again: move it to the front of
            // the queue, and adopt the newer edit if there is one.
            requests[id] = request
            order.removeAll { $0 == id }
            order.append(id)
            self.isStillNeeded[id] = isStillNeeded
            return
        }
        pending[id] = [completion]
        requests[id] = request
        order.append(id)
        self.isStillNeeded[id] = isStillNeeded
        enqueued += 1
        if taskID == nil {
            taskID = tasks.begin(title: "Building previews", total: enqueued)
        }
        tasks.update(taskID!, completed: completed, total: enqueued)
        pump()
    }

    /// Whether this photo has no picture to show *and never will* — no file at
    /// all, or one nothing could read. That is the exclamation badge; a preview
    /// that simply has not arrived yet is not this.
    func isMissing(_ photo: CatalogPhoto) -> Bool {
        photo.firstLocation == nil || failed.contains(photo.id)
    }

    /// Development #1 was just written: drop what is in memory and build the new
    /// picture now, so that coming back to the grid shows the edit rather than
    /// the frame before it.
    func invalidate(photoID: Int64) {
        memory.removeObject(forKey: NSNumber(value: photoID))
        memoryKind[photoID] = nil
        renderFailed.remove(photoID)
        failed.remove(photoID)
    }

    // MARK: - The worker

    private func pump() {
        guard !inFlight, !order.isEmpty else { return }
        // Newest first, skipping anything that has to wait for the render loop.
        var index = order.count - 1
        while index >= 0 {
            guard let request = requests[order[index]] else {
                order.remove(at: index)
                index -= 1
                continue
            }
            if request.kind == .embedded || !isEditingActive() { break }
            index -= 1
        }
        guard index >= 0, let request = requests[order[index]] else {
            scheduleRetry()
            return
        }
        order.remove(at: index)
        let id = request.id
        let stillNeeded = isStillNeeded[id] ?? { true }
        inFlight = true

        guard let url = request.url else {
            deliver(nil, for: request, remember: true)
            return
        }
        let store = previews
        let library = self.library
        queue.async { [weak self] in
            guard let self else { return }
            guard stillNeeded() else {
                DispatchQueue.main.async { self.deliver(nil, for: request, remember: false) }
                return
            }
            // 1. The store, when it holds a picture of the right thing.
            if let row = try? store?.preview(for: request.hash),
               row.isCurrent(developmentFingerprint: request.kind.fingerprint),
               let image = PreviewBuilder.decodeJPEG(row.jpeg) {
                SelfTest.note("preview \(id): \(row.source) from previews.sqlite")
                DispatchQueue.main.async { self.deliver(image, for: request, remember: true) }
                return
            }
            // 2. Build it. The embedded path is ImageIO and finishes here; the
            //    rendered one needs the GPU, which lives on the main thread's
            //    side of the app, so it goes back and comes round again.
            switch request.kind {
            case .embedded:
                SelfTest.note("preview \(id): building an embedded preview")
                let image = EmbeddedPreview.thumbnail(url: url,
                                                      maxPixelSize: PreviewBuilder.pixelSize)
                let stored = image.flatMap { PreviewBuilder.store($0, for: request, in: store) }
                DispatchQueue.main.async { self.deliver(stored, for: request, remember: true) }
            case .rendered:
                let edit = (try? library?.developments(for: id))??.first?.edit
                DispatchQueue.main.async {
                    self.startRender(request, url: url, edit: edit)
                }
            }
        }
    }

    /// The second half of a rendered preview: the pipeline run, then the encode
    /// and the store write back on the worker.
    private func startRender(_ request: Request, url: URL, edit: EditState?) {
        guard let render, let edit, !renderFailed.contains(request.id) else {
            fallBackToEmbedded(request, url: url)
            return
        }
        // What was actually read, which is what the row must say it is: the
        // development may have moved since the catalog snapshot was taken.
        let rendered = Request(id: request.id, hash: request.hash, url: request.url,
                               kind: .rendered(edit.fingerprint))
        let store = previews
        SelfTest.note("preview \(request.id): rendering development #1")
        render(url, edit) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.renderFailed.insert(request.id)
                self.fallBackToEmbedded(request, url: url)
                return
            }
            self.queue.async {
                let stored = PreviewBuilder.store(image, for: rendered, in: store)
                DispatchQueue.main.async {
                    self.deliver(stored, for: request, remember: true, renderedKind: rendered.kind)
                }
            }
        }
    }

    /// No development to render, or a render that would not run: the camera's
    /// own picture is still better than an empty cell. It is not written to the
    /// store, because the row would then claim to be this photo's preview and
    /// the next launch would never build the real one — and it is delivered
    /// under the *rendered* kind so that scrolling past the cell again does not
    /// re-attempt the render that just failed.
    private func fallBackToEmbedded(_ request: Request, url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            let image = EmbeddedPreview.thumbnail(url: url, maxPixelSize: PreviewBuilder.pixelSize)
            DispatchQueue.main.async { self.deliver(image, for: request, remember: true) }
        }
    }

    /// Match the queued request separately from the edit the database supplied.
    private func deliver(_ image: CGImage?, for request: Request, remember: Bool,
                         renderedKind: PreviewKind? = nil) {
        let id = request.id
        inFlight = false
        // A newer request for this photo arrived while this one was running —
        // an autosave moved the fingerprint mid-build. What just finished is a
        // picture of the wrong edit, so it goes back in the queue instead of
        // being handed to a cell that would have no reason to ask again.
        if let current = requests[id], current.kind != request.kind {
            if !order.contains(id) { order.append(id) }
            pump()
            return
        }
        if let image {
            memory.setObject(image, forKey: NSNumber(value: id),
                             cost: PreviewBuilder.cost(image))
            memoryKind[id] = renderedKind ?? request.kind
        } else if remember {
            // Remembered for the session: a file that is not there now will not
            // be there on the next scroll either, and re-asking on every cell
            // reuse is how a broken photo costs more than a good one.
            failed.insert(id)
        }
        let waiting = pending.removeValue(forKey: id) ?? []
        requests[id] = nil
        isStillNeeded[id] = nil
        order.removeAll { $0 == id }
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
        pump()
    }

    /// Everything left in the queue is waiting for the render loop to go quiet.
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewBuilder.editingBackoff) {
            [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.pump()
        }
    }

    // MARK: - JPEG

    static func cost(_ image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, 1)
    }

    /// Encodes, writes the row, and hands back the image the caller should show.
    /// Returns the image even when the write fails — a preview that could not be
    /// stored is still a preview.
    private static func store(_ image: CGImage, for request: Request,
                              in store: PreviewStore?) -> CGImage? {
        let sRGB = sRGBImage(image)
        guard let data = jpegData(from: sRGB) else { return sRGB }
        try? store?.store(hash: request.hash,
                          source: request.kind.source,
                          fingerprint: request.kind.fingerprint,
                          width: sRGB.width,
                          height: sRGB.height,
                          jpeg: data)
        return sRGB
    }

    /// Everything stored is sRGB, whatever the camera tagged its embedded
    /// preview with — so the grid draws one colour space and a stored preview
    /// can be compared with a freshly rendered one.
    private static func sRGBImage(_ image: CGImage) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
