import Foundation
import GraphicalDomain
import GraphicalCLI

/// Project workspace state: YAML I/O, Goal source, Org editing, runners, dirty tracking.
@MainActor
final class ProjectSession {
    struct SavedSnapshot: Equatable {
        var org: OrgGraph
        var layout: CanvasLayout
        var runners: RunnersConfig
        var goal: String
    }

    private(set) var project: GraphicalProject?
    private(set) var layout = CanvasLayout()
    var goalDraft: String = ""
    private(set) var validationIssues: [OrgValidationIssue] = []
    private var savedSnapshot: SavedSnapshot?

    let yamlStore = YAMLStore()

    var hasUnsavedChanges: Bool {
        guard let project, let snapshot = savedSnapshot else { return false }
        return project.org != snapshot.org
            || layout != snapshot.layout
            || project.runners != snapshot.runners
            || goalDraft != snapshot.goal
    }

    func readiness(firstRunComplete: Bool) -> ProjectReadiness? {
        guard let project else { return nil }
        return ProjectReadiness.derive(
            goal: goalDraft,
            org: project.org,
            runners: project.runners,
            firstRunComplete: firstRunComplete
        )
    }

    func captureSnapshot() {
        guard let project else {
            savedSnapshot = nil
            return
        }
        savedSnapshot = SavedSnapshot(
            org: project.org,
            layout: layout,
            runners: project.runners,
            goal: goalDraft
        )
    }

    func clear() {
        project = nil
        layout = CanvasLayout()
        goalDraft = ""
        validationIssues = []
        savedSnapshot = nil
    }

    /// Returns whether a new project was created (vs loaded).
    @discardableResult
    func open(at url: URL) throws -> Bool {
        let created: Bool
        if yamlStore.exists(at: url) {
            project = try yamlStore.load(from: url)
            created = false
        } else {
            project = try yamlStore.createProject(at: url, seed: .agenticMesh)
            created = true
        }
        if let project {
            layout = try yamlStore.loadLayout(projectRoot: project.root, org: project.org)
        }
        goalDraft = project.map { GoalSource.loadDraft(from: $0, store: yamlStore) } ?? ""
        revalidate()
        captureSnapshot()
        return created
    }

    func create(at url: URL) throws {
        project = try yamlStore.createProject(at: url, seed: .agenticMesh)
        if let project {
            layout = try yamlStore.loadLayout(projectRoot: project.root, org: project.org)
        }
        goalDraft = project.map { GoalSource.loadDraft(from: $0, store: yamlStore) } ?? ""
        revalidate()
        captureSnapshot()
    }

    /// Re-seeds the org as an agentic mesh with `width` lanes and regenerates layout.
    /// Preserves the current runner binding when possible (coding-tool setup rebinds next).
    func reseedAgenticMesh(width: Int) {
        guard var project else { return }
        let clamped = YAMLStore.clampedMeshWidth(width)
        let runnerName = project.org.nodes.first?.runner
            ?? project.runners.runners.keys.sorted().first
            ?? "echo_fixture"
        let kind = project.runners.runners[runnerName]?.kind
        project.config.meshWidth = clamped
        project.org = SeedTemplate.agenticMesh(
            width: clamped,
            runnerName: runnerName,
            agentKind: kind
        )
        self.project = project
        layout = CanvasLayout.autoLayout(org: project.org)
        revalidate()
    }

    func setParallelFanOut(_ enabled: Bool) {
        guard var project else { return }
        project.config.parallelFanOut = enabled
        self.project = project
    }

    @discardableResult
    func save() throws -> Bool {
        guard var project else { return false }
        try GoalSource.commit(goalDraft, to: &project, store: yamlStore)
        try yamlStore.save(project)
        try yamlStore.saveLayout(layout, projectRoot: project.root)
        self.project = project
        revalidate()
        captureSnapshot()
        return true
    }

    func revalidate() {
        guard let project else {
            validationIssues = []
            return
        }
        validationIssues = OrgValidator.validate(
            org: project.org,
            runners: project.runners,
            meshWidth: project.config.meshWidth
        )
    }

    func updateOrg(_ org: OrgGraph) {
        guard var project else { return }
        project.org = org
        self.project = project
        layout.ensurePositions(for: org)
        revalidate()
    }

