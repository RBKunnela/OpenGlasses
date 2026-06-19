import XCTest
@testable import OpenGlasses

/// Tests for `StructuredVisionParser` (structured-vision Phase 2) — pure extraction of the assessment
/// JSON object from recorded provider response bodies, including the text fallback when the model
/// answers with prose JSON instead of a forced tool/function call. Headless — no network.
final class StructuredVisionParserTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Anthropic

    func testAnthropicForcedToolUse() {
        let body = """
        {"content":[
          {"type":"tool_use","name":"assessment","input":{"tier":"critical","confidence":0.9}}
        ]}
        """
        let obj = StructuredVisionParser.anthropic(data(body), toolName: "assessment")
        XCTAssertEqual(obj?["tier"] as? String, "critical")
        XCTAssertEqual(obj?["confidence"] as? Double, 0.9)
    }

    func testAnthropicFallsBackToTextBlock() {
        let body = #"{"content":[{"type":"text","text":"```json\n{\"tier\":\"ok\"}\n```"}]}"#
        XCTAssertEqual(StructuredVisionParser.anthropic(data(body), toolName: "assessment")?["tier"] as? String, "ok")
    }

    func testAnthropicWrongToolNameNoTextReturnsNil() {
        let body = #"{"content":[{"type":"tool_use","name":"other","input":{"tier":"ok"}}]}"#
        XCTAssertNil(StructuredVisionParser.anthropic(data(body), toolName: "assessment"))
    }

    func testAnthropicEmptyToolNameMatchesAny() {
        let body = #"{"content":[{"type":"tool_use","name":"whatever","input":{"tier":"caution"}}]}"#
        XCTAssertEqual(StructuredVisionParser.anthropic(data(body))?["tier"] as? String, "caution")
    }

    // MARK: - OpenAI-compatible

    func testOpenAIFunctionArguments() {
        let body = """
        {"choices":[{"message":{"role":"assistant","tool_calls":[
          {"type":"function","function":{"name":"assessment","arguments":"{\\"tier\\":\\"caution\\",\\"summary\\":\\"x\\"}"}}
        ]}}]}
        """
        let obj = StructuredVisionParser.openAI(data(body))
        XCTAssertEqual(obj?["tier"] as? String, "caution")
        XCTAssertEqual(obj?["summary"] as? String, "x")
    }

    func testOpenAIFallsBackToContent() {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"{\"tier\":\"ok\"}"}}]}"#
        XCTAssertEqual(StructuredVisionParser.openAI(data(body))?["tier"] as? String, "ok")
    }

    func testOpenAIMalformedReturnsNil() {
        XCTAssertNil(StructuredVisionParser.openAI(data(#"{"choices":[]}"#)))
    }

    // MARK: - Gemini

    func testGeminiJSONTextPart() {
        let body = #"{"candidates":[{"content":{"parts":[{"text":"{\"tier\":\"critical\"}"}]}}]}"#
        XCTAssertEqual(StructuredVisionParser.gemini(data(body))?["tier"] as? String, "critical")
    }

    func testGeminiFunctionCallArgs() {
        let body = #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"assessment","args":{"tier":"ok"}}}]}}]}"#
        XCTAssertEqual(StructuredVisionParser.gemini(data(body))?["tier"] as? String, "ok")
    }

    func testGeminiMalformedReturnsNil() {
        XCTAssertNil(StructuredVisionParser.gemini(data(#"{"candidates":[]}"#)))
    }
}
