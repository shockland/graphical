import XCTest
@testable import GraphicalDomain

final class GoalSourceTests: XCTestCase {
    private var tempRoot: URL!
    private let store = YAMLStore()

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testLoadDraftPrefersGoalFile() throws {
        var project = try store.createProject(at: tempRoot, seed: .agenticMesh)
        project.config.goal = "yaml goal"
        try "file goal".write(
            to: tempRoot.appendingPathComponent("GOAL.md"),
            atomically: true,
            encoding: .utf8
        )
        let draft = GoalSource.loadDraft(from: project, store: store)
        XCTAssertEqual(draft, "file goal")
    }

    func testLoadDraftFallsBackToYAML() throws {
        var project = try store.createProject(at: tempRoot, seed: .agenticMesh)
        project.config.goal = "yaml only"
        try store.save(project)
        // Remove goal file if seed created one
        let goalURL = tempRoot.appendingPathComponent("GOAL.md")
        try? FileManager.default.removeItem(at: goalURL)
        let draft = GoalSource.loadDraft(from: project, store: store)
        XCTAssertEqual(draft, "yaml only")
    }

    func testCommitWritesYAMLAndFile() throws {
        var project = try store.createProject(at: tempRoot, seed: .agenticMesh)
        try GoalSource.commit("committed goal", to: &project, store: store)
        XCTAssertEqual(project.config.goal, "committed goal")
        let fromFile = try store.loadGoalText(projectRoot: project.root, config: project.config)
        XCTAssertEqual(fromFile, "committed goal")
    }
}
