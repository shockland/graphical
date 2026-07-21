import XCTest
@testable import GraphicalCLI
@testable import GraphicalEngine

final class UserErrorFormattingTests: XCTestCase {
    func testJoinsDiagnosisAndRecoveryForRunEngineError() {
        let error = RunEngineError.missingRunner("codex")
        let message = UserErrorFormatting.message(for: error)
        XCTAssertTrue(message.contains("Missing runner 'codex'"), message)
        XCTAssertTrue(message.contains("Agents"), message)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testExhaustedIterationsMessageIncludesFailedChecksAndRecovery() {
        let diagnosis = RunEngineError.exhaustedIterationsMessage(
            role: "Implementer",
            nodeId: "implementer",
            failedChecks: ["summary.txt", "shell:tests"]
        )
        XCTAssertTrue(diagnosis.contains("Implementer"), diagnosis)
        XCTAssertTrue(diagnosis.contains("summary.txt"), diagnosis)
        XCTAssertTrue(diagnosis.contains("shell:tests"), diagnosis)

        let error = RunEngineError.failed(diagnosis)
        XCTAssertNotNil(error.recoverySuggestion)
        let suggestion = error.recoverySuggestion ?? ""
        XCTAssertTrue(
            suggestion.lowercased().contains("retry") || suggestion.lowercased().contains("done-checks"),
            suggestion
        )

        let composed = UserErrorFormatting.message(for: error)
        XCTAssertTrue(composed.contains(diagnosis), composed)
        XCTAssertTrue(composed.contains(suggestion), composed)
    }

    func testRejectWithoutEdgeRecovery() {
        let diagnosis = RunEngineError.rejectWithoutEdgeMessage(role: "Solo", nodeId: "solo")
        let error = RunEngineError.failed(diagnosis)
        XCTAssertTrue(diagnosis.contains("Solo"), diagnosis)
        XCTAssertTrue(diagnosis.contains("reject"), diagnosis)
        let suggestion = error.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.contains("on: reject"), suggestion)
    }

    func testCancelledHasNoRecoverySuggestion() {
        XCTAssertNil(RunEngineError.cancelled.recoverySuggestion)
        XCTAssertEqual(UserErrorFormatting.message(for: RunEngineError.cancelled), "Run cancelled")
    }

    func testProcessRunnerLaunchFailedRecovery() {
        let error = ProcessRunnerError.launchFailed("No such file or directory")
        XCTAssertNotNil(error.recoverySuggestion)
        let message = UserErrorFormatting.message(for: error)
        XCTAssertTrue(message.contains("No such file or directory"), message)
        XCTAssertTrue(message.contains("PATH") || message.contains("Agents"), message)
    }
}
