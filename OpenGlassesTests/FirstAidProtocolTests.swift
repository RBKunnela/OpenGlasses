import XCTest
@testable import OpenGlasses

/// Tests for the first-aid protocol catalog + runner (First-Aid / Emergency Assist).
final class FirstAidProtocolTests: XCTestCase {

    func testCatalogHasTheCoreProtocols() {
        let ids = Set(FirstAidProtocol.ids)
        XCTAssertTrue(ids.isSuperset(of: ["cpr", "choking", "bleeding", "recovery", "march"]))
    }

    func testEveryProtocolStartsWithTheEmergencyGate() {
        for proto in FirstAidProtocol.catalog {
            XCTAssertTrue(proto.firstStep.isEmergencyGate, "\(proto.id) must open with the emergency gate")
            XCTAssertEqual(proto.firstStep.id, "call_emergency")
        }
    }

    func testNamedLookupIsCaseInsensitive() {
        XCTAssertEqual(FirstAidProtocol.named("CPR")?.id, "cpr")
        XCTAssertEqual(FirstAidProtocol.named("bleeding")?.id, "bleeding")
        XCTAssertNil(FirstAidProtocol.named("nonsense"))
    }

    func testCPRHasACompressionStep() {
        let cpr = FirstAidProtocol.named("cpr")!
        XCTAssertTrue(cpr.steps.contains { $0.startsCPR })
    }

    func testRunnerAdvancesThenStopsAtLastStep() {
        var runner = FirstAidProtocolRunner(proto: FirstAidProtocol.named("recovery")!)
        XCTAssertTrue(runner.current.isEmergencyGate)   // starts at the gate
        var steps = 1
        while runner.advance() != nil { steps += 1 }
        XCTAssertEqual(steps, FirstAidProtocol.named("recovery")!.steps.count)
        XCTAssertNil(runner.advance())                  // already at the end
        XCTAssertTrue(runner.isOnLastStep)
    }

    func testRunnerBackClampsAtTheGate() {
        var runner = FirstAidProtocolRunner(proto: FirstAidProtocol.named("cpr")!)
        runner.advance()
        runner.advance()
        runner.back()
        XCTAssertEqual(runner.index, 1)
        runner.back()
        runner.back()                                   // clamp
        XCTAssertEqual(runner.index, 0)
        XCTAssertTrue(runner.current.isEmergencyGate)
    }

    func testStepIdsAreUniqueWithinAProtocol() {
        for proto in FirstAidProtocol.catalog {
            XCTAssertEqual(Set(proto.steps.map(\.id)).count, proto.steps.count, "\(proto.id) has duplicate step ids")
        }
    }
}
