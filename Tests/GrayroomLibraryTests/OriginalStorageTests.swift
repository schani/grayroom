import Foundation
import XCTest
@testable import GrayroomLibrary

final class OriginalStorageTests: XCTestCase {
    func testConfigurationRoundTrips() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }

        try temp.library.setConfiguration("photos", forKey: "storage.bucket")
        XCTAssertEqual(try temp.library.configurationValue(forKey: "storage.bucket"), "photos")
        XCTAssertEqual(try temp.library.configuration(), ["storage.bucket": "photos"])
    }

    func testStorageConfigurationSavesAndLoadsEveryValue() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        let configuration = OriginalStorageConfiguration(
            endpoint: "https://s3.example.com", region: "us-west-1", bucket: "photos",
            prefix: "masters", cacheDirectory: "/tmp/grayroom-cache")

        try configuration.save(to: temp.library)

        XCTAssertEqual(try OriginalStorageConfiguration(library: temp.library), configuration)
    }

    func testNetworkConfigurationCanUseCredentialsFromAStore() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        try OriginalStorageConfiguration(
            endpoint: "https://s3.example.com", region: "us-west-1", bucket: "photos",
            cacheDirectory: "/tmp/grayroom-cache").save(to: temp.library)
        let credentials = S3Credentials(accessKeyID: "key", secretAccessKey: "secret")

        XCTAssertNoThrow(try OriginalStorage(
            library: temp.library, environment: [:],
            credentialStore: MemoryCredentialStore(credentials: credentials)))
    }

    func testNetworkConfigurationWithoutCredentialsFails() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        try OriginalStorageConfiguration(
            endpoint: "https://s3.example.com", region: "us-west-1", bucket: "photos",
            cacheDirectory: "/tmp/grayroom-cache").save(to: temp.library)

        XCTAssertThrowsError(try OriginalStorage(
            library: temp.library, environment: [:], credentialStore: MemoryCredentialStore()))
    }

    func testCacheNameIsHashPlusLowercaseExtension() throws {
        let directory = URL(fileURLWithPath: "/tmp/cache", isDirectory: true)
        let hash = Data(repeating: 0xab, count: 32)
        let storage = OriginalStorage(cacheDirectory: directory, prefix: "originals",
                                      objectStore: MemoryObjectStore())

        XCTAssertEqual(storage.cacheURL(hash: hash, originalName: "IMG_1.DNG").path,
                       "/tmp/cache/\(String(repeating: "ab", count: 32)).dng")
        XCTAssertEqual(storage.objectKey(hash: hash),
                       "originals/\(String(repeating: "ab", count: 32))")
    }

    func testImportUploadsAndCachesBeforeInsertingPhoto() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        let store = MemoryObjectStore()
        let storage = OriginalStorage(
            cacheDirectory: temp.directory.appendingPathComponent("cache"),
            prefix: "originals", objectStore: store)
        let source = try temp.writeFile("IMG.RAW", Data("original".utf8))

        let result = try Importer(library: temp.library, originals: storage,
                                  probe: stubProbe()).importFile(at: source)
        let photo = try XCTUnwrap(temp.library.photo(id: result.photoID))
        XCTAssertEqual(store.objects[storage.objectKey(hash: photo.hash)], Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: storage.cacheURL(for: photo)), Data("original".utf8))
        XCTAssertEqual(try temp.library.photos().count, 1)
    }

    func testFailedUploadDoesNotInsertPhotoOrPopulateCache() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        let store = MemoryObjectStore(error: TestError.failed)
        let storage = OriginalStorage(
            cacheDirectory: temp.directory.appendingPathComponent("cache"),
            prefix: "originals", objectStore: store)
        let source = try temp.writeFile("IMG.RAW", Data("original".utf8))

        XCTAssertThrowsError(try Importer(library: temp.library, originals: storage,
                                          probe: stubProbe()).importFile(at: source))
        XCTAssertTrue(try temp.library.photos().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.cacheDirectory.path))
    }

    func testFailedCacheCopyDoesNotInsertPhoto() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        let storage = OriginalStorage(cacheDirectory: URL(fileURLWithPath: "/dev/null/cache"),
                                      objectStore: MemoryObjectStore())
        let source = try temp.writeFile("IMG.RAW", Data("original".utf8))

        XCTAssertThrowsError(try Importer(library: temp.library, originals: storage,
                                          probe: stubProbe()).importFile(at: source))
        XCTAssertTrue(try temp.library.photos().isEmpty)
    }

    func testCacheMissDownloadsTheOriginal() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        let store = MemoryObjectStore()
        let storage = OriginalStorage(cacheDirectory: temp.directory.appendingPathComponent("cache"),
                                      objectStore: store)
        let remote = Data("remote".utf8)
        let source = try temp.writeFile("remote", remote)
        let hash = try FileHash.sha256(of: source)
        store.objects[storage.objectKey(hash: hash)] = remote
        let photo = Photo(hash: hash, byteSize: 6, originalName: "IMG.DNG")

        let local = try storage.localURL(for: photo)

        XCTAssertEqual(local.pathExtension, "dng")
        XCTAssertEqual(try Data(contentsOf: local), Data("remote".utf8))
    }

    func testCorruptDownloadIsNotCached() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        let store = MemoryObjectStore()
        let storage = OriginalStorage(cacheDirectory: temp.directory.appendingPathComponent("cache"),
                                      objectStore: store)
        let hash = Data(repeating: 7, count: 32)
        store.objects[storage.objectKey(hash: hash)] = Data("wrong".utf8)
        let photo = Photo(hash: hash, byteSize: 5, originalName: "IMG.DNG")

        XCTAssertThrowsError(try storage.localURL(for: photo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.cacheURL(for: photo).path))
    }

    func testBatchImportRunsFiveUploadsAtOnceAndNoMore() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }
        let store = BlockingObjectStore()
        let storage = OriginalStorage(cacheDirectory: temp.directory.appendingPathComponent("cache"),
                                      objectStore: store)
        let importer = Importer(library: temp.library, originals: storage, probe: stubProbe())
        let urls = try (0..<8).map {
            try temp.writeFile("concurrent-\($0).dng", Data("photo \($0)".utf8))
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = importer.importFiles(urls)
            finished.signal()
        }

        let reachedFive = store.waitForFiveUploads(timeout: .now() + 2)
        let peak = store.peak
        store.releaseAll()

        XCTAssertTrue(reachedFive)
        XCTAssertEqual(peak, 5)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try temp.library.photos().count, 8)
    }
}

