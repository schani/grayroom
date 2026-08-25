import Foundation

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
    /// A photo contributes its **first location that is still on disk**. The
    /// library keeps every path it has ever seen a photo at, and the first of
    /// them is not necessarily the one that is there now; one whose files have
    /// all moved away contributes nothing, because there is no file to hand
    /// over.
    public static func files(
        for ids: [Int64],
        from photos: [CatalogPhoto],
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [File] {
        let wanted = Set(ids)
        return photos.filter { wanted.contains($0.id) }.compactMap { photo in
            photo.locations.first(where: exists).map {
                File(id: photo.id, url: URL(fileURLWithPath: $0))
            }
        }
    }
}
