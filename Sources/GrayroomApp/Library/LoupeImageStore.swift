import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomUI

/// The camera's own picture of one photo, at loupe resolution.
///
/// # What it is for
///
/// A photo that has never been developed is shown as the camera's embedded
/// preview — the same rule the grid follows (`PreviewBuilder`), and the reason
/// an unedited frame looks like the colour picture the camera made rather than
/// this app's black-and-white default. It is read here at loupe size rather
/// than at the grid's 512 px, because every camera embeds a preview big enough
/// to fill a window and demosaicing a frame nobody has edited would cost a
/// second to show the same picture.
///
/// A photo *with* a development does not come through here at all: the loupe
/// runs the real pipeline over it, through the same render loop the develop
/// view uses (`AppModel.loadLoupeImage`), which is what makes the loupe zoom,
/// show EDR, and cost nothing at all when the photo is the one just developed.
///
/// # Why a cache and why six
///
/// The arrow keys walk the grid one photo at a time, and a walk back along the
/// row the user just came down must not re-read anything. Six entries is a
/// screenful of stepping in either direction; at 2560 px they are on the order
/// of 25 MB each, which is the reason it is six and not sixty.
///
/// # Threading
///
/// Called on the main thread; every completion lands there. The read itself is
/// on a queue of its own.
final class LoupeImageStore {
    /// The long edge to load at. Above a Retina window's own pixel count, so
    /// fitting the image into the content area never scales it up.
    static let maxDimension = 2560
    /// How many pictures to keep.
    static let capacity = 6

    private var entries: [Int64: CGImage] = [:]
    /// Least recently used first.
    private var order: [Int64] = []
    private var pending: [Int64: [(CGImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "grayroom.loupe", qos: .userInitiated)

    /// What the store can answer without any work — what the loupe draws on its
    /// first pass, if it is lucky.
    func cached(_ photo: CatalogPhoto) -> CGImage? {
        value(for: photo.id)
    }

    /// The camera's picture, from memory when it is there and from the file
    /// otherwise.
    func image(for photo: CatalogPhoto,
               maxDimension: Int = LoupeImageStore.maxDimension,
               completion: @escaping (CGImage?) -> Void) {
        let key = photo.id
        if let hit = value(for: key) {
            completion(hit)
            return
        }
        guard let url = photo.url else {
            completion(nil)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        queue.async { [weak self] in
            let image = EmbeddedPreview.thumbnail(url: url, maxPixelSize: maxDimension)
            DispatchQueue.main.async { self?.deliver(image, for: key) }
        }
    }

    // MARK: - Private

    private func deliver(_ image: CGImage?, for key: Int64) {
        if let image { store(image, for: key) }
        let waiting = pending.removeValue(forKey: key) ?? []
        for callback in waiting { callback(image) }
    }

    private func value(for key: Int64) -> CGImage? {
        guard let image = entries[key] else { return nil }
        touch(key)
        return image
    }

    private func store(_ image: CGImage, for key: Int64) {
        entries[key] = image
        touch(key)
        while order.count > LoupeImageStore.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    private func touch(_ key: Int64) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
