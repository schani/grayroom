import Foundation
import GrayroomCore

/// What an edit change costs.
///
/// The whole interactive loop hangs off this: white balance is applied inside
/// `CIRAWFilter` (see `ImageDecoder`), so temp/tint are the *only* edit fields
/// that force a re-decode. Everything else re-runs the Metal pipeline on the
/// already-decoded linear texture, which is the cheap path.
public enum RenderInvalidation: Int, Comparable, Sendable {
    case none = 0
    case pipeline = 1
    case decode = 2

    public static func < (a: RenderInvalidation, b: RenderInvalidation) -> Bool {
        a.rawValue < b.rawValue
    }

    public static func between(_ old: EditState, _ new: EditState) -> RenderInvalidation {
        if old.whiteBalance != new.whiteBalance { return .decode }
        if old != new { return .pipeline }
        return .none
    }

    public mutating func merge(_ other: RenderInvalidation) {
        self = max(self, other)
    }
}

/// Identity of a decoded texture: the same key always yields the same pixels, so
/// a cache hit lets a slider drag skip the decode entirely.
///
/// `nil` temperature/tint mean "as shot", which is a *different* key from the
/// numerically equal explicit values only in principle — `ImageDecoder` leaves the
/// filter untouched when both are nil — so they are kept distinct here too.
public struct DecodeKey: Hashable, Sendable {
    public let path: String
    public let temperature: Double?
    public let tint: Double?
    public let maxDimension: Int?

    public init(url: URL, edit: EditState, maxDimension: Int?) {
        self.path = url.standardizedFileURL.path
        self.temperature = edit.whiteBalance.temperature
        self.tint = edit.whiteBalance.tint
        self.maxDimension = maxDimension
    }
}
