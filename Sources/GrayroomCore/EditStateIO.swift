import Foundation

public enum EditStateError: Error, CustomStringConvertible {
    case unknownKeyPath(String)
    case malformedSetting(String)
    case notAnObject(String)

    public var description: String {
        switch self {
        case .unknownKeyPath(let k): return "unknown edit key '\(k)'"
        case .malformedSetting(let s): return "malformed --set argument '\(s)' (expected key=value)"
        case .notAnObject(let k): return "edit key '\(k)' is not an object"
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
            guard valid.contains(key) else { throw EditStateError.unknownKeyPath(key) }
            try EditState.set(path: key.split(separator: ".").map(String.init),
                              to: EditState.parse(raw),
                              in: &root,
                              fullKey: key)
        }
        let merged = try JSONSerialization.data(withJSONObject: root)
        return try EditState.decode(from: merged)
    }

    private static func set(path: [String], to value: Any, in dict: inout [String: Any], fullKey: String) throws {
        guard let head = path.first else { return }
        if path.count == 1 {
            dict[head] = value
            return
        }
        var child = (dict[head] as? [String: Any]) ?? [:]
        try set(path: Array(path.dropFirst()), to: value, in: &child, fullKey: fullKey)
        dict[head] = child
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
