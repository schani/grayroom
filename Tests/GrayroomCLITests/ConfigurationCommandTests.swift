import XCTest
@testable import GrayroomCLI

final class ConfigurationCommandTests: XCTestCase {
    func testSetGetAndList() throws {
        let temp = try TempLibrary()
        defer { temp.tearDown() }

        try temp.run(["config", "set", "storage.bucket", "archive"])
        XCTAssertEqual(try temp.run(["config", "get", "storage.bucket"]).stdout, "archive\n")
        XCTAssertTrue(try temp.run(["config", "list"]).stdout
            .contains("storage.bucket=archive\n"))
    }
}
