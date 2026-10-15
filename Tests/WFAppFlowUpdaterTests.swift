import XCTest
import Foundation

/// Stubs URLSession.shared for one fake host so Updater.checkRelease never reaches the network.
final class WFStubURLProtocol: URLProtocol {
    static let host = "updates.sermontrim.test"
    /// (status, body) to answer with, or nil to fail with a network error.
    static var response: (Int, Data)?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let (status, body) = Self.response else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WFAppFlowUpdaterTests: XCTestCase {
    static var previousURL: String?
    override class func setUp() {
        super.setUp()
        // Read once by Updater.releasesURL (a static let), so set it before anything touches Updater.
        previousURL = ProcessInfo.processInfo.environment["SERMONTRIM_RELEASES_URL"]
        setenv("SERMONTRIM_RELEASES_URL", "https://\(WFStubURLProtocol.host)/repos/x/releases/latest", 1)
        URLProtocol.registerClass(WFStubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(WFStubURLProtocol.self)
        if let previousURL { setenv("SERMONTRIM_RELEASES_URL", previousURL, 1) }
        else { unsetenv("SERMONTRIM_RELEASES_URL") }
        super.tearDown()
    }

    override func setUp() { WFStubURLProtocol.response = nil; WFStubURLProtocol.requests = [] }

    // MARK: isNewer

    func testIsNewerComparesNumericallyPartByPart() {
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(Updater.isNewer("1.9", than: "1.10"))
        XCTAssertTrue(Updater.isNewer("1.2.1", than: "1.2"))
        XCTAssertTrue(Updater.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(Updater.isNewer("1.2.0", than: "1.2.1"), "an older release is never an update")
        XCTAssertFalse(Updater.isNewer("1.0", than: "10.0"))
        XCTAssertTrue(Updater.isNewer("10.0", than: "9.9"))
    }

    func testIsNewerTreatsEqualVersionsAndMissingPartsAsSame() {
        XCTAssertFalse(Updater.isNewer("1.2", than: "1.2"))
        XCTAssertFalse(Updater.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(Updater.isNewer("1.2.0", than: "1.2"))
        // Non-numeric parts count as 0: "1.2-beta" reads as 1.0.
        XCTAssertFalse(Updater.isNewer("1.2-beta", than: "1.1"))
        XCTAssertTrue(Updater.isNewer("1.1", than: "1.2-beta"))
    }

    // MARK: checkRelease

    func release(tag: String, assets: [String]) -> Data {
        let a = assets.map { "{\"name\":\"\($0)\",\"browser_download_url\":\"https://\(WFStubURLProtocol.host)/\($0)\",\"digest\":null}" }
        return Data("{\"tag_name\":\"\(tag)\",\"body\":\"notes\",\"assets\":[\(a.joined(separator: ","))]}".utf8)
    }

    func testReleasesURLComesFromTheEnvironment() {
        XCTAssertEqual(Updater.releasesURL, "https://\(WFStubURLProtocol.host)/repos/x/releases/latest")
    }

    func testNotFoundMeansUpToDate() async throws {
        try XCTSkipUnless(Updater.releasesURL.contains(WFStubURLProtocol.host), "releases URL not redirected to the stub")
        WFStubURLProtocol.response = (404, Data("{}".utf8))
        guard case .upToDate = await Updater.checkRelease() else { return XCTFail("404 should mean nothing published yet") }
        XCTAssertEqual(WFStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testServerErrorFails() async throws {
        try XCTSkipUnless(Updater.releasesURL.contains(WFStubURLProtocol.host))
        WFStubURLProtocol.response = (500, Data())
        guard case .failed(let m) = await Updater.checkRelease() else { return XCTFail("expected failure") }
        XCTAssertTrue(m.contains("500"), m)
    }

    func testReleaseWithoutDMGFails() async throws {
        try XCTSkipUnless(Updater.releasesURL.contains(WFStubURLProtocol.host))
        WFStubURLProtocol.response = (200, release(tag: "v9999.0", assets: ["notes.txt"]))
        guard case .failed(let m) = await Updater.checkRelease() else { return XCTFail("expected failure") }
        XCTAssertTrue(m.contains("no download"), m)
    }

    func testNewerReleaseIsOfferedAndOlderIsNot() async throws {
        try XCTSkipUnless(Updater.releasesURL.contains(WFStubURLProtocol.host))
        WFStubURLProtocol.response = (200, release(tag: "v9999.0", assets: ["Sermon Trim.DMG"]))
        guard case .available(let r) = await Updater.checkRelease() else { return XCTFail("expected an update") }
        XCTAssertEqual(r.version, "9999.0")
        XCTAssertEqual(r.dmg?.name, "Sermon Trim.DMG")

        WFStubURLProtocol.response = (200, release(tag: "v0", assets: ["Sermon Trim.dmg"]))
        guard case .upToDate = await Updater.checkRelease() else { return XCTFail("an older release is not an update") }
    }

    func testNetworkErrorGivesAMessage() async throws {
        try XCTSkipUnless(Updater.releasesURL.contains(WFStubURLProtocol.host))
        WFStubURLProtocol.response = nil
        guard case .failed(let m) = await Updater.checkRelease() else { return XCTFail("expected failure") }
        XCTAssertTrue(m.hasPrefix("Couldn't reach GitHub"), m)
    }

    func testMalformedJSONFails() async throws {
        try XCTSkipUnless(Updater.releasesURL.contains(WFStubURLProtocol.host))
        WFStubURLProtocol.response = (200, Data("not json".utf8))
        guard case .failed = await Updater.checkRelease() else { return XCTFail("expected failure") }
    }
}
