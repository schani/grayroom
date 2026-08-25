import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomUI

/// The camera's own picture of one photo, read off the file at the size the
/// loupe asked for.
///
/// # What it is for
///
/// A photo that has never been developed is shown as the camera made it — the
/// same rule the grid follows (`PreviewBuilder`), and the reason an unedited
/// frame looks like the colour picture the camera produced rather than this
/// app's black-and-white default. While the frame is fitted that picture is the
/// file's **embedded preview**, read at the view's own pixel count: every camera
/// embeds one big enough to fill a window, and demosaicing a frame nobody has
/// edited would cost a second to show the same picture.
///
/// Past Fit the embedded preview runs out of pixels and only the RAW decoder has
/// more, which is `RenderService.decodeCameraImage` — the GPU's side of the app,
/// not this one's.
///
/// A photo *with* a development does not come through here at all: the loupe
/// runs the real pipeline over it (`AppModel.loadLoupeImage`), which is what
/// gives it EDR and full resolution, neither of which an 8-bit `CGImage` can
/// carry.
///
/// # Threading
///
/// Called on the main thread; every completion lands there. The read itself is
/// on a queue of its own, and two requests for the same picture share one read.
/// Nothing is kept: what the loupe holds on to is the *texture* it made of the
/// picture, in `LoupeImageCache`, so a second cache here would be the same
/// megabytes twice.
final class LoupeImageStore {
    /// The long edge to read when nothing has said how big the view is — above
    /// a Retina window's own pixel count, so fitting the image into the content
    /// area never scales it up.
    static let defaultLongEdge = 2560

    private struct Key: Hashable {
        let photoID: Int64
        let longEdge: Int
    }

    private var pending: [Key: [(CGImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "grayroom.loupe", qos: .userInitiated)

    /// The camera's picture, at most `longEdge` pixels on its longer side.
    func image(for photo: CatalogPhoto, longEdge: Int,
               completion: @escaping (CGImage?) -> Void) {
        guard let url = photo.url else {
            completion(nil)
            return
        }
        let key = Key(photoID: photo.id, longEdge: longEdge)
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        queue.async { [weak self] in
            let image = EmbeddedPreview.thumbnail(url: url, maxPixelSize: longEdge)
            DispatchQueue.main.async { self?.deliver(image, for: key) }
        }
    }

    // MARK: - Private

    private func deliver(_ image: CGImage?, for key: Key) {
        let waiting = pending.removeValue(forKey: key) ?? []
        for callback in waiting { callback(image) }
    }
}
