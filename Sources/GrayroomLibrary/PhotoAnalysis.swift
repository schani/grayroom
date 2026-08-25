import CoreGraphics
import Foundation
import GrayroomCore
import Vision

/// What Vision says about a picture: how good it looks, and what it looks like.
///
/// `aestheticScore` is `CalculateImageAestheticsScoresRequest`'s
/// `overallScore`, −1…1. `featurePrint` is a `FeaturePrintObservation` encoded
/// whole (see `PhotoAnalyzer.encode`), because the only way back to one is its
/// own `Codable` conformance — there is no public initializer that takes the
/// float vector, and `distance(to:)` is a method on the observation.
public struct PhotoAnalysis: Equatable, Sendable {
    public var aestheticScore: Double
    public var featurePrint: Data

    public init(aestheticScore: Double, featurePrint: Data) {
        self.aestheticScore = aestheticScore
        self.featurePrint = featurePrint
    }
}

public enum PhotoAnalysisError: Error, CustomStringConvertible {
    case unavailable
    case noImage(URL)

    public var description: String {
        switch self {
        case .unavailable: return "image analysis needs macOS 15 or later"
        case .noImage(let url): return "no readable preview in \(url.path)"
        }
    }
}

/// The culling aids: Vision's aesthetics score and image feature print, both
/// computed from a small decoded image and never from a full RAW decode.
///
/// # Threading
///
/// `analyze` is synchronous and blocks its caller, like every other operation
/// in this target — the importer runs on a background queue of its own and the
/// CLI has no run loop to yield to. Never call it on the main thread.
public enum PhotoAnalyzer {
    /// The size the analysis sees. The same 512 px the grid's previews use, so
    /// a photo that has a preview has already paid for this decode.
    public static let previewPixelSize = 512

    /// How far apart two feature prints may be and still be the same picture.
    ///
    /// Measured on `testdata/`: the same frame re-exposed, cropped by a fifth,
    /// halved in size, or converted to black and white lands between 0.015 and
    /// 0.51 of its original, while the closest pair of *different* photographs
    /// in that folder is 0.83 apart. 0.6 sits between the two with room on both
    /// sides.
    public static let defaultSimilarityThreshold = 0.6

    public static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Aesthetics and feature print for one decoded image.
    public static func analyze(image: CGImage) throws -> PhotoAnalysis {
        guard #available(macOS 15.0, *) else { throw PhotoAnalysisError.unavailable }
        let input = UnsafeBox(image)
        return try blocking { try await analyze(image: input.value) }
    }

    /// The same, from the file's embedded preview — the cheap thumbnail path,
    /// never the RAW decoder.
    public static func analyze(url: URL) throws -> PhotoAnalysis {
        guard let image = EmbeddedPreview.thumbnail(url: url, maxPixelSize: previewPixelSize)
        else { throw PhotoAnalysisError.noImage(url) }
        return try analyze(image: image)
    }

    /// How far apart two stored feature prints are; 0 is the same picture.
    public static func distance(_ a: Data, _ b: Data) throws -> Double {
        guard #available(macOS 15.0, *) else { throw PhotoAnalysisError.unavailable }
        return try decode(a).distance(to: decode(b))
    }

    @available(macOS 15.0, *)
    static func analyze(image: CGImage) async throws -> PhotoAnalysis {
        let scores = try await CalculateImageAestheticsScoresRequest().perform(on: image)
        let print = try await GenerateImageFeaturePrintRequest().perform(on: image)
        return PhotoAnalysis(aestheticScore: Double(scores.overallScore),
                             featurePrint: try encode(print))
    }

    /// JSON, because `FeaturePrintObservation` is `Codable` and nothing else
    /// rebuilds one. Measured: 4.3 kB per photo for a 768-element print, and a
    /// round trip is bit-exact (`distance` to the decoded copy is 0).
    @available(macOS 15.0, *)
    static func encode(_ observation: FeaturePrintObservation) throws -> Data {
        try JSONEncoder().encode(observation)
    }

    @available(macOS 15.0, *)
    static func decode(_ data: Data) throws -> FeaturePrintObservation {
        try JSONDecoder().decode(FeaturePrintObservation.self, from: data)
    }

    /// Runs an async body to completion on the calling thread's behalf.
    ///
    /// Vision's Swift API is async-only and this target is synchronous
    /// throughout, so there is one bridge and it is here.
    private static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let result = UnsafeBox<Result<T, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result.value = .success(try await body()) } catch { result.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.value!.get()
    }
}

/// Hands a value across the concurrency boundary the semaphore already
/// serializes.
private final class UnsafeBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Nearest neighbours and near-duplicate groups over a set of stored feature
/// prints.
///
/// Pure and database-free so the linkage rule can be tested against distances
/// that were written by hand rather than by a neural network.
public struct FeaturePrintIndex {
    public let ids: [Int64]
    private let prints: [Int64: Data]

    public init(_ entries: [(id: Int64, featurePrint: Data)]) {
        ids = entries.map(\.id)
        prints = Dictionary(entries.map { ($0.id, $0.featurePrint) },
                            uniquingKeysWith: { _, last in last })
    }

    public var isEmpty: Bool { ids.isEmpty }

    public func featurePrint(of id: Int64) -> Data? { prints[id] }

    public func distance(_ a: Int64, _ b: Int64) throws -> Double {
        guard let x = prints[a], let y = prints[b] else { throw LibraryError.noSuchPhoto(a) }
        return try PhotoAnalyzer.distance(x, y)
    }

    /// Every other photo within `threshold` of this one, nearest first. The
    /// photo itself is never in the answer.
    public func nearest(to id: Int64, threshold: Double,
                        limit: Int? = nil) throws -> [(id: Int64, distance: Double)] {
        guard let subject = prints[id] else { throw LibraryError.noSuchPhoto(id) }
        var found: [(id: Int64, distance: Double)] = []
        for other in ids where other != id {
            guard let data = prints[other] else { continue }
            let distance = try PhotoAnalyzer.distance(subject, data)
            if distance <= threshold { found.append((other, distance)) }
        }
        found.sort { $0.distance == $1.distance ? $0.id < $1.id : $0.distance < $1.distance }
        if let limit, found.count > limit { found.removeSubrange(limit...) }
        return found
    }

    /// Groups of two or more photos joined by single linkage: A and C are in
    /// one group when A is near B and B is near C, even if A and C are not near
    /// each other. That is what a burst of frames looks like.
    public func duplicateGroups(threshold: Double) throws -> [[Int64]] {
        try FeaturePrintIndex.singleLinkageGroups(ids, threshold: threshold) { a, b in
            try distance(a, b)
        }
    }

    /// The linkage itself, over any distance function — union-find across every
    /// pair under the threshold. Groups come back sorted by id, and in the
    /// order of their lowest id.
    public static func singleLinkageGroups(
        _ ids: [Int64], threshold: Double,
        distance: (Int64, Int64) throws -> Double) rethrows -> [[Int64]] {
        var parent = Array(0..<ids.count)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var walk = i
            while parent[walk] != root {
                let next = parent[walk]
                parent[walk] = root
                walk = next
            }
            return root
        }
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                guard try distance(ids[i], ids[j]) <= threshold else { continue }
                let (a, b) = (find(i), find(j))
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        var groups: [Int: [Int64]] = [:]
        for i in 0..<ids.count { groups[find(i), default: []].append(ids[i]) }
        return groups.values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }
}
