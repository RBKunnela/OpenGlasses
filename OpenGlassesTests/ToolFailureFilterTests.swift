import XCTest
@testable import OpenGlasses

/// Headless tests for the tool-failure filter that gates what the evolution loop records — genuine
/// execution errors in, transient/intentional noise out.
final class ToolFailureFilterTests: XCTestCase {

    func testGenuineToolErrorIsRecorded() {
        XCTAssertTrue(ToolFailureFilter.shouldRecord("Tool error: the network connection was lost"))
    }

    func testTimeoutIsNotRecorded() {
        XCTAssertFalse(ToolFailureFilter.shouldRecord("Tool 'web_search' timed out after 30s"))
    }

    func testSafetyAndDeclineOutcomesNotRecorded() {
        XCTAssertFalse(ToolFailureFilter.shouldRecord("'delete_all' was blocked by a safety rule (irreversible)."))
        XCTAssertFalse(ToolFailureFilter.shouldRecord("The user did NOT approve this action, so 'send' was not performed."))
        XCTAssertFalse(ToolFailureFilter.shouldRecord("Unknown tool: frobnicate"))
    }

    func testUnrelatedFailureNotRecorded() {
        XCTAssertFalse(ToolFailureFilter.shouldRecord("Some other message without the marker"))
    }
}
