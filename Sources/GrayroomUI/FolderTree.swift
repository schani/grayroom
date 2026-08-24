import Foundation

/// What the Folders panel has selected, and therefore what the grid shows.
///
/// Lightroom's left panel in the Library module is a list of *sources*: the
/// whole catalog at the top, the folder tree under it, and the frames whose
/// files have gone away at the bottom. Those are three different things, not
/// three folders, which is why this is an enum and not an optional path.
public enum FolderSelection: Hashable, Sendable {
    /// "All Photographs" — every photo in the library, missing files included.
    case all
    /// One directory *and everything below it*, which is what clicking a folder
    /// means in Lightroom.
    case folder(path: String)
    /// The photos the library remembers and has no file for.
    case missing
}

/// One directory in the Folders panel.
///
/// `id` is the directory's full path — that is what the selection carries and
/// what the filter matches on. The three name properties are what the row
/// draws, and they are three because a collapsed chain has two halves:
///
/// - `leafName` is the folder itself ("Pictures"), which is the only part the
///   user is looking for and therefore the part in the row's primary font;
/// - `parentChain` is the rest of the chain above it ("Users/schani"), or `nil`
///   when the row is a single folder or a volume. Lightroom draws it as a
///   second, smaller line — one long truncated string ("…rs/schani/Pictures")
///   hides exactly the word that identifies the row;
/// - `name` is the two joined ("Users/schani/Pictures"), which is what the
///   panel sorts on: a chain then sits where its *topmost* component would
///   have put the parent it replaced.
public struct FolderNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// The folder this row selects, without the folded-away parents above it.
    /// For a volume, the volume's name.
    public let leafName: String
    /// The folded-away parents, in order, joined by `/` — `nil` unless this row
    /// is a collapsed chain.
    public let parentChain: String?
    /// Photos in this directory *or any directory below it*, counted once each
    /// however many of its files sit under this node.
    public let count: Int
    /// Photos with a file directly in this directory.
    public let directCount: Int
    /// Sorted by name, case-insensitively.
    public let children: [FolderNode]

    public init(id: String, name: String, count: Int, directCount: Int,
                children: [FolderNode] = []) {
        self.init(id: id, leafName: name, parentChain: nil, count: count,
                  directCount: directCount, children: children)
    }

    public init(id: String, leafName: String, parentChain: String?, count: Int,
                directCount: Int, children: [FolderNode] = []) {
        self.id = id
        self.leafName = leafName
        self.parentChain = parentChain
        self.name = parentChain.map { $0 + "/" + leafName } ?? leafName
        self.count = count
        self.directCount = directCount
        self.children = children
    }
}

/// The Folders panel's model: the directory tree the catalog's files sit in,
/// plus the filter that turns a click on it into the grid's contents.
///
/// # Shape
///
/// Roots are **volumes**, the way Lightroom's panel shows them: the boot volume
/// under its own name (`/` displayed as "Macintosh HD", or whatever the volume
/// is actually called) and each mounted volume as `/Volumes/<name>`.
///
/// Below a root, a chain of directories that has nothing in it but one
/// subdirectory is drawn as **one row** whose name is the joined relative path
/// ("Users/schani/Pictures"). Lightroom does the same thing — an unbroken chain
/// of empty parents is not information, it is five disclosure triangles between
/// the user and their photos. Roots are never collapsed into their child: a
/// volume is a place, and Lightroom always shows it.
///
/// # Cost
///
/// One pass over the catalog, building a node per directory and touching each
/// photo's ancestor chain once, so it is linear in photos × paths × depth and
/// is rebuilt outright whenever the catalog changes rather than being patched.
/// At a hundred thousand frames that is a few million dictionary lookups, i.e.
/// milliseconds, once per import.
public struct FolderTree: Equatable, Sendable {
    /// One per volume, sorted by name case-insensitively.
    public let roots: [FolderNode]
    /// Every photo in the catalog — what "All Photographs" counts.
    public let totalCount: Int
    /// Photos with no location at all.
    public let missingCount: Int

