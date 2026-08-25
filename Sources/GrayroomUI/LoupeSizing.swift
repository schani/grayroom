import CoreGraphics
import Foundation

/// How much of a photo's own resolution the loupe needs on screen.
public enum LoupeResolution: Hashable, Sendable {
    /// A picture whose longer edge is at most this many pixels — a decode
    /// capped at it, or an embedded preview read at it.
    case sized(longEdge: Int)
    /// The file's own pixels.
    case full

    /// The longer edge this resolution stands for, for a photo whose own is
    /// `native`.
    public func longEdge(native: Int) -> Int {
        switch self {
        case .sized(let edge): return native > 0 ? min(edge, native) : edge
        case .full: return native
        }
    }
}

/// What one loupe picture is a picture of: which photo, which development, at
/// what resolution.
///
/// The development is carried as its `EditState.fingerprint`, so "is the
/// picture I am holding still right" is one `==` — the same trick the grid's
/// `PreviewKind` plays. `nil` is a photo that has never been developed, whose
/// picture is the camera's own.
public struct LoupeRenderKey: Hashable, Sendable {
    public let photoID: Int64
    public let fingerprint: Data?
    public let resolution: LoupeResolution

    public init(photoID: Int64, fingerprint: Data?, resolution: LoupeResolution) {
        self.photoID = photoID
        self.fingerprint = fingerprint
        self.resolution = resolution
    }

    public var isFullResolution: Bool { resolution == .full }
}

/// How big a picture the loupe has to load for the zoom it is at.
///
/// The loupe draws one frame at a time and cannot crop, so the texture on the
/// canvas has to cover the whole photo. At Fit that means the view's own pixel
/// count and no more — rendering a hundred megapixels to fill a 3 MP window is
/// a second of work nobody can see. Past Fit the picture is being magnified,
/// and the only cure is the file's own pixels.
public enum LoupeSizing {
    /// A picture within this factor of what the zoom asks for is left alone.
    /// Reloading a hundred-megapixel frame because a window grew by a hundred
    /// points would cost seconds to fix a softness nobody can see.
    public static let slack: Double = 1.2

    /// Image pixels along the longer edge that drawing the frame at `zoom`
    /// needs before the picture has to be magnified. Never more than the photo
    /// has.
    public static func requiredLongEdge(imageLongEdge: Int, zoom: Double) -> Int {
        guard imageLongEdge > 0 else { return 0 }
        let wanted = Double(imageLongEdge) * max(zoom, 0)
        return min(imageLongEdge, max(1, Int(wanted.rounded(.up))))
    }

    /// What to load on the first pass: the picture the view can actually show.
    public static func initial(imageLongEdge: Int, zoom: Double) -> LoupeResolution {
        let required = requiredLongEdge(imageLongEdge: imageLongEdge, zoom: zoom)
        return required >= imageLongEdge ? .full : .sized(longEdge: required)
    }

    /// What to load *instead* of what is loaded, or `nil` when the picture in
    /// hand already has a pixel for every pixel the view is drawing.
    ///
    /// Two rungs and no more. While the frame is fitted the loupe holds exactly
    /// what the view can show, so a window that grows reloads at the new size;
    /// the moment the user zooms past Fit it goes straight to the file's own
    /// pixels, because a rung per zoom step would put another full decode
    /// behind every notch of a magnification they are only passing through.
    public static func upgrade(loaded: LoupeResolution, imageLongEdge: Int,
                               zoom: Double, fitZoom: Double,
                               slack: Double = LoupeSizing.slack) -> LoupeResolution? {
        guard imageLongEdge > 0, loaded != .full else { return nil }
        let have = loaded.longEdge(native: imageLongEdge)
        guard have < imageLongEdge else { return nil }
        let required = requiredLongEdge(imageLongEdge: imageLongEdge, zoom: zoom)
        guard Double(required) > Double(have) * slack else { return nil }
        // Still fitted: the window changed, not the zoom, so the answer is the
        // window's new size rather than the whole file.
        if zoom <= fitZoom * 1.0001, required < imageLongEdge {
            return .sized(longEdge: required)
        }
        return .full
    }
}

/// The loupe's pictures, keyed by what they are a picture of.
///
/// One full-resolution entry, ever: a hundred-megapixel frame is ~400 MB of
/// texture, and the only photo allowed to hold one is the one on screen. The
/// view-sized ones are a few megabytes each, and a walk back along the row the
/// user just came down must not re-render anything, so a handful stay.
///
/// Generic over the picture so the policy is testable without a GPU.
public struct LoupeImageCache<Value> {
    /// How many view-sized pictures to keep. Full-resolution ones are counted
    /// separately, and there is never more than one.
    public let capacity: Int

    private var entries: [LoupeRenderKey: Value] = [:]
    /// Least recently used first.
    private var order: [LoupeRenderKey] = []

    public init(capacity: Int = 4) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { entries.count }
    /// Least recently used first — the eviction order.
    public var keys: [LoupeRenderKey] { order }

    public mutating func value(for key: LoupeRenderKey) -> Value? {
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    /// The biggest picture of this photo the cache holds — what the loupe can
    /// put on screen in the turn of the run loop the arrow key was pressed in.
    public func best(photoID: Int64, fingerprint: Data?,
                     nativeLongEdge: Int) -> (key: LoupeRenderKey, value: Value)? {
        entries
            .filter { $0.key.photoID == photoID && $0.key.fingerprint == fingerprint }
            .max { a, b in
                a.key.resolution.longEdge(native: nativeLongEdge)
                    < b.key.resolution.longEdge(native: nativeLongEdge)
            }
            .map { (key: $0.key, value: $0.value) }
    }

    public mutating func store(_ value: Value, for key: LoupeRenderKey) {
        if key.isFullResolution {
            for other in order where other.isFullResolution && other != key { remove(other) }
        }
        entries[key] = value
        touch(key)
        evict()
    }

    /// A different photo is on screen: the full-resolution picture of anything
    /// else goes, now, because two of them is most of a gigabyte.
    public mutating func dropFullResolution(except photoID: Int64?) {
        for key in order where key.isFullResolution && key.photoID != photoID {
            remove(key)
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    // MARK: - Private

    private mutating func touch(_ key: LoupeRenderKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private mutating func remove(_ key: LoupeRenderKey) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    private mutating func evict() {
        var sized = order.filter { !$0.isFullResolution }
        while sized.count > capacity { remove(sized.removeFirst()) }
    }
}
