import XCTest
@testable import OpenGlasses

final class GatewayEndpointTests: XCTestCase {

    func testSanitizeAddsHTTPSForRemoteHost() {
        XCTAssertEqual(GatewayEndpoint.sanitize("maia.example.com"), "https://maia.example.com")
    }

    func testSanitizeAddsPort18789CandidateForBareDomain() {
        let bases = GatewayEndpoint.candidateBases(from: "maia.example.com")
        XCTAssertTrue(bases.contains("https://maia.example.com"))
        XCTAssertTrue(bases.contains("https://maia.example.com:18789"))
    }

    func testSanitizeStripsWSSuffix() {
        XCTAssertEqual(
            GatewayEndpoint.sanitize("https://maia.example.com/ws"),
            "https://maia.example.com"
        )
    }

    func testSanitizePreservesExplicitPort() {
        XCTAssertEqual(
            GatewayEndpoint.sanitize("https://maia.example.com:18789"),
            "https://maia.example.com:18789"
        )
        let bases = GatewayEndpoint.candidateBases(from: "https://maia.example.com:18789")
        XCTAssertEqual(bases, ["https://maia.example.com:18789"])
    }

    func testHealthURLCandidates() {
        let urls = GatewayEndpoint.healthURLCandidates(from: "vps.example.com")
        XCTAssertTrue(urls.contains(URL(string: "https://vps.example.com/health")!))
        XCTAssertTrue(urls.contains(URL(string: "https://vps.example.com:18789/health")!))
    }

    func testLANHostUsesHTTP() {
        XCTAssertEqual(GatewayEndpoint.sanitize("192.168.1.10:18789"), "http://192.168.1.10:18789")
    }

    func testHealthProbeRequestsIncludeNoAuthFirst() {
        let requests = GatewayEndpoint.healthProbeRequests(from: "vps.example.com", token: "secret")
        XCTAssertFalse(requests.isEmpty)
        XCTAssertEqual(requests.first?.style, .none)
        XCTAssertTrue(requests.contains { $0.style == .bearer })
    }

    func testHermesHostDetection() {
        XCTAssertTrue(GatewayEndpoint.isHermesHost("https://aicontexteng.com"))
        XCTAssertTrue(GatewayEndpoint.isHermesHost("hermes.aicontexteng.com"))
        XCTAssertTrue(GatewayEndpoint.isHermesHost("46.202.189.72"))
        XCTAssertFalse(GatewayEndpoint.isHermesHost("https://srv753644.hstgr.cloud"))
    }

    func testPreferMaiaEndpointRewritesHermes() {
        XCTAssertEqual(
            GatewayEndpoint.preferMaiaEndpoint("https://aicontexteng.com"),
            GatewayEndpoint.defaultMaiaGatewayURL
        )
        XCTAssertEqual(
            GatewayEndpoint.preferMaiaEndpoint("https://srv753644.hstgr.cloud"),
            "https://srv753644.hstgr.cloud"
        )
    }
}