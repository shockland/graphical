import XCTest
@testable import GraphicalDomain

/// Table-driven characterization tests for `OrgValidator` (plans/012): one row
/// per `OrgValidationIssue` case, each with a minimal fixture org that should
/// trigger exactly that issue kind. `YAMLStoreTests` already covers a couple of
/// these incidentally; this file is the authoritative, exhaustive table so a new
/// `OrgValidationIssue` case without a matching row is easy to spot in review.
final class OrgValidatorTests: XCTestCase {
    private struct Case {
        let name: String
        let org: OrgGraph
        let runners: RunnersConfig
        let matches: (OrgValidationIssue) -> Bool
    }

    private static let defaultRunners = RunnersConfig(runners: ["echo_fixture": RunnerTemplate(command: "/bin/echo")])

    private func node(
        id: String,
        runner: String = "echo_fixture",
        maxIterations: Int = 1,
        done: DoneCheckGroup = .allOf([.artifact("output.md")])
    ) -> OrgNode {
        OrgNode(id: id, role: "Role", runner: runner, done: done, maxIterations: maxIterations)
    }

    private var cases: [Case] {
        [
            Case(
                name: "emptyOrg",
                org: OrgGraph(nodes: [], edges: [], entry: nil),
                runners: Self.defaultRunners,
                matches: { if case .emptyOrg = $0 { return true }; return false }
            ),
            Case(
                name: "missingEntry",
                org: OrgGraph(nodes: [node(id: "a")], edges: [], entry: "ghost"),
                runners: Self.defaultRunners,
                matches: { if case .missingEntry(let id) = $0 { return id == "ghost" }; return false }
            ),
            Case(
                name: "danglingEdge (unknown from)",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "ghost", to: "a", type: .fixed)],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .danglingEdge(_, let nodeId) = $0 { return nodeId == "ghost" }; return false }
            ),
            Case(
                name: "danglingEdge (unknown fixed to)",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "a", to: "ghost", type: .fixed)],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .danglingEdge(_, let nodeId) = $0 { return nodeId == "ghost" }; return false }
            ),
            Case(
                name: "routerWithoutTargets",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "a", type: .router, targets: [])],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .routerWithoutTargets = $0 { return true }; return false }
            ),
            Case(
                name: "routerTargetUnknown",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "a", type: .router, targets: ["ghost"])],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .routerTargetUnknown(_, let target) = $0 { return target == "ghost" }; return false }
            ),
            Case(
                name: "fixedEdgeMissingTo",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "a", to: nil, type: .fixed)],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .fixedEdgeMissingTo = $0 { return true }; return false }
            ),
            Case(
                name: "duplicateNodeId",
                org: OrgGraph(nodes: [node(id: "a"), node(id: "a")], edges: [], entry: "a"),
                runners: Self.defaultRunners,
                matches: { if case .duplicateNodeId(let id) = $0 { return id == "a" }; return false }
            ),
            Case(
                name: "unknownRunner",
                org: OrgGraph(nodes: [node(id: "a", runner: "ghost_runner")], edges: [], entry: "a"),
                runners: Self.defaultRunners,
                matches: { if case .unknownRunner(_, let runner) = $0 { return runner == "ghost_runner" }; return false }
            ),
            Case(
                name: "maxIterationsInvalid",
                org: OrgGraph(nodes: [node(id: "a", maxIterations: 0)], edges: [], entry: "a"),
                runners: Self.defaultRunners,
                matches: { if case .maxIterationsInvalid(let id) = $0 { return id == "a" }; return false }
            ),
            Case(
                name: "routerFanOutTooLarge",
                org: OrgGraph(
                    nodes: [node(id: "a")] + (0..<(OrgValidator.maxRouterTargets + 1)).map { node(id: "t\($0)") },
                    edges: [
                        OrgEdge(
                            from: "a",
                            type: .router,
                            targets: (0..<(OrgValidator.maxRouterTargets + 1)).map { "t\($0)" }
                        )
                    ],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .routerFanOutTooLarge(_, let count, let max) = $0 {
                    return count == OrgValidator.maxRouterTargets + 1 && max == OrgValidator.maxRouterTargets
                }; return false }
            ),
            Case(
                name: "unsafeNodeId",
                org: OrgGraph(nodes: [node(id: "../escape")], edges: [], entry: "../escape"),
                runners: Self.defaultRunners,
                matches: { if case .unsafeNodeId(let id) = $0 { return id == "../escape" }; return false }
            ),
            Case(
                name: "emptyDoneChecks",
                org: OrgGraph(nodes: [node(id: "a", done: .allOf([]))], edges: [], entry: "a"),
                runners: Self.defaultRunners,
                matches: { if case .emptyDoneChecks(let id) = $0 { return id == "a" }; return false }
            )
        ]
    }

    func testEachIssueKindIsProducedByItsFixture() {
        for testCase in cases {
            let issues = OrgValidator.validate(org: testCase.org, runners: testCase.runners)
            XCTAssertTrue(
                issues.contains(where: testCase.matches),
                "Case '\(testCase.name)' expected a matching issue, got: \(issues.map(\.message))"
            )
        }
    }

    func testValidOrgProducesNoIssues() {
        let org = SeedTemplate.plannerImplementerReviewer()
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(issues.isEmpty, "Expected no issues, got: \(issues.map(\.message))")
    }

    func testEmptyOrgShortCircuitsWithoutOtherIssues() {
        let issues = OrgValidator.validate(org: OrgGraph(), runners: Self.defaultRunners)
        XCTAssertEqual(issues, [.emptyOrg])
    }
}
