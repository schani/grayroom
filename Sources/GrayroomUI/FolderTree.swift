import Foundation

public enum FolderSelection: Hashable, Sendable {
    case all
    /// A year, month, or day, identified as `yyyy`, `yyyy/MM`, or `yyyy/MM/dd`.
    case folder(path: String)
    case missing
}

public struct FolderNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let leafName: String
    public let parentChain: String?
    public let count: Int
    public let directCount: Int
    public let children: [FolderNode]

    public init(id: String, name: String, count: Int, directCount: Int,
                children: [FolderNode] = []) {
        self.id = id
        self.name = name
        self.leafName = name
        self.parentChain = nil
        self.count = count
        self.directCount = directCount
        self.children = children
    }
}

/// Viewer-local capture dates grouped as year/month/day.
public struct FolderTree: Equatable, Sendable {
    public let roots: [FolderNode]
    public let totalCount: Int
    /// Photos without a capture date.
    public let missingCount: Int
    private let entries: [Entry]

    private struct Entry: Equatable, Sendable {
        let id: Int64
        let day: String?
    }

    public init() {
        roots = []
        totalCount = 0
        missingCount = 0
        entries = []
    }

    public init(photos: [CatalogPhoto], calendar: Calendar = .current) {
        var entries: [Entry] = []
        var years: [Int: [Int: [Int: Int]]] = [:]
        var missing = 0
        for photo in photos {
            guard let date = photo.capturedAt else {
                entries.append(Entry(id: photo.id, day: nil))
                missing += 1
                continue
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else {
                entries.append(Entry(id: photo.id, day: nil))
                missing += 1
                continue
            }
            let id = String(format: "%04d/%02d/%02d", year, month, day)
            entries.append(Entry(id: photo.id, day: id))
            years[year, default: [:]][month, default: [:]][day, default: 0] += 1
        }

        self.entries = entries
        self.totalCount = photos.count
        self.missingCount = missing
        self.roots = years.keys.sorted(by: >).map { year in
            let months = years[year]!
            let children = months.keys.sorted(by: >).map { month in
                let days = months[month]!
                let dayNodes = days.keys.sorted(by: >).map { day in
                    FolderNode(id: String(format: "%04d/%02d/%02d", year, month, day),
                               name: String(format: "%02d", day), count: days[day]!,
                               directCount: days[day]!)
                }
                return FolderNode(id: String(format: "%04d/%02d", year, month),
                                  name: String(format: "%02d", month),
                                  count: days.values.reduce(0, +), directCount: 0,
                                  children: dayNodes)
            }
            return FolderNode(id: String(format: "%04d", year), name: String(year),
                              count: months.values.flatMap(\.values).reduce(0, +),
                              directCount: 0, children: children)
        }
    }

    public func photoIDs(for selection: FolderSelection) -> [Int64] {
        switch selection {
        case .all:
            return entries.map(\.id)
        case .missing:
            return entries.filter { $0.day == nil }.map(\.id)
        case .folder(let path):
            return entries.filter { entry in
                guard let day = entry.day else { return false }
                return day == path || day.hasPrefix(path + "/")
            }.map(\.id)
        }
    }

    public func node(at path: String) -> FolderNode? {
        func find(_ node: FolderNode) -> FolderNode? {
            if node.id == path { return node }
            return node.children.lazy.compactMap(find).first
        }
        return roots.lazy.compactMap(find).first
    }

    public var allNodes: [FolderNode] {
        func flatten(_ node: FolderNode) -> [FolderNode] {
            [node] + node.children.flatMap(flatten)
        }
        return roots.flatMap(flatten)
    }

}
