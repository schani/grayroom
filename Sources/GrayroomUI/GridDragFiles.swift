import Foundation
import GrayroomLibrary

/// What a drag out of the photo grid hands over: the photos' own originals.
///
/// Lightroom drags files, not a private pasteboard type — dropping on the
/// Desktop or in another app gives you the RAWs themselves. Which photos go is
/// the grid's selection rule (drag one of the selected cells and the whole
/// selection travels; drag a cell that is not selected and only it does), and
/// that part is the drag container's; what is here is the other half: turning
/// photo ids into files.
public enum GridDragFiles {
    /// One photo's original, on its way out of the grid.
    public struct File: Equatable, Sendable {
        public let id: Int64
        public let url: URL
    }

    /// The originals behind `ids`, in the order the grid draws them rather than
    /// the order the ids arrived in — a multi-photo drop should land in the
    /// order it was picked up.
    ///
    public static func files(
        for ids: [Int64],
        from photos: [CatalogPhoto],
        originals: OriginalStorage
    ) throws -> [File] {
        let wanted = Set(ids)
        return try photos.filter { wanted.contains($0.id) }.map { photo in
            File(id: photo.id,
                 url: try originals.localURL(hash: photo.hash, originalName: photo.originalName))
        }
    }
}
