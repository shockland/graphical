import XCTest
@testable import GraphicalCLI

final class SetupSessionTests: XCTestCase {
    func testFirstRunRequiresGoalBeforeContinue() {
        var session = SetupSession(mode: .firstRun, goal: "", selectedPresetID: "demo")
        XCTAssertEqual(session.currentStep, .goal)
        XCTAssertEqual(session.meshWidth, 3)
        XCTAssertFalse(session.canContinue)
        XCTAssertFalse(session.advance())
        XCTAssertFalse(session.isReadyToFinish)

        session.goal = "Ship the feature"
        XCTAssertTrue(session.canContinue)
        XCTAssertTrue(session.advance())
        XCTAssertEqual(session.currentStep, .codingTool)
    }

    func testMeshWidthClampsToValidatorBounds() {
        let low = SetupSession(mode: .firstRun, meshWidth: 1)
        XCTAssertEqual(low.meshWidth, 2)
        let high = SetupSession(mode: .firstRun, meshWidth: 99)
        XCTAssertEqual(high.meshWidth, 8)
    }

    func testParallelFanOutDefaultsOn() {
        let session = SetupSession(mode: .firstRun)
        XCTAssertTrue(session.parallelFanOut)
    }

    func testFirstRunIsTwoStepsAndFinishesOnCodingTool() {
        var session = SetupSession(mode: .firstRun, goal: "Ship it", selectedPresetID: "demo")
        XCTAssertEqual(SetupSession.Step.allCases.count, 2)
        XCTAssertTrue(session.advance())
        XCTAssertEqual(session.currentStep, .codingTool)
        XCTAssertTrue(session.isReadyToFinish)
        XCTAssertTrue(session.canContinue)
        // No workflow preview step — advance past coding tool is not allowed.
        XCTAssertFalse(session.advance())
        XCTAssertEqual(session.currentStep, .codingTool)
        XCTAssertTrue(session.back())
        XCTAssertEqual(session.currentStep, .goal)
        XCTAssertFalse(session.isReadyToFinish)
    }

    func testCodingToolOnlyStartsOnToolStepAndAllowsMissingSelection() {
        var session = SetupSession(
            mode: .codingToolOnly,
            goal: "",
            selectedPresetID: "claude-code"
        )
        XCTAssertEqual(session.currentStep, .codingTool)
        XCTAssertTrue(session.canContinue)
        XCTAssertTrue(session.isReadyToFinish)
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.advance())
        XCTAssertFalse(session.back())
    }

    func testCodingToolOnlyRequiresPresetSelection() {
        var session = SetupSession(
            mode: .codingToolOnly,
            selectedPresetID: nil
        )
        XCTAssertFalse(session.canContinue)
        XCTAssertFalse(session.isReadyToFinish)
        session.selectedPresetID = "demo"
        XCTAssertTrue(session.canContinue)
        XCTAssertTrue(session.isReadyToFinish)
    }
}
