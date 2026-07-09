import XCTest
@testable import OpenGlasses

/// Headless tests for the JSON Schema → Gemini `responseSchema` translation: uppercase types,
/// recursion through properties/items, enum + required preserved, unsupported keywords dropped.
final class GeminiSchemaTranslatorTests: XCTestCase {

    func testTypesAreUppercased() {
        XCTAssertEqual(GeminiSchemaTranslator.translate(["type": "object"])["type"] as? String, "OBJECT")
        XCTAssertEqual(GeminiSchemaTranslator.translate(["type": "string"])["type"] as? String, "STRING")
        XCTAssertEqual(GeminiSchemaTranslator.translate(["type": "number"])["type"] as? String, "NUMBER")
        XCTAssertEqual(GeminiSchemaTranslator.translate(["type": "integer"])["type"] as? String, "INTEGER")
        XCTAssertEqual(GeminiSchemaTranslator.translate(["type": "boolean"])["type"] as? String, "BOOLEAN")
        XCTAssertEqual(GeminiSchemaTranslator.translate(["type": "array"])["type"] as? String, "ARRAY")
    }

    func testNestedObjectWithEnumAndRequired() {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "value": ["type": "number", "description": "the reading"],
                "unit": ["type": "string", "enum": ["psi", "bar"]]
            ],
            "required": ["value"]
        ]
        let out = GeminiSchemaTranslator.translate(schema)
        XCTAssertEqual(out["type"] as? String, "OBJECT")
        XCTAssertEqual(out["required"] as? [String], ["value"])

        let props = out["properties"] as? [String: Any]
        let value = props?["value"] as? [String: Any]
        XCTAssertEqual(value?["type"] as? String, "NUMBER")
        XCTAssertEqual(value?["description"] as? String, "the reading")
        let unit = props?["unit"] as? [String: Any]
        XCTAssertEqual(unit?["type"] as? String, "STRING")
        XCTAssertEqual(unit?["enum"] as? [String], ["psi", "bar"])
    }

    func testArrayItemsRecurse() {
        let schema: [String: Any] = [
            "type": "array",
            "items": ["type": "object", "properties": ["label": ["type": "string"]]]
        ]
        let out = GeminiSchemaTranslator.translate(schema)
        XCTAssertEqual(out["type"] as? String, "ARRAY")
        let items = out["items"] as? [String: Any]
        XCTAssertEqual(items?["type"] as? String, "OBJECT")
        let itemProps = items?["properties"] as? [String: Any]
        XCTAssertEqual((itemProps?["label"] as? [String: Any])?["type"] as? String, "STRING")
    }

    func testUnsupportedKeywordsDropped() {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#",
            "minimum": 0,
            "properties": ["x": ["type": "integer", "default": 1]]
        ]
        let out = GeminiSchemaTranslator.translate(schema)
        XCTAssertNil(out["additionalProperties"])
        XCTAssertNil(out["$schema"])
        XCTAssertNil(out["minimum"])
        // The recursive call drops `default` too, keeping only the structural keys.
        let x = (out["properties"] as? [String: Any])?["x"] as? [String: Any]
        XCTAssertEqual(x?["type"] as? String, "INTEGER")
        XCTAssertNil(x?["default"])
    }

    func testNullablePreserved() {
        let out = GeminiSchemaTranslator.translate(["type": "string", "nullable": true])
        XCTAssertEqual(out["nullable"] as? Bool, true)
    }
}
