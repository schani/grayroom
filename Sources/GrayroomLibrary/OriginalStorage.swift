import CryptoKit
import Foundation
import Security

public protocol OriginalObjectStore: Sendable {
    func put(file: URL, key: String, sha256: Data) throws
    func get(key: String, to destination: URL) throws
}

public struct S3Credentials: Codable, Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

public protocol OriginalStorageCredentialStore: Sendable {
    func load() throws -> S3Credentials?
    func save(_ credentials: S3Credentials) throws
}

public struct KeychainOriginalStorageCredentialStore: OriginalStorageCredentialStore {
    private let service = "Grayroom Original Storage"
    private let account = "S3 credentials"

    public init() {}

    public func load() throws -> S3Credentials? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainOriginalStorageError(status: status)
        }
        return try JSONDecoder().decode(S3Credentials.self, from: data)
    }

    public func save(_ credentials: S3Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainOriginalStorageError(status: status) }
    }
}

public struct KeychainOriginalStorageError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public var description: String { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
}

public struct OriginalStorageConfiguration: Equatable, Sendable {
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var prefix: String
    public var cacheDirectory: String

    public init(endpoint: String, region: String, bucket: String, prefix: String = "originals",
                cacheDirectory: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.cacheDirectory = cacheDirectory
    }

    public init(library: Library) throws {
        func required(_ key: String) throws -> String {
            guard let value = try library.configurationValue(forKey: key), !value.isEmpty else {
                throw LibraryError.missingConfiguration(key)
            }
            return value
        }
        endpoint = try required("storage.endpoint")
        region = try required("storage.region")
        bucket = try required("storage.bucket")
        prefix = try library.configurationValue(forKey: "storage.prefix") ?? "originals"
        cacheDirectory = try required("cache.directory")
    }

    public func save(to library: Library) throws {
        try library.setConfiguration([
            "storage.endpoint": endpoint,
            "storage.region": region,
            "storage.bucket": bucket,
            "storage.prefix": prefix,
            "cache.directory": cacheDirectory,
        ])
    }

    public func makeStorage(credentials: S3Credentials?) throws -> OriginalStorage {
        guard let endpointURL = URL(string: endpoint),
              endpointURL.isFileURL || (endpointURL.scheme != nil && endpointURL.host != nil),
              endpointURL.query == nil, endpointURL.fragment == nil else {
            throw OriginalStorageConfigurationError.invalidEndpoint
        }
        guard !bucket.isEmpty, !bucket.contains("/") else {
            throw OriginalStorageConfigurationError.invalidBucket
        }
        guard (cacheDirectory as NSString).isAbsolutePath else {
            throw OriginalStorageConfigurationError.invalidCacheDirectory
        }
        let store: any OriginalObjectStore
        if endpointURL.isFileURL {
            store = FileObjectStore(directory: endpointURL.appendingPathComponent(bucket))
        } else {
            guard !region.isEmpty else { throw OriginalStorageConfigurationError.invalidRegion }
            guard let credentials, !credentials.accessKeyID.isEmpty,
                  !credentials.secretAccessKey.isEmpty else {
                throw LibraryError.missingStorageCredentials
            }
            store = S3ObjectStore(endpoint: endpointURL, region: region, bucket: bucket,
                                  accessKeyID: credentials.accessKeyID,
                                  secretAccessKey: credentials.secretAccessKey,
                                  sessionToken: credentials.sessionToken)
        }
        return OriginalStorage(cacheDirectory: URL(fileURLWithPath: cacheDirectory,
                                                   isDirectory: true),
                               prefix: prefix, objectStore: store)
    }
}

public enum OriginalStorageConfigurationError: Error, CustomStringConvertible, Sendable {
    case invalidEndpoint
    case invalidRegion
    case invalidBucket
    case invalidCacheDirectory

    public var description: String {
        switch self {
        case .invalidEndpoint: return "enter a valid endpoint URL"
        case .invalidRegion: return "enter a region"
        case .invalidBucket: return "enter a valid bucket name"
        case .invalidCacheDirectory: return "enter an absolute cache directory path"
        }
    }
}

public final class OriginalStorage: @unchecked Sendable {
    public let cacheDirectory: URL
    public let prefix: String
    private let objectStore: any OriginalObjectStore

    public init(cacheDirectory: URL, prefix: String = "originals",
                objectStore: any OriginalObjectStore) {
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.objectStore = objectStore
    }

    public convenience init(library: Library,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            credentialStore: any OriginalStorageCredentialStore =
                                KeychainOriginalStorageCredentialStore())
        throws {
        let configuration = try OriginalStorageConfiguration(library: library)
        if configuration.endpoint.lowercased().hasPrefix("file:") {
            self.init(copying: try configuration.makeStorage(credentials: nil))
            return
        }
        let credentials: S3Credentials?
        if environment["AWS_ACCESS_KEY_ID"] != nil || environment["AWS_SECRET_ACCESS_KEY"] != nil {
            guard let accessKey = environment["AWS_ACCESS_KEY_ID"], !accessKey.isEmpty,
                  let secretKey = environment["AWS_SECRET_ACCESS_KEY"], !secretKey.isEmpty else {
                throw LibraryError.missingStorageCredentials
            }
            credentials = S3Credentials(accessKeyID: accessKey, secretAccessKey: secretKey,
                                        sessionToken: environment["AWS_SESSION_TOKEN"])
        } else {
            credentials = try credentialStore.load()
        }
        self.init(copying: try configuration.makeStorage(credentials: credentials))
    }

    private convenience init(copying storage: OriginalStorage) {
        self.init(cacheDirectory: storage.cacheDirectory, prefix: storage.prefix,
                  objectStore: storage.objectStore)
    }

