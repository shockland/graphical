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
            ),
            Case(
                name: "fanOutWithoutTargets",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "a", type: .fanOut, targets: [])],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .fanOutWithoutTargets = $0 { return true }; return false }
            ),
            Case(
                name: "fanOutTargetUnknown",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "a", type: .fanOut, targets: ["ghost"])],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .fanOutTargetUnknown(_, let target) = $0 { return target == "ghost" }; return false }
            ),
            Case(
                name: "fanOutTooLarge",
                org: OrgGraph(
                    nodes: [node(id: "a")] + (0..<(OrgValidator.maxMeshWidth + 1)).map { node(id: "t\($0)") },
                    edges: [
                        OrgEdge(
                            from: "a",
                            type: .fanOut,
                            targets: (0..<(OrgValidator.maxMeshWidth + 1)).map { "t\($0)" }
                        )
                    ],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .fanOutTooLarge(_, let count, let max) = $0 {
                    return count == OrgValidator.maxMeshWidth + 1 && max == OrgValidator.maxMeshWidth
                }; return false }
            ),
            Case(
                name: "joinEdgeMissingTo",
                org: OrgGraph(
                    nodes: [node(id: "a")],
                    edges: [OrgEdge(from: "a", to: nil, type: .join)],
                    entry: "a"
                ),
                runners: Self.defaultRunners,
                matches: { if case .joinEdgeMissingTo = $0 { return true }; return false }
            ),
            Case(
                name: "meshNoPlanners",
                org: {
                    var org = SeedTemplate.agenticMesh(width: 2)
                    org.nodes.removeAll { $0.role == "Planner" || $0.id.hasPrefix("planner-") }
                    org.edges = org.edges.compactMap { edge -> OrgEdge? in
                        if edge.from.hasPrefix("planner-") { return nil }
                        if edge.type == .fanOut {
                            return OrgEdge(
                                id: edge.id,
                                from: edge.from,
                                type: .fanOut,
                                targets: edge.targets.filter { !$0.hasPrefix("planner-") },
                                on: edge.on,
                                pass: edge.pass
                            )
                        }
                        return edge
                    }
                    return org
                }(),
                runners: SeedTemplate.defaultRunners(),
                matches: { if case .meshNoPlanners = $0 { return true }; return false }
            ),
            Case(
                name: "meshBrokenLanePairing",
                org: {
                    var org = SeedTemplate.agenticMesh(width: 2)
                    org.nodes.removeAll { $0.id == "interpreter-1" }
                    org.edges.removeAll { $0.to == "interpreter-1" || $0.from == "interpreter-1" }
                    return org
                }(),
                runners: SeedTemplate.defaultRunners(),
                matches: {
                    if case .meshBrokenLanePairing("planner-1", _) = $0 { return true }
                    return false
                }
            ),
            Case(
                name: "meshMissingAuditorJoin",
                org: {
                    var org = SeedTemplate.agenticMesh(width: 2)
                    org.edges.removeAll { $0.type == .join }
                    return org
                }(),
                runners: SeedTemplate.defaultRunners(),
                matches: { if case .meshMissingAuditorJoin = $0 { return true }; return false }
            ),
            Case(
                name: "meshMultiplePostAuditorImplementers",
                org: {
                    var org = SeedTemplate.agenticMesh(width: 2)
                    org.nodes.append(
                        OrgNode(
                            id: "implementer-b",
                            role: "Implementer",
                            runner: "echo_fixture",
                            done: .allOf([.artifact("implementation.md")])
                        )
                    )
                    org.edges.append(
                        OrgEdge(
                            from: "auditor",
                            to: "implementer-b",
                            type: .fixed,
                            on: .success
                        )
                    )
                    return org
                }(),
                runners: SeedTemplate.defaultRunners(),
                matches: {
                    if case .meshMultiplePostAuditorImplementers = $0 { return true }
                    return false
                }
            ),
            Case(
                name: "meshSpinePassIncomplete",
                org: {
                    var org = SeedTemplate.agenticMesh(width: 2)
                    if let idx = org.edges.firstIndex(where: { $0.id == "planner-1-to-interpreter-1" }) {
                        org.edges[idx].pass = [.checks]
                    }
                    return org
                }(),
                runners: SeedTemplate.defaultRunners(),
                matches: {
                    if case .meshSpinePassIncomplete("planner-1-to-interpreter-1", let missing) = $0 {
                        return Set(missing) == [.artifacts, .summary]
                    }
                    return false
                }
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

    func testAgenticMeshSeedValidates() {
        let org = SeedTemplate.agenticMesh(width: 3)
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(issues.isEmpty, "Expected no issues, got: \(issues.map(\.message))")
        XCTAssertEqual(org.nodes.filter { $0.id.hasPrefix("planner-") }.count, 3)
        XCTAssertEqual(org.nodes.filter { $0.id.hasPrefix("interpreter-") }.count, 3)
        XCTAssertEqual(org.edges.filter { $0.type == .fanOut }.count, 1)
        XCTAssertEqual(org.edges.filter { $0.type == .join }.count, 3)
    }

    func testAgenticMeshSeedUsesNilInheritModels() {
        for width in [2, 3, 5] {
            let org = SeedTemplate.agenticMesh(width: width)
            XCTAssertTrue(
                org.nodes.allSatisfy { $0.model == nil },
                "width \(width): expected nil-inherit models, got \(org.nodes.map { ($0.id, $0.model) })"
            )
            let planners = org.nodes.filter { $0.id.hasPrefix("planner-") }
            let interpreters = org.nodes.filter { $0.id.hasPrefix("interpreter-") }
            XCTAssertEqual(planners.count, width)
            XCTAssertEqual(interpreters.count, width)
            XCTAssertTrue(planners.allSatisfy { $0.instructions.contains("plan.md") })
            XCTAssertTrue(interpreters.allSatisfy { $0.instructions.contains("Plan goals") })
            XCTAssertTrue(org.node(id: "auditor")?.instructions.contains("Merged Objectives") == true)
        }
    }

    func testMeshWidthInvalidWhenPassed() {
        let org = SeedTemplate.agenticMesh(width: 3)
        let issues = OrgValidator.validate(
            org: org,
            runners: SeedTemplate.defaultRunners(),
            meshWidth: 1
        )
        XCTAssertTrue(issues.contains { if case .meshWidthInvalid(1) = $0 { return true }; return false })
    }

    func testEmptyOrgShortCircuitsWithoutOtherIssues() {
        let issues = OrgValidator.validate(org: OrgGraph(), runners: Self.defaultRunners)
        XCTAssertEqual(issues, [.emptyOrg])
    }

    func testNonMeshWorkflowHasNoMeshWarnings() {
        let org = SeedTemplate.plannerImplementerReviewer()
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(issues.filter(\.isWarning).isEmpty)
        XCTAssertTrue(issues.filter { !$0.isWarning }.isEmpty)
    }

    func testMeshNoPlannersWarning() {
        var org = SeedTemplate.agenticMesh(width: 2)
        org.nodes.removeAll { $0.role == "Planner" || $0.id.hasPrefix("planner-") }
        org.edges = org.edges.compactMap { edge -> OrgEdge? in
            if edge.from.hasPrefix("planner-") { return nil }
            if edge.type == .fanOut {
                return OrgEdge(
                    id: edge.id,
                    from: edge.from,
                    type: .fanOut,
                    targets: edge.targets.filter { !$0.hasPrefix("planner-") },
                    on: edge.on,
                    pass: edge.pass
                )
            }
            return edge
        }
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(
            issues.contains { if case .meshNoPlanners = $0 { return true }; return false },
            "got: \(issues.map(\.message))"
        )
        XCTAssertTrue(issues.contains { $0.isWarning })
    }

    func testMeshBrokenLanePairingWarning() {
        var org = SeedTemplate.agenticMesh(width: 2)
        org.edges.removeAll { $0.from == "planner-1" && $0.to == "interpreter-1" }
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(
            issues.contains {
                if case .meshBrokenLanePairing("planner-1", _) = $0 { return true }
                return false
            },
            "got: \(issues.map(\.message))"
        )
        XCTAssertTrue(issues.contains { $0.isWarning })
        XCTAssertTrue(issues.filter { !$0.isWarning }.isEmpty)
    }

    func testMeshMissingAuditorJoinWarning() {
        var org = SeedTemplate.agenticMesh(width: 2)
        org.edges.removeAll { $0.type == .join }
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(
            issues.contains { if case .meshMissingAuditorJoin = $0 { return true }; return false },
            "got: \(issues.map(\.message))"
        )
    }

    func testMeshMultiplePostAuditorImplementersWarning() {
        var org = SeedTemplate.agenticMesh(width: 2)
        org.nodes.append(
            OrgNode(
                id: "implementer-b",
                role: "Implementer",
                runner: "echo_fixture",
                done: .allOf([.artifact("implementation.md")])
            )
        )
        org.edges.append(
            OrgEdge(
                id: "auditor-to-implementer-b",
                from: "auditor",
                to: "implementer-b",
                type: .fixed,
                on: .success
            )
        )
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(
            issues.contains {
                if case .meshMultiplePostAuditorImplementers(let ids) = $0 {
                    return Set(ids) == ["implementer", "implementer-b"]
                }
                return false
            },
            "got: \(issues.map(\.message))"
        )
    }

    func testMeshSpinePassIncompleteHardFails() {
        var org = SeedTemplate.agenticMesh(width: 2)
        if let idx = org.edges.firstIndex(where: { $0.id == "interpreter-1-join-auditor" }) {
            org.edges[idx].pass = [.checks, .notes]
        }
        if let idx = org.edges.firstIndex(where: { $0.id == "auditor-to-implementer" }) {
            org.edges[idx].pass = [.summary]
        }
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertTrue(
            issues.contains {
                if case .meshSpinePassIncomplete("interpreter-1-join-auditor", let missing) = $0 {
                    return Set(missing) == [.artifacts, .summary]
                }
                return false
            },
            "got: \(issues.map(\.message))"
        )
        XCTAssertTrue(
            issues.contains {
                if case .meshSpinePassIncomplete("auditor-to-implementer", let missing) = $0 {
                    return missing == [.artifacts]
                }
                return false
            },
            "got: \(issues.map(\.message))"
        )
        XCTAssertTrue(issues.contains { !$0.isWarning }, "pass-list incompleteness must hard-fail")
        // Non-spine edges (entry fan-out, implementer→report) can strip pass without this issue.
        if let idx = org.edges.firstIndex(where: { $0.id == "implementer-to-report" }) {
            org.edges[idx].pass = [.checks]
        }
        // Restore spine edges so only non-spine is stripped.
        if let idx = org.edges.firstIndex(where: { $0.id == "interpreter-1-join-auditor" }) {
            org.edges[idx].pass = [.summary, .artifacts, .checks]
        }
        if let idx = org.edges.firstIndex(where: { $0.id == "auditor-to-implementer" }) {
            org.edges[idx].pass = [.summary, .artifacts, .checks]
        }
        let after = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertFalse(
            after.contains { if case .meshSpinePassIncomplete = $0 { return true }; return false },
            "non-spine strip should not hard-fail: \(after.map(\.message))"
        )
    }

    func testClassicOrgStrippedPassDoesNotTriggerMeshSpineIssue() {
        var org = SeedTemplate.plannerImplementerReviewer()
        for idx in org.edges.indices {
            org.edges[idx].pass = [.checks]
        }
        let issues = OrgValidator.validate(org: org, runners: SeedTemplate.defaultRunners())
        XCTAssertFalse(
            issues.contains { if case .meshSpinePassIncomplete = $0 { return true }; return false }
        )
    }

    func testJoinPredecessorsSortNumerically() {
        let org = OrgGraph(
            nodes: [
                node(id: "auditor"),
                node(id: "interpreter-1"),
                node(id: "interpreter-2"),
                node(id: "interpreter-10")
            ],
            edges: [
                OrgEdge(from: "interpreter-10", to: "auditor", type: .join),
                OrgEdge(from: "interpreter-2", to: "auditor", type: .join),
                OrgEdge(from: "interpreter-1", to: "auditor", type: .join)
            ],
            entry: "interpreter-1"
        )
        XCTAssertEqual(
            org.joinPredecessors(of: "auditor"),
            ["interpreter-1", "interpreter-2", "interpreter-10"]
        )
    }
}
