import XCTest
@testable import GraphicalDomain

final class RunProgressCopyTests: XCTestCase {
    private func sampleOrg() -> OrgGraph {
        OrgGraph(
            nodes: [
                OrgNode(
                    id: "planner",
                    role: "Planner",
                    runner: "echo_fixture",
                    done: .allOf([.artifact("plan.md")]),
                    maxIterations: 2
                ),
                OrgNode(
                    id: "implementer",
                    role: "Implementer",
                    runner: "echo_fixture",
                    done: .allOf([.artifact("implementation.md")]),
                    maxIterations: 3
                ),
                OrgNode(
                    id: "reviewer",
                    role: "Reviewer",
                    runner: "echo_fixture",
                    done: .allOf([.artifact("review.md")]),
                    maxIterations: 2
                )
            ],
            edges: [
                OrgEdge(
                    from: "planner",
                    type: .router,
                    targets: ["implementer", "reviewer"]
                ),
                OrgEdge(from: "implementer", to: "reviewer", type: .fixed),
                OrgEdge(from: "reviewer", to: "implementer", type: .fixed, on: .reject)
            ],
            entry: "planner"
        )
    }

    func testSuccessNextNodeIdsSkipsRejectEdges() {
        let org = sampleOrg()
        XCTAssertEqual(org.successNextNodeIds(from: "planner"), ["implementer", "reviewer"])
        XCTAssertEqual(org.successNextNodeIds(from: "implementer"), ["reviewer"])
        XCTAssertEqual(org.successNextNodeIds(from: "reviewer"), [])
    }

    func testRunningShowsAgentAttemptsLeftAndNext() {
        let copy = RunProgressCopy.make(
            status: .running,
            activeNodeId: "planner",
            phase: "waiting for agent · 0:12",
            iteration: 1,
            org: sampleOrg(),
            runId: "abcdefgh-1234",
            isRunning: true
        )
        XCTAssertTrue(copy.headline.contains("Planner is working"))
        XCTAssertTrue(copy.headline.contains("attempt 1 of 2 (1 left)"))
        XCTAssertTrue(copy.headline.contains("waiting for agent"))
        XCTAssertEqual(copy.detail, "Next: Implementer or Reviewer")
        XCTAssertTrue(copy.statusBar.contains("Planner is working"))
        XCTAssertTrue(copy.statusBar.contains("Next: Implementer or Reviewer"))
        XCTAssertTrue(copy.runInfo.contains("run abcdefgh"))
    }

    func testKnownNextOverridesRouterCandidates() {
        let copy = RunProgressCopy.make(
            status: .running,
            activeNodeId: "planner",
            phase: "handoff to implementer",
            iteration: 2,
            org: sampleOrg(),
            knownNextNodeId: "implementer",
            isRunning: true
        )
        XCTAssertTrue(copy.headline.contains("last try"))
        XCTAssertTrue(copy.headline.contains("handing off to Implementer"))
        XCTAssertEqual(copy.detail, "Next: Implementer")
    }

    func testFinalStepWhenNoSuccessOutbound() {
        let copy = RunProgressCopy.make(
            status: .running,
            activeNodeId: "reviewer",
            phase: "evaluating checks",
            iteration: 1,
            org: sampleOrg(),
            isRunning: true
        )
        XCTAssertEqual(copy.detail, "Final step — done after this")
        XCTAssertTrue(copy.headline.contains("checking if step is done"))
    }

    func testAwaitingApprovalNamesNextAgent() {
        let copy = RunProgressCopy.make(
            status: .awaitingApproval,
            activeNodeId: "planner",
            phase: "awaiting approval",
            iteration: 1,
            org: sampleOrg(),
            knownNextNodeId: "implementer",
            isRunning: false
        )
        XCTAssertTrue(copy.headline.contains("approve handoff to Implementer"))
        XCTAssertTrue(copy.statusBar.contains("next Implementer"))
    }

    func testSucceededCopy() {
        let copy = RunProgressCopy.make(
            status: .succeeded,
            activeNodeId: nil,
            phase: nil,
            iteration: nil,
            org: sampleOrg(),
            isRunning: false
        )
        XCTAssertEqual(copy.headline, "Done — all steps finished")
        XCTAssertEqual(copy.statusBar, "Done — all steps finished")
    }

    func testActivityTextJoinsDetail() {
        let copy = RunProgressCopy(
            headline: "Planner is working",
            detail: "Next: Implementer",
            statusBar: "x",
            runInfo: "y"
        )
        XCTAssertEqual(copy.activityText, "Planner is working\nNext: Implementer")
    }
}
