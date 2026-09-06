import Foundation
import GrayroomLibrary
import XCTest
@testable import GrayroomUI

final class GridDragFilesTests: XCTestCase {
    func testDragMaterializesSelectedOriginalsInGridOrder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DragStore()
        let storage = OriginalStorage(cacheDirectory: root, objectStore: store)
        let aData = Data("a".utf8)
        let bData = Data("b".utf8)
        let aSource = root.appendingPathComponent("a")
        let bSource = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try aData.write(to: aSource)
        try bData.write(to: bSource)
        let a = CatalogPhoto(id: 1, hash: try FileHash.sha256(of: aSource), originalName: "a.DNG")
        let b = CatalogPhoto(id: 2, hash: try FileHash.sha256(of: bSource), originalName: "b.JPG")
        store.objects[storage.objectKey(hash: a.hash)] = aData
        store.objects[storage.objectKey(hash: b.hash)] = bData

        let files = try GridDragFiles.files(for: [2, 1], from: [a, b], originals: storage)

        XCTAssertEqual(files.map(\.id), [1, 2])
        XCTAssertEqual(files.map(\.url.pathExtension), ["dng", "jpg"])
        XCTAssertEqual(try files.map { try Data(contentsOf: $0.url) },
                       [Data("a".utf8), Data("b".utf8)])
    }
}

private final class DragStore: OriginalObjectStore, @unchecked Sendable {
    var objects: [String: Data] = [:]
    func put(file: URL, key: String, sha256: Data) throws {
        objects[key] = try Data(contentsOf: file)
    }
    func get(key: String, to destination: URL) throws {
        try objects[key]!.write(to: destination)
    }
}
