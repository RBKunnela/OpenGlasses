import XCTest
@testable import OpenGlasses

/// Tests for the AED finder (First-Aid / Emergency Assist): Overpass query/parse/nearest, all headless
/// with an injected fetcher.
final class AEDFinderTests: XCTestCase {

    func testOverpassURLContainsTheQuery() {
        let url = AEDFinder.overpassURL(latitude: 37.7749, longitude: -122.4194, radiusMeters: 1500)
        XCTAssertEqual(url.host, "overpass-api.de")
        let decoded = url.absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(decoded.contains("emergency=defibrillator"))
        XCTAssertTrue(decoded.contains("around:1500,37.7749,-122.4194"))
    }

    func testParseFixture() throws {
        let json = """
        {"elements":[
          {"type":"node","lat":37.7750,"lon":-122.4190,"tags":{"name":"Library AED"}},
          {"type":"node","lat":37.7800,"lon":-122.4100}
        ]}
        """.data(using: .utf8)!
        let aeds = try AEDFinder.parse(json)
        XCTAssertEqual(aeds.count, 2)
        XCTAssertEqual(aeds[0].name, "Library AED")
        XCTAssertNil(aeds[1].name)
    }

    func testParseSkipsElementsWithoutCoordinates() throws {
        let json = #"{"elements":[{"type":"way","tags":{"name":"no coords"}}]}"#.data(using: .utf8)!
        XCTAssertTrue(try AEDFinder.parse(json).isEmpty)
    }

    func testNearestPicksClosestByHaversine() {
        let here = (lat: 37.7749, lon: -122.4194)
        let near = AED(latitude: 37.7750, longitude: -122.4190, name: "near")
        let far = AED(latitude: 37.9000, longitude: -122.3000, name: "far")
        XCTAssertEqual(AEDFinder.nearest([far, near], toLat: here.lat, lon: here.lon)?.name, "near")
    }

    func testNearestOfEmptyIsNil() {
        XCTAssertNil(AEDFinder.nearest([], toLat: 0, lon: 0))
    }

    func testDistanceMetersIsSane() {
        // ~111 km per degree of latitude near the equator.
        let d = AEDFinder.distanceMeters(fromLat: 0, lon: 0, toLat: 1, lon: 0)
        XCTAssertEqual(d, 111_195, accuracy: 2_000)
    }

    func testNearestAEDEndToEndWithInjectedFetch() async throws {
        let fixture = """
        {"elements":[
          {"type":"node","lat":37.9000,"lon":-122.3000,"tags":{"name":"far"}},
          {"type":"node","lat":37.7750,"lon":-122.4190,"tags":{"name":"near"}}
        ]}
        """.data(using: .utf8)!
        let finder = AEDFinder(fetch: { _ in fixture })
        let aed = try await finder.nearestAED(latitude: 37.7749, longitude: -122.4194)
        XCTAssertEqual(aed?.name, "near")
    }

    func testNearestAEDReturnsNilWhenNoneFound() async throws {
        let finder = AEDFinder(fetch: { _ in #"{"elements":[]}"#.data(using: .utf8)! })
        let aed = try await finder.nearestAED(latitude: 0, longitude: 0)
        XCTAssertNil(aed)
    }
}