    /// The catalog, reduced to what the filter needs: a photo's id and the
    /// distinct directories it has files in, in the catalog's own order (which
    /// is the grid's order, so a filtered list needs no re-sorting).
    private let entries: [Entry]

    private struct Entry: Equatable, Sendable {
        let id: Int64
        /// Sorted and deduplicated.
        let directories: [String]
    }

    public init() {
        roots = []
        totalCount = 0
        missingCount = 0
        entries = []
    }

    public init(photos: [CatalogPhoto],
                bootVolumeName: String = FolderTree.bootVolumeName()) {
        var entries: [Entry] = []
        entries.reserveCapacity(photos.count)
        var missing = 0

        // The tree under construction: nodes in a flat array, addressed by
        // index, so a node can be looked up by path and grown in place without
        // any reference types.
        var nodes: [Builder] = []
        var indexByPath: [String: Int] = [:]

        /// Finds or creates the node for a directory, saying which — a node is
        /// linked into its parent exactly once, when it is created, which is
        /// what keeps the child lists distinct without searching them.
        func index(ofPath path: String, isRoot: Bool) -> (index: Int, isNew: Bool) {
            if let existing = indexByPath[path] { return (existing, false) }
            nodes.append(Builder(path: path, isRoot: isRoot))
            indexByPath[path] = nodes.count - 1
            return (nodes.count - 1, true)
        }

        for photo in photos {
            let directories = Set(photo.locations.map(FolderTree.directory(ofPath:)))
                .filter { !$0.isEmpty }
            entries.append(Entry(id: photo.id, directories: directories.sorted()))
            if photo.locations.isEmpty { missing += 1 }
            // A photo with two files under the same folder must not count
            // twice, so the ancestors it touches are gathered before any
            // counter moves.
            var touched: Set<Int> = []
            for directory in directories {
                var parent: Int?
                var leaf: Int?
                for (offset, path) in FolderTree.ancestorPaths(of: directory).enumerated() {
                    let (node, isNew) = index(ofPath: path, isRoot: offset == 0)
                    if isNew, let parent { nodes[parent].children.append(node) }
                    touched.insert(node)
                    parent = node
                    leaf = node
                }
                if let leaf { nodes[leaf].directCount += 1 }
            }
            for node in touched { nodes[node].count += 1 }
        }

        self.entries = entries
        self.totalCount = photos.count
        self.missingCount = missing
        self.roots = nodes.indices
            .filter { nodes[$0].isRoot }
            .map { FolderTree.node(at: $0, in: nodes, isRoot: true,
                                   bootVolumeName: bootVolumeName) }
            .sorted(by: FolderTree.isOrderedBefore)
    }

    // MARK: - Filtering

    /// The photos a selection shows, in the catalog's order — which is the
    /// grid's order, so this *is* the displayed list a shift-range spans.
    public func photoIDs(for selection: FolderSelection) -> [Int64] {
        switch selection {
        case .all:
            return entries.map(\.id)
        case .missing:
            return entries.filter { $0.directories.isEmpty }.map(\.id)
        case .folder(let path):
            return entries.filter { entry in
                entry.directories.contains { FolderTree.directory($0, isWithin: path) }
            }.map(\.id)
        }
    }

    /// Whether `directory` is `folder` itself or lies below it.
    ///
    /// The prefix has to stop at a path-component boundary: `/a/b` contains
    /// `/a/b/c` and does not contain `/a/bc`, which a bare `hasPrefix` would get
    /// wrong. `/` is the one folder whose separator is already there.
    public static func directory(_ directory: String, isWithin folder: String) -> Bool {
        if directory == folder { return true }
        if folder == "/" { return directory.hasPrefix("/") }
        return directory.hasPrefix(folder + "/")
    }

