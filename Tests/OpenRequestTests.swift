import XCTest

final class OpenRequestTests: XCTestCase {
    func testFileURLOpensAsIs() throws {
        let u = URL(fileURLWithPath: "/tmp/Sunday.mp4")
        XCTAssertEqual(OpenRequest(url: u), OpenRequest(file: u))
    }

    func testURLSchemeWithPointsAndDetect() throws {
        let u = try XCTUnwrap(URL(string: "sermontrim://open?path=/Users/x/Desktop/(Students)%20Nov%2018.mp4&in=00:44:01:20&out=01:23:08:07&detect=1"))
        let r = try XCTUnwrap(OpenRequest(url: u))
        XCTAssertEqual(r.file.path, "/Users/x/Desktop/(Students) Nov 18.mp4")
        XCTAssertEqual(r.inText, "00:44:01:20")
        XCTAssertEqual(r.outText, "01:23:08:07")
        XCTAssertTrue(r.detect)
    }

    func testURLSchemeExpandsTildeAndNeedsAPath() throws {
        let r = try XCTUnwrap(OpenRequest(url: URL(string: "sermontrim://open?file=~/Desktop/a.mp4")!))
        XCTAssertEqual(r.file.path, (("~/Desktop/a.mp4") as NSString).expandingTildeInPath)
        XCTAssertFalse(r.detect)
        XCTAssertNil(OpenRequest(url: URL(string: "sermontrim://open?in=10")!))
        XCTAssertNil(OpenRequest(url: URL(string: "https://example.com/a.mp4")!))
        XCTAssertNil(OpenRequest(url: URL(string: "sermontrim://export?path=/a.mp4")!))
    }

    func testLaunchArgumentsSkipSystemFlagsAndReadPoints() throws {
        let exists: (String) -> Bool = { $0 == "/v/a.mp4" }
        let r = try XCTUnwrap(OpenRequest.fromArguments(["-NSDocumentRevisionsDebugMode", "YES", "/v/a.mp4", "--in", "44:01", "--out", "5000", "--detect"], fileExists: exists))
        XCTAssertEqual(r.file.path, "/v/a.mp4")
        XCTAssertEqual(r.inText, "44:01")
        XCTAssertEqual(r.outText, "5000")
        XCTAssertTrue(r.detect)
        XCTAssertNil(OpenRequest.fromArguments(["/v/missing.mp4"], fileExists: exists))
        XCTAssertNil(OpenRequest.fromArguments([], fileExists: exists))
    }

    func testLaunchArgumentCanBeASchemeURL() throws {
        let r = try XCTUnwrap(OpenRequest.fromArguments(["sermontrim://open?path=/v/b.mp4&in=10"], fileExists: { _ in false }))
        XCTAssertEqual(r.file.path, "/v/b.mp4")
        XCTAssertEqual(r.inText, "10")
    }
}
