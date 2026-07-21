import XCTest
@testable import GraphicalDomain

final class DoneCheckMergeTests: XCTestCase {
    func testShellChecksArePreserved() {
        let existing = DoneCheckGroup.allOf([
            .artifact("implementation.md"),
            .shell("test -f implementation.md")
        ])
        let merged = DoneCheckMerge.applyArtifactEdits(
            existing: existing,
            artifactPaths: ["implementation.md"],
            includeRouterNext: false
        )
        XCTAssertEqual(
            merged,
            .allOf([.artifact("implementation.md"), .shell("test -f implementation.md")])
        )
    }

    func testArtifactsAreReplacedNotAppended() {
        let existing = DoneCheckGroup.allOf([
            .artifact("old.md"),
            .shell("echo ok")
        ])
        let merged = DoneCheckMerge.applyArtifactEdits(
            existing: existing,
            artifactPaths: ["new.md", "other.md"],
            includeRouterNext: false
        )
        XCTAssertEqual(
            merged,
            .allOf([.artifact("new.md"), .artifact("other.md"), .shell("echo ok")])
        )
    }

    func testRouterNextToggleAddsAndRemoves() {
        let existing = DoneCheckGroup.allOf([.artifact("plan.md")])

        let withRouter = DoneCheckMerge.applyArtifactEdits(
            existing: existing,
            artifactPaths: ["plan.md"],
            includeRouterNext: true
        )
        XCTAssertEqual(withRouter, .allOf([.artifact("plan.md"), .routerNext]))

        let withoutRouter = DoneCheckMerge.applyArtifactEdits(
            existing: withRouter,
            artifactPaths: ["plan.md"],
            includeRouterNext: false
        )
        XCTAssertEqual(withoutRouter, .allOf([.artifact("plan.md")]))
    }

    func testAnyOfGroupKindIsPreserved() {
        let existing = DoneCheckGroup.anyOf([
            .artifact("a.md"),
            .shell("echo ok")
        ])
        let merged = DoneCheckMerge.applyArtifactEdits(
            existing: existing,
            artifactPaths: ["b.md"],
            includeRouterNext: false
        )
        XCTAssertEqual(merged, .anyOf([.artifact("b.md"), .shell("echo ok")]))
    }

    func testEmptyAnyOfSwitchesToAllOfWhenArtifactsAdded() {
        let existing = DoneCheckGroup.anyOf([])
        let merged = DoneCheckMerge.applyArtifactEdits(
            existing: existing,
            artifactPaths: ["output.md"],
            includeRouterNext: false
        )
        XCTAssertEqual(merged, .allOf([.artifact("output.md")]))
    }

    func testEmptyAllOfWithNoArtifactsStaysEmpty() {
        let existing = DoneCheckGroup.allOf([])
        let merged = DoneCheckMerge.applyArtifactEdits(
            existing: existing,
            artifactPaths: [],
            includeRouterNext: false
        )
        XCTAssertEqual(merged, .allOf([]))
    }
}
