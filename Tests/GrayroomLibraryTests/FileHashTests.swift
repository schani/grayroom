import CryptoKit
import Foundation
import XCTest
@testable import GrayroomLibrary

final class FileHashTests: XCTestCase {
    private var temp: TempLibrary!

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    /// `printf 'grayroom library test\n' | shasum -a 256`
    func testKnownDigest() throws {
        let url = try temp.writeFile("known.txt", Data("grayroom library test\n".utf8))
        let hex = try FileHash.sha256HexString(of: url)
        XCTAssertEqual(hex, "51ea955d51d3c5cd8ad42d6a59b74243cfb31daca809e8bdee2ca7569db29568")
    }

    func testEmptyFileDigest() throws {
        let url = try temp.writeFile("empty.bin", Data())
        XCTAssertEqual(
            try FileHash.sha256HexString(of: url),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// The chunked read must agree with hashing the whole file at once, across
    /// several 1 MB boundaries and a partial final chunk.
    func testStreamingMatchesWholeFileAcrossChunkBoundaries() throws {
        var bytes = Data(count: 0)
        bytes.reserveCapacity(FileHash.chunkSize * 2 + 12345)
        for i in 0..<(FileHash.chunkSize * 2 + 12345) {
            bytes.append(UInt8(i % 251))
        }
        let url = try temp.writeFile("big.bin", bytes)
        let expected = Data(SHA256.hash(data: bytes))
        XCTAssertEqual(try FileHash.sha256(of: url), expected)
    }

    func testHexRoundTrip() throws {
        let url = try temp.writeFile("known2.txt", Data("grayroom library test\n".utf8))
        let digest = try FileHash.sha256(of: url)
        XCTAssertEqual(FileHash.data(fromHexString: FileHash.hexString(digest)), digest)
        XCTAssertNil(FileHash.data(fromHexString: "abc"))
        XCTAssertNil(FileHash.data(fromHexString: "zz"))
    }

    func testMissingFileThrows() {
        let url = temp.directory.appendingPathComponent("nope.bin")
        XCTAssertThrowsError(try FileHash.sha256(of: url))
    }
}
