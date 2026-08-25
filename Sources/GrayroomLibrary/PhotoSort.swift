import Foundation

/// What a list of photos is ordered by — Lightroom's View › Sort, reduced to
/// the three keys this app has.
///
/// It lives in the library target rather than in the UI because both orderings
/// are the same ordering: the CLI's `ls --sort` sorts in SQL, the grid sorts in
/// RAM, and a photo has to come out in the same place either way.
public enum PhotoSortKey: String, CaseIterable, Sendable {
    case captureTime = "capture"
    case fileName = "name"
    case aestheticScore = "score"

    /// The menu's wording, which is Lightroom's.
    public var title: String {
        switch self {
        case .captureTime: return "Capture Time"
        case .fileName: return "File Name"
        case .aestheticScore: return "Aesthetic Score"
        }
    }

    /// The `ORDER BY` clause, ties broken by row id so the order is total.
    ///
    /// An unscored photo sorts last in both directions: `NULL` is not a bad
    /// score, it is no score, and a list of the best frames should not open on
    /// the ones nobody has looked at yet.
    func orderBy(ascending: Bool) -> String {
        let direction = ascending ? "ASC" : "DESC"
        switch self {
        case .captureTime:
            return "photos.captured_at \(direction), photos.id \(direction)"
        case .fileName:
            return "photos.original_name COLLATE NOCASE \(direction), photos.id \(direction)"
        case .aestheticScore:
            return "photos.aesthetic_score IS NULL, photos.aesthetic_score \(direction), "
                + "photos.id \(direction)"
        }
    }
}
