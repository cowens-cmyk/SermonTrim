import XCTest

final class ErrorExplainerTests: XCTestCase {
    let generic = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
        NSLocalizedDescriptionKey: "The operation could not be completed",
        NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -17913),
    ])
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-err-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileIsExplained() {
        let e = ErrorExplainer.explain(generic, operation: "Opening the video", input: dir.appendingPathComponent("gone.mp4"))
        XCTAssertTrue(e.message.contains("isn't there any more"))
        XCTAssertFalse(e.isPermission)
    }

    func testUnreadableFileIsReportedAsPermissionProblem() throws {
        let f = dir.appendingPathComponent("locked.mp4")
        try Data([1, 2, 3]).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        let e = ErrorExplainer.explain(generic, operation: "Opening the video", input: f)
        XCTAssertTrue(e.isPermission)
        XCTAssertTrue(e.message.contains("Privacy & Security"))
    }

    func testReadOnlyOutputFolderIsReported() throws {
        let f = dir.appendingPathComponent("ok.mp4")
        try Data([1, 2, 3]).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let e = ErrorExplainer.explain(generic, operation: "Export", input: f, outputFolder: dir)
        XCTAssertTrue(e.isPermission)
        XCTAssertTrue(e.message.contains("can't save"))
    }

    func testGenericFallbackIncludesErrorCodes() throws {
        let f = dir.appendingPathComponent("ok.mp4")
        try Data([1, 2, 3]).write(to: f)
        let e = ErrorExplainer.explain(generic, operation: "Export", input: f, outputFolder: dir)
        XCTAssertTrue(e.message.contains("-11800"))
        XCTAssertTrue(e.message.contains("-17913"))
    }

    func testNotEnoughSpaceMessage() {
        XCTAssertThrowsError(try ErrorExplainer.checkSpace(for: dir.appendingPathComponent("x.mp4"), needing: Int64.max / 4)) { err in
            XCTAssertTrue((err as? ExportError)?.localizedDescription.contains("free space") == true)
        }
    }
}
