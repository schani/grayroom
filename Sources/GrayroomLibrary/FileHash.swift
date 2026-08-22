import CryptoKit
import Foundation

/// SHA-256 of a whole file — the external identity of a photo (see PLAN.md,
/// "M6 — Library"). Streamed rather than slurped: RAW files run to 100 MB and
/// the hash is disk-bound anyway.
public struct FileHash {
    /// 1 MB, chosen in PLAN.md.
    public static let chunkSize = 1 << 20

    public static func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses a hex digest back into bytes; `nil` if it is not an even-length
    /// run of hex digits.
    public static func data(fromHexString hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    public static func sha256HexString(of url: URL) throws -> String {
        hexString(try sha256(of: url))
    }
}
