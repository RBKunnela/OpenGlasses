import XCTest
@testable import OpenGlasses

/// Tests for `UnitNormalizer` — the deterministic unit conversion behind the "read the instrument"
/// capability (structured-vision plan). Pure/headless: no model, no network.
final class UnitNormalizerTests: XCTestCase {

    private let acc = 0.0001

    // MARK: - Temperature (canonical °C)

    func testFahrenheitToCanonicalCelsius() {
        XCTAssertEqual(UnitNormalizer.canonical(value: 32, unit: "°F")!.value, 0, accuracy: acc)
        XCTAssertEqual(UnitNormalizer.canonical(value: 212, unit: "F")!.value, 100, accuracy: acc)
        XCTAssertEqual(UnitNormalizer.canonical(value: 98.6, unit: "fahrenheit")!.value, 37, accuracy: 0.01)
        XCTAssertEqual(UnitNormalizer.canonical(value: 32, unit: "°F")!.unit, "°C")
    }

    func testCelsiusIsIdentity() {
        let c = UnitNormalizer.canonical(value: 4, unit: "°C")!
        XCTAssertEqual(c.value, 4, accuracy: acc)
        XCTAssertEqual(c.unit, "°C")
    }

    func testConvertCelsiusToFahrenheit() {
        XCTAssertEqual(UnitNormalizer.convert(100, from: "C", to: "F")!, 212, accuracy: acc)
        XCTAssertEqual(UnitNormalizer.convert(37, from: "celsius", to: "fahrenheit")!, 98.6, accuracy: 0.01)
    }

    // MARK: - Pressure (canonical kPa)

    func testPressureToCanonicalKPa() {
        XCTAssertEqual(UnitNormalizer.canonical(value: 100, unit: "psi")!.value, 689.4757, accuracy: 0.001)
        XCTAssertEqual(UnitNormalizer.canonical(value: 1, unit: "bar")!.value, 100, accuracy: acc)
        XCTAssertEqual(UnitNormalizer.canonical(value: 1, unit: "inHg")!.value, 3.386389, accuracy: 0.0001)
        XCTAssertEqual(UnitNormalizer.canonical(value: 50, unit: "kPa")!.unit, "kPa")
    }

    func testPsigTreatedAsPsiMagnitude() {
        XCTAssertEqual(UnitNormalizer.canonical(value: 100, unit: " psig ")!.value,
                       UnitNormalizer.canonical(value: 100, unit: "psi")!.value, accuracy: acc)
    }

    // MARK: - Mass (canonical kg)

    func testMassToCanonicalKg() {
        XCTAssertEqual(UnitNormalizer.canonical(value: 1, unit: "lb")!.value, 0.45359237, accuracy: acc)
        XCTAssertEqual(UnitNormalizer.canonical(value: 1000, unit: "g")!.value, 1, accuracy: acc)
        XCTAssertEqual(UnitNormalizer.canonical(value: 16, unit: "oz")!.value, 0.45359237, accuracy: 0.001)
        XCTAssertEqual(UnitNormalizer.convert(2.2046226, from: "lbs", to: "kg")!, 1, accuracy: 0.0001)
    }

    // MARK: - Identity dimensions

    func testBrixAndVoltageAreIdentity() {
        XCTAssertEqual(UnitNormalizer.canonical(value: 12.5, unit: "°Bx")!.value, 12.5, accuracy: acc)
        XCTAssertEqual(UnitNormalizer.canonical(value: 12.5, unit: "brix")!.unit, "°Bx")
        XCTAssertEqual(UnitNormalizer.canonical(value: 240, unit: "V")!.value, 240, accuracy: acc)
    }

    // MARK: - Failure modes

    func testUnknownUnitReturnsNil() {
        XCTAssertNil(UnitNormalizer.canonical(value: 1, unit: "furlongs"))
        XCTAssertNil(UnitNormalizer.canonical(value: 1, unit: "%"))
    }

    func testConvertAcrossDimensionsReturnsNil() {
        XCTAssertNil(UnitNormalizer.convert(1, from: "psi", to: "kg"))
        XCTAssertNil(UnitNormalizer.convert(1, from: "°F", to: "bar"))
    }
}