    public static func resolved(for library: Library) throws -> OriginalStorage {
        if let storage = library.originalStorage { return storage }
        let storage = try OriginalStorage(library: library)
        library.originalStorage = storage
        return storage
    }

    public func objectKey(hash: Data) -> String {
        let hash = FileHash.hexString(hash)
        return prefix.isEmpty ? hash : "\(prefix)/\(hash)"
    }

    public func cacheURL(hash: Data, originalName: String) -> URL {
        let ext = URL(fileURLWithPath: originalName).pathExtension.lowercased()
        let name = FileHash.hexString(hash) + (ext.isEmpty ? "" : ".\(ext)")
        return cacheDirectory.appendingPathComponent(name, isDirectory: false)
    }

    public func cacheURL(for photo: Photo) -> URL {
        cacheURL(hash: photo.hash, originalName: photo.originalName)
    }

    public func storeImportedFile(_ source: URL, hash: Data, originalName: String) throws {
        try objectStore.put(file: source, key: objectKey(hash: hash), sha256: hash)
        let destination = cacheURL(hash: hash, originalName: originalName)
        try FileManager.default.createDirectory(at: cacheDirectory,
                                                withIntermediateDirectories: true)
        try Self.atomicCopy(source, to: destination)
    }

    @discardableResult
    public func localURL(for photo: Photo) throws -> URL {
        try localURL(hash: photo.hash, originalName: photo.originalName)
    }

    @discardableResult
    public func localURL(hash: Data, originalName: String) throws -> URL {
        let destination = cacheURL(hash: hash, originalName: originalName)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: cacheDirectory,
                                                withIntermediateDirectories: true)
        let temporary = cacheDirectory.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try objectStore.get(key: objectKey(hash: hash), to: temporary)
            guard try FileHash.sha256(of: temporary) == hash else {
                throw OriginalStorageError.hashMismatch
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: temporary)
            } else {
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch where FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: temporary)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }

    fileprivate static func atomicCopy(_ source: URL, to destination: URL) throws {
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        try FileManager.default.copyItem(at: source, to: temporary)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: temporary)
            } else {
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch where FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: temporary)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

public enum OriginalStorageError: Error, CustomStringConvertible, Sendable {
    case hashMismatch

    public var description: String {
        "downloaded original does not match its SHA-256"
    }
}

public struct S3ObjectStore: OriginalObjectStore, Sendable {
    public let endpoint: URL
    public let region: String
    public let bucket: String
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(endpoint: URL, region: String, bucket: String, accessKeyID: String,
                secretAccessKey: String, sessionToken: String? = nil) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }

    public func put(file: URL, key: String, sha256: Data) throws {
        try request(method: "PUT", key: key, payloadHash: Self.hex(sha256), uploadFile: file)
    }

    public func get(key: String, to destination: URL) throws {
        try request(method: "GET", key: key,
                    payloadHash: Self.hex(SHA256.hash(data: Data())),
                    downloadDestination: destination)
    }

    @discardableResult
    private func request(method: String, key: String, payloadHash: String,
                         uploadFile: URL? = nil, downloadDestination: URL? = nil) throws -> Data {
        let now = Date()
        let timestamp = Self.timestamp.string(from: now)
        let day = String(timestamp.prefix(8))
        let path = ([endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), bucket, key]
            .filter { !$0.isEmpty }).joined(separator: "/")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/" + path.split(separator: "/")
            .map { Self.encode(String($0)) }.joined(separator: "/")
        guard let url = components.url, let hostname = components.host else {
            throw URLError(.badURL)
        }
        let host = components.port.map { "\(hostname):\($0)" } ?? hostname

        var headers = ["host": host, "x-amz-content-sha256": payloadHash,
                       "x-amz-date": timestamp]
        if let sessionToken { headers["x-amz-security-token"] = sessionToken }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [method, components.percentEncodedPath, "", canonicalHeaders,
                         signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope,
                            Self.hex(SHA256.hash(data: Data(canonical.utf8)))]
            .joined(separator: "\n")
        let signature = Self.hex(Self.hmac(Data(stringToSign.utf8), key: Self.signingKey(
            secret: secretAccessKey, day: day, region: region)))

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), "
                         + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }
        if let downloadDestination {
            URLSession.shared.downloadTask(with: request) { url, response, error in
                if let url {
                    do { try FileManager.default.moveItem(at: url, to: downloadDestination) }
                    catch { box.error = error }
                }
                box.response = response
                box.error = box.error ?? error
                semaphore.signal()
            }.resume()
        } else if let uploadFile {
            URLSession.shared.uploadTask(with: request, fromFile: uploadFile,
                                         completionHandler: completion).resume()
        } else {
            URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
        }
        semaphore.wait()
        if let error = box.error { throw error }
        guard let response = box.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw S3Error(statusCode: response.statusCode,
                          message: box.data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
        return box.data ?? Data()
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    private static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func signingKey(secret: String, day: String, region: String) -> Data {
        let date = hmac(Data(day.utf8), key: Data(("AWS4" + secret).utf8))
        let region = hmac(Data(region.utf8), key: date)
        let service = hmac(Data("s3".utf8), key: region)
        return hmac(Data("aws4_request".utf8), key: service)
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct S3Error: Error, CustomStringConvertible, Sendable {
    public let statusCode: Int
    public let message: String
    public var description: String { "S3 request failed (HTTP \(statusCode)): \(message)" }
}

private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}

private struct FileObjectStore: OriginalObjectStore {
    let directory: URL

    func put(file: URL, key: String, sha256: Data) throws {
        let destination = directory.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try OriginalStorage.atomicCopy(file, to: destination)
    }

    func get(key: String, to destination: URL) throws {
        try FileManager.default.copyItem(at: directory.appendingPathComponent(key), to: destination)
    }
}