    func updateLayout(_ layout: CanvasLayout, persist: Bool = false) {
        self.layout = layout
        if persist, let project {
            try? yamlStore.saveLayout(layout, projectRoot: project.root)
        }
    }

    func setNodePosition(id: String, x: Double, y: Double, persist: Bool) {
        layout.nodes[id] = NodePosition(x: x, y: y)
        if persist, let project {
            try? yamlStore.saveLayout(layout, projectRoot: project.root)
        }
    }

    func updateProjectName(_ name: String) {
        guard var project else { return }
        project.config.name = name
        self.project = project
    }

    func updateRunners(_ runners: RunnersConfig) {
        guard var project else { return }
        project.runners = runners
        self.project = project
        revalidate()
    }

    func applyAgentPreset(_ presetID: String) throws -> String {
        guard let project else {
            throw CodingToolSetupError.unknownPreset(presetID)
        }
        let updated = try CodingToolSetup.apply(presetID: presetID, to: project)
        self.project = updated
        revalidate()
        guard let preset = AgentPresetCatalog.preset(id: presetID) else {
            throw CodingToolSetupError.unknownPreset(presetID)
        }
        return preset.displayName
    }

    func inferredCodingToolPresetID() -> String? {
        guard let project else { return nil }
        return AgentPresetCatalog.inferredPresetID(from: project.runners, org: project.org)
    }

    func ensureArtifactsGitignore() throws {
        guard let project else { return }
        try yamlStore.ensureArtifactsGitignore(projectRoot: project.root)
    }

    // MARK: - Org mutations

    @discardableResult
    func addNode() -> String? {
        guard let project else { return nil }
        let runner = project.runners.runners.keys.sorted().first ?? "echo_fixture"
        let result = OrgEditing.insertNode(into: project.org, defaultRunner: runner)
        applyOrg(result.org)
        layout.nodes[result.nodeId] = result.position
        return result.nodeId
    }

    func replaceNode(_ node: OrgNode) {
        guard let project else { return }
        applyOrg(OrgEditing.replaceNode(node, in: project.org))
    }

    /// Mirrors the source node's coding tool + model onto other nodes with the same role.
    @discardableResult
    func mirrorAgentAndModel(from sourceId: String) -> Int {
        guard let project else { return 0 }
        let result = OrgEditing.mirrorAgentAndModel(from: sourceId, in: project.org)
        applyOrg(result.org)
        return result.updatedCount
    }

    @discardableResult
    func deleteNode(id: String) -> String? {
        guard let project else { return nil }
        let result = OrgEditing.removeNode(id: id, from: project.org)
        applyOrg(result.org)
        layout.nodes.removeValue(forKey: id)
        return result.selectedNodeId
    }

    func setEntry(_ id: String) {
        guard let project else { return }
        applyOrg(OrgEditing.setEntry(id, in: project.org))
    }

    @discardableResult
    func addFixedEdge(from: String? = nil, to: String? = nil) -> String? {
        guard let project else { return nil }
        guard let from = from ?? project.org.nodes.first?.id else { return nil }
        let to = to ?? project.org.nodes.dropFirst().first?.id ?? from
        let result = OrgEditing.connectFixed(from: from, to: to, in: project.org)
        applyOrg(result.org)
        return result.edgeId
    }

    @discardableResult
    func addRouterEdge(from: String? = nil, to: String? = nil) -> String? {
        guard let project else { return nil }
        guard let from = from ?? project.org.nodes.first?.id else { return nil }
        let result = OrgEditing.connectRouter(from: from, to: to, in: project.org)
        applyOrg(result.org)
        return result.edgeId
    }

    func replaceEdge(_ edge: OrgEdge) {
        guard let project else { return }
        applyOrg(OrgEditing.replaceEdge(edge, in: project.org))
    }

    func deleteEdge(id: String) {
        guard let project else { return }
        applyOrg(OrgEditing.removeEdge(id: id, from: project.org))
    }

    private func applyOrg(_ org: OrgGraph) {
        guard var project else { return }
        project.org = org
        self.project = project
        layout.ensurePositions(for: org)
        revalidate()
    }
}