    /// The directory a file path sits in: everything before the last `/`, with
    /// the root spelled `/` rather than the empty string. Returns "" for a path
    /// with no separator in it at all, which the library's standardized
    /// absolute paths never are.
    public static func directory(ofPath path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        if slash == path.startIndex { return "/" }
        return String(path[path.startIndex..<slash])
    }

    // MARK: - Lookup

    /// The node whose path this is, or `nil` — note that a collapsed chain is
    /// addressed by its *deepest* path, the one its row selects.
    public func node(at path: String) -> FolderNode? {
        func search(_ node: FolderNode) -> FolderNode? {
            if node.id == path { return node }
            for child in node.children {
                if let found = search(child) { return found }
            }
            return nil
        }
        for root in roots {
            if let found = search(root) { return found }
        }
        return nil
    }

    /// Every node, roots first then depth-first — what a test or the panel's
    /// "is this selection still there" check walks.
    public var allNodes: [FolderNode] {
        func flatten(_ node: FolderNode) -> [FolderNode] {
            [node] + node.children.flatMap(flatten)
        }
        return roots.flatMap(flatten)
    }

    // MARK: - Volumes

    /// What the Finder calls `/`. Lightroom's panel shows the volume's name,
    /// not a slash.
    public static func bootVolumeName() -> String {
        let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? "Macintosh HD"
    }

    /// The path of every node from the volume down to `directory`, inclusive.
    ///
    /// `/Volumes/<name>` is a root in its own right rather than two rows under
    /// the boot volume: it is a different disk, and `/Volumes` is a mount point,
    /// not a place a user keeps photos.
    static func ancestorPaths(of directory: String) -> [String] {
        guard directory.hasPrefix("/") else { return [] }
        let components = directory.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var current: String
        var next = 0
        if components.count >= 2, components[0] == "Volumes" {
            current = "/Volumes/" + components[1]
            next = 2
        } else {
            current = "/"
        }
        var paths = [current]
        for component in components[next...] {
            current = current == "/" ? "/" + component : current + "/" + component
            paths.append(current)
        }
        return paths
    }

    // MARK: - Building

    private struct Builder {
        let path: String
        let isRoot: Bool
        var children: [Int] = []
        var count = 0
        var directCount = 0

        init(path: String, isRoot: Bool) {
            self.path = path
            self.isRoot = isRoot
        }
    }

    /// Freezes one subtree, collapsing chains on the way down.
    private static func node(at index: Int, in nodes: [Builder], isRoot: Bool,
                             bootVolumeName: String) -> FolderNode {
        var index = index
        var components = [isRoot
            ? rootName(nodes[index].path, bootVolumeName: bootVolumeName)
            : lastComponent(nodes[index].path)]
        // A directory with nothing in it but one subdirectory is drawn as part
        // of that subdirectory's row. Its counts are the child's by
        // construction (no direct photos, one child), so nothing is lost.
        while !isRoot, nodes[index].children.count == 1, nodes[index].directCount == 0 {
            index = nodes[index].children[0]
            components.append(lastComponent(nodes[index].path))
        }
        let children = nodes[index].children
            .map { node(at: $0, in: nodes, isRoot: false, bootVolumeName: bootVolumeName) }
            .sorted(by: isOrderedBefore)
        return FolderNode(id: nodes[index].path,
                          leafName: components[components.count - 1],
                          parentChain: components.count > 1
                              ? components.dropLast().joined(separator: "/") : nil,
                          count: nodes[index].count,
                          directCount: nodes[index].directCount, children: children)
    }

    private static func rootName(_ path: String, bootVolumeName: String) -> String {
        path == "/" ? bootVolumeName : lastComponent(path)
    }

    private static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = String(path[path.index(after: slash)...])
        return name.isEmpty ? path : name
    }

    /// Case-insensitive by name, ties broken by path so the order is total.
    private static func isOrderedBefore(_ a: FolderNode, _ b: FolderNode) -> Bool {
        switch a.name.localizedCaseInsensitiveCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id < b.id
        }
    }
}
