import Foundation

public enum EditStateError: Error, CustomStringConvertible {
    case unknownKeyPath(String)
    case malformedSetting(String)
    case notAnObject(String)
    case indexOutOfRange(String, Int, Int)

    public var description: String {
        switch self {
        case .unknownKeyPath(let k): return "unknown edit key '\(k)'"
        case .malformedSetting(let s): return "malformed --set argument '\(s)' (expected key=value)"
        case .notAnObject(let k): return "edit key '\(k)' is not an object"
        case .indexOutOfRange(let k, let i, let n):
            return "index \(i) out of range in '\(k)' (\(n) element\(n == 1 ? "" : "s"))"
        }
    }
}

// MARK: - Sidecar IO

extension EditState {
    /// `IMG_1234.DNG` → `IMG_1234.DNG.grayroom.json`
    public static func sidecarURL(forRAW url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".grayroom.json")
    }

    public static func load(from url: URL) throws -> EditState {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }

    public static func decode(from data: Data) throws -> EditState {
        try JSONDecoder().decode(EditState.self, from: data)
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public func save(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }
}

// MARK: - Dotted-path `--set` merging

extension EditState {
    /// Every dotted key path that `--set` accepts, derived from a fully populated
    /// template so the list can never drift from the schema.
    public static var settableKeyPaths: Set<String> {
        var template = EditState()
        template.whiteBalance = WhiteBalance(temperature: 5500, tint: 0)
        guard let data = try? template.jsonData(),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var out = Set<String>()
        flatten(obj, prefix: "", into: &out)
        return out
    }

    private static func flatten(_ obj: [String: Any], prefix: String, into out: inout Set<String>) {
        for (k, v) in obj {
            let path = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let sub = v as? [String: Any] {
                flatten(sub, prefix: path, into: &out)
            } else {
                out.insert(path)
            }
        }
    }

    /// Applies `key=value` overrides where `key` is a dotted JSON path
    /// (`tone.exposure`, `bwMix.enabled`, `clarity`, …).
    ///
    /// Array elements are addressed with a bracket subscript:
    /// `masks[0].adjustments.exposure=1.5`. The mask must already exist —
    /// `--set` edits masks, it does not create them (strokes come from the
    /// sidecar JSON).
    ///
    /// Implemented as a JSON merge: encode → mutate the dictionary → decode.
    public func applying(settings: [String]) throws -> EditState {
        guard !settings.isEmpty else { return self }
        var pairs: [(String, String)] = []
        for s in settings {
            guard let eq = s.firstIndex(of: "=") else { throw EditStateError.malformedSetting(s) }
            let key = String(s[s.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(s[s.index(after: eq)...])
            guard !key.isEmpty else { throw EditStateError.malformedSetting(s) }
            pairs.append((key, value))
        }
        return try applying(keyValues: pairs)
    }

    public func applying(keyValues: [(String, String)]) throws -> EditState {
        guard !keyValues.isEmpty else { return self }
        let valid = EditState.settableKeyPaths
        let data = try jsonData()
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditStateError.notAnObject("")
        }
        for (key, raw) in keyValues {
            let path = try EditState.parsePath(key)
            if path.contains(where: { if case .index = $0 { return true } else { return false } }) {
                // Array paths (`masks[0].adjustments.exposure`) are validated
                // against the *actual* document: which indices exist depends on
                // how many masks the sidecar holds, so a static key-path list
                // cannot say. Creating masks with --set is not supported —
                // masks come from the sidecar JSON.
                try EditState.validate(path: path[...], in: root, fullKey: key)
            } else {
                guard valid.contains(key) else { throw EditStateError.unknownKeyPath(key) }
            }
            var container: Any = root
            try EditState.set(path: path[...], to: EditState.parse(raw),
                              in: &container, fullKey: key)
            guard let dict = container as? [String: Any] else {
                throw EditStateError.notAnObject(key)
            }
            root = dict
        }
        let merged = try JSONSerialization.data(withJSONObject: root)
        return try EditState.decode(from: merged)
    }

    /// One step of a dotted `--set` path.
    enum PathElement: Equatable {
        case key(String)
        case index(Int)
    }

    /// `masks[0].adjustments.exposure` → `[.key(masks), .index(0),
    /// .key(adjustments), .key(exposure)]`. A component may carry several
    /// subscripts (`a[0][1]`), though nothing in the schema needs that today.
    static func parsePath(_ key: String) throws -> [PathElement] {
        var out: [PathElement] = []
        for component in key.split(separator: ".", omittingEmptySubsequences: false) {
            var name = ""
            var indices: [Int] = []
            var rest = Substring(component)
            if let open = rest.firstIndex(of: "[") {
                name = String(rest[rest.startIndex..<open])
                rest = rest[open...]
                while let open = rest.firstIndex(of: "["), let close = rest.firstIndex(of: "]"),
                      open < close {
                    guard let i = Int(rest[rest.index(after: open)..<close]), i >= 0 else {
                        throw EditStateError.unknownKeyPath(key)
                    }
                    indices.append(i)
                    rest = rest[rest.index(after: close)...]
                }
                guard rest.isEmpty else { throw EditStateError.unknownKeyPath(key) }
            } else {
                name = String(rest)
            }
            guard !name.isEmpty else { throw EditStateError.unknownKeyPath(key) }
            out.append(.key(name))
            out.append(contentsOf: indices.map { PathElement.index($0) })
        }
        guard !out.isEmpty else { throw EditStateError.unknownKeyPath(key) }
        return out
    }

    /// Structural validation: every element of the path must already exist.
    private static func validate(path: ArraySlice<PathElement>, in container: Any, fullKey: String) throws {
        guard let head = path.first else { return }
        switch head {
        case .key(let name):
            guard let dict = container as? [String: Any] else {
                throw EditStateError.notAnObject(fullKey)
            }
            guard let child = dict[name] else { throw EditStateError.unknownKeyPath(fullKey) }
            try validate(path: path.dropFirst(), in: child, fullKey: fullKey)
        case .index(let i):
            guard let array = container as? [Any] else {
                throw EditStateError.unknownKeyPath(fullKey)
            }
            guard i < array.count else {
                throw EditStateError.indexOutOfRange(fullKey, i, array.count)
            }
            try validate(path: path.dropFirst(), in: array[i], fullKey: fullKey)
        }
    }

    private static func set(path: ArraySlice<PathElement>, to value: Any,
                            in container: inout Any, fullKey: String) throws {
        guard let head = path.first else {
            container = value
            return
        }
        let tail = path.dropFirst()
        switch head {
        case .key(let name):
            var dict = (container as? [String: Any]) ?? [:]
            var child: Any = dict[name] ?? [String: Any]()
            if tail.isEmpty {
                child = value
            } else {
                try set(path: tail, to: value, in: &child, fullKey: fullKey)
            }
            dict[name] = child
            container = dict
        case .index(let i):
            guard var array = container as? [Any], i < array.count else {
                throw EditStateError.unknownKeyPath(fullKey)
            }
            var child: Any = array[i]
            if tail.isEmpty {
                child = value
            } else {
                try set(path: tail, to: value, in: &child, fullKey: fullKey)
            }
            array[i] = child
            container = array
        }
    }

    /// `true`/`false` → Bool, numeric → Double, `null` → NSNull, otherwise String.
    static func parse(_ raw: String) -> Any {
        let t = raw.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        case "null", "nil", "": return NSNull()
        default: break
        }
        if let d = Double(t) { return d }
        return t
    }
}
