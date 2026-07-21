import XCTest
@testable import GraphicalCLI

final class CursorStreamJSONTests: XCTestCase {
    func testPassthroughForNonJSON() {
        var formatter = CursorStreamJSONFormatter()
        XCTAssertEqual(formatter.format(line: "hello world"), .passthrough)
        XCTAssertEqual(formatter.format(line: "not {json"), .passthrough)
    }

    func testSystemInitAndUserSkip() {
        var formatter = CursorStreamJSONFormatter()
        XCTAssertEqual(
            formatter.format(line: #"{"type":"system","subtype":"init","model":"composer"}"#),
            .display(["model composer"])
        )
        XCTAssertEqual(
            formatter.format(line: #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#),
            .skip
        )
    }

    func testAssistantCompleteMessageWithoutPartialMode() {
        var formatter = CursorStreamJSONFormatter()
        XCTAssertEqual(
            formatter.format(line: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello\nWorld"}]}}"#),
            .assistantText(["Hello", "World"])
        )
    }

    func testAssistantPartialDeltasSkipDuplicates() {
        var formatter = CursorStreamJSONFormatter()
        XCTAssertEqual(
            formatter.format(line: #"{"type":"assistant","timestamp_ms":1,"message":{"role":"assistant","content":[{"type":"text","text":"Hel"}]}}"#),
            .assistantText(["Hel"])
        )
        XCTAssertEqual(
            formatter.format(line: #"{"type":"assistant","timestamp_ms":2,"message":{"role":"assistant","content":[{"type":"text","text":"lo"}]}}"#),
            .assistantText(["lo"])
        )
        // Buffered flush before tool call
        XCTAssertEqual(
            formatter.format(line: #"{"type":"assistant","timestamp_ms":3,"model_call_id":"x","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}"#),
            .skip
        )
        // Final flush without timestamp after partials
        XCTAssertEqual(
            formatter.format(line: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}"#),
            .skip
        )
    }

    func testToolCallStartedLabels() {
        var formatter = CursorStreamJSONFormatter()
        XCTAssertEqual(
            formatter.format(line: #"{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":"README.md"}}}}"#),
            .display(["read README.md"])
        )
        XCTAssertEqual(
            formatter.format(line: #"{"type":"tool_call","subtype":"started","tool_call":{"writeToolCall":{"args":{"path":"out.md"}}}}"#),
            .display(["write out.md"])
        )
        XCTAssertEqual(
            formatter.format(line: #"{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"README.md"}}}}"#),
            .skip
        )
    }

    func testResultSkipped() {
        var formatter = CursorStreamJSONFormatter()
        XCTAssertEqual(
            formatter.format(line: #"{"type":"result","subtype":"success","result":"done"}"#),
            .skip
        )
    }
}
