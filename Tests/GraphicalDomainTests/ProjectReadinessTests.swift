import XCTest
@testable import GraphicalDomain

final class ProjectReadinessTests: XCTestCase {
    func testSeededDemoBecomesReadyInRecommendedOrder() {
        let org = SeedTemplate.plannerImplementerReviewer()
        let runners = SeedTemplate.defaultRunners()

        let missingGoal = ProjectReadiness.derive(
            goal: "  ",
            org: org,
            runners: runners,
            firstRunComplete: false
        )
        XCTAssertFalse(missingGoal.goalPresent)
        XCTAssertTrue(missingGoal.usableAgentSelected)
        XCTAssertTrue(missingGoal.graphValid)
        XCTAssertFalse(missingGoal.firstRunComplete)
        XCTAssertEqual(missingGoal.nextRecommendedAction, .setGoal)

        let readyToRun = ProjectReadiness.derive(
            goal: "Build the feature",
            org: org,
            runners: runners,
            firstRunComplete: false
        )
        XCTAssertTrue(readyToRun.canRun)
        XCTAssertFalse(readyToRun.isReady)
        XCTAssertEqual(readyToRun.nextRecommendedAction, .runFirstWorkflow)

        let complete = ProjectReadiness.derive(
            goal: "Build the feature",
            org: org,
            runners: runners,
            firstRunComplete: true
        )
        XCTAssertTrue(complete.isReady)
        XCTAssertEqual(complete.nextRecommendedAction, .none)
    }

    func testUnknownOrEmptyRunnerIsNotUsableBeforeGraphRepair() {
        var org = SeedTemplate.plannerImplementerReviewer()
        org.nodes[0].runner = "missing"

        let unknown = ProjectReadiness.derive(
            goal: "Ship",
            org: org,
            runners: SeedTemplate.defaultRunners(),
            firstRunComplete: false
        )
        XCTAssertFalse(unknown.usableAgentSelected)
        XCTAssertFalse(unknown.graphValid)
        XCTAssertEqual(unknown.nextRecommendedAction, .selectAgent)

        org.nodes[0].runner = "empty"
        var runners = SeedTemplate.defaultRunners()
        runners.runners["empty"] = RunnerTemplate(command: "  ")
        let empty = ProjectReadiness.derive(
            goal: "Ship",
            org: org,
            runners: runners,
            firstRunComplete: false
        )
        XCTAssertFalse(empty.usableAgentSelected)
        XCTAssertEqual(empty.nextRecommendedAction, .selectAgent)
    }

    func testKnownRunnersDoNotHideOtherGraphValidationFailures() {
        var org = SeedTemplate.plannerImplementerReviewer()
        org.edges[0].targets = ["missing-node"]

        let readiness = ProjectReadiness.derive(
            goal: "Ship",
            org: org,
            runners: SeedTemplate.defaultRunners(),
            firstRunComplete: false
        )

        XCTAssertTrue(readiness.usableAgentSelected)
        XCTAssertFalse(readiness.graphValid)
        XCTAssertEqual(readiness.nextRecommendedAction, .fixGraph)
    }
}