private enum TestError: Error { case failed }

private struct MemoryCredentialStore: OriginalStorageCredentialStore {
    var credentials: S3Credentials?

    func load() throws -> S3Credentials? { credentials }
    func save(_ credentials: S3Credentials) throws {}
}

private final class MemoryObjectStore: OriginalObjectStore, @unchecked Sendable {
    var objects: [String: Data] = [:]
    let error: Error?

    init(error: Error? = nil) { self.error = error }

    func put(file: URL, key: String, sha256: Data) throws {
        if let error { throw error }
        objects[key] = try Data(contentsOf: file)
    }

    func get(key: String, to destination: URL) throws {
        guard let data = objects[key] else { throw TestError.failed }
        try data.write(to: destination)
    }
}

private final class BlockingObjectStore: OriginalObjectStore, @unchecked Sendable {
    private let lock = NSLock()
    private let fiveStarted = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var active = 0
    private var maximum = 0
    private var started = 0

    var peak: Int { lock.withLock { maximum } }

    func waitForFiveUploads(timeout: DispatchTime) -> Bool {
        fiveStarted.wait(timeout: timeout) == .success
    }

    func releaseAll() {
        for _ in 0..<20 { release.signal() }
    }

    func put(file: URL, key: String, sha256: Data) throws {
        lock.withLock {
            active += 1
            started += 1
            maximum = max(maximum, active)
            if started == 5 { fiveStarted.signal() }
        }
        release.wait()
        lock.withLock { active -= 1 }
    }

    func get(key: String, to destination: URL) throws { throw TestError.failed }
}
