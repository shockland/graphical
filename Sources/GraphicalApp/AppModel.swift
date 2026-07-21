import Foundation
import AppKit
import UniformTypeIdentifiers
import GraphicalDomain
import GraphicalEngine

@MainActor
protocol AppModelDelegate: AnyObject {
    func appModelDidChange(_ model: AppModel)
}

@MainActor
final class AppModel {
    weak var delegate: AppModelDelegate?

    private(set) var project: GraphicalProject?
    private(set) var layout = CanvasLayout()
    var selectedTab: AppTab = .org {
        didSet { notify() }
    }
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isRunning = false
    private(set) var run: RunRecord?
    private(set) var events: [TraceEvent] = []
    private(set) var liveLog: [String] = []
    private(set) var runPhase: String?
    private(set) var runIteration: Int?
    private(set) var pendingApproval: PendingApproval?
    private(set) var lastInspection: HandoffInspection?
    private(set) var validationIssues: [OrgValidationIssue] = []
    private(set) var recentRuns: [RunRecord] = []
    var goalDraft: String = ""
    private(set) var exportPath: String?
    /// Set when Play is requested with an empty goal; Run console consumes and clears it.
    private(set) var focusRunGoal = false

    var selectedNodeId: String?
    var selectedEdgeId: String?

    let yamlStore = YAMLStore()
    private(set) var traceStore: TraceStore?
    private var engine: RunEngine?
    /// Incremented when a new run session starts so stale async work cannot clear UI state.
    private var runSession = 0

    enum AppTab: String, CaseIterable, Identifiable {
        case org = "Org"
        case run = "Run"
        case trace = "Trace"
        case runners = "Agents"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .org: return "rectangle.3.group"
            case .run: return "play.circle"
            case .trace: return "list.bullet.rectangle"
            case .runners: return "terminal"
            }
        }
    }

    init() {
        do {
            traceStore = try TraceStore()
        } catch {
            errorMessage = "Failed to open trace store: \(error.localizedDescription)"
        }
    }

    func notify() {
        delegate?.appModelDidChange(self)
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder with or without a .graphical project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func createProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create"
        panel.message = "Choose a folder to initialize as a Graphical project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            if yamlStore.exists(at: url) {
                project = try yamlStore.load(from: url)
            } else {
                project = try yamlStore.createProject(at: url, seedTemplate: true)
                statusMessage = "Created .graphical project in \(url.path)"
            }
            if let project {
                layout = try yamlStore.loadLayout(projectRoot: project.root, org: project.org)
            }
            goalDraft = project?.config.goal ?? ""
            selectedNodeId = project?.org.entryNodeId
            selectedEdgeId = nil
            revalidate()
            refreshRecentRuns()
            selectedTab = .org
            errorMessage = nil
            notify()
        } catch {
            errorMessage = error.localizedDescription
            notify()
        }
    }

    func createProject(at url: URL) {
        do {
            project = try yamlStore.createProject(at: url, seedTemplate: true)
            if let project {
                layout = try yamlStore.loadLayout(projectRoot: project.root, org: project.org)
            }
            goalDraft = project?.config.goal ?? ""
            selectedNodeId = project?.org.entryNodeId
            selectedEdgeId = nil
            revalidate()
            statusMessage = "Created Graphical project at \(url.path)"
            errorMessage = nil
            selectedTab = .org
            notify()
        } catch {
            errorMessage = error.localizedDescription
            notify()
        }
    }

    func closeProject() {
        if isRunning {
            cancelRun()
        }
        runSession += 1
        project = nil
        layout = CanvasLayout()
        selectedNodeId = nil
        selectedEdgeId = nil
        selectedTab = .org
        goalDraft = ""
        run = nil
        events = []
        liveLog = []
        pendingApproval = nil
        lastInspection = nil
        validationIssues = []
        exportPath = nil
        engine = nil
        errorMessage = nil
        statusMessage = "Project closed"
        notify()
    }

    func saveProject() {
        guard let project else { return }
        do {
            var updated = project
            updated.config.goal = goalDraft
            try yamlStore.save(updated)
            try yamlStore.saveLayout(layout, projectRoot: updated.root)
            self.project = updated
            revalidate()
            statusMessage = "Saved .graphical YAML"
            errorMessage = nil
            notify()
        } catch {
            errorMessage = error.localizedDescription
            notify()
        }
    }

    func revalidate() {
        guard let project else {
            validationIssues = []
            return
        }
        validationIssues = OrgValidator.validate(org: project.org, runners: project.runners)
    }

    func updateOrg(_ org: OrgGraph) {
        guard var project else { return }
        project.org = org
        self.project = project
        layout.ensurePositions(for: org)
        revalidate()
        notify()
    }

    func updateLayout(_ layout: CanvasLayout, persist: Bool = false) {
        self.layout = layout
        if persist, let project {
            try? yamlStore.saveLayout(layout, projectRoot: project.root)
        }
        notify()
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
        notify()
    }

    func updateRunners(_ runners: RunnersConfig) {
        guard var project else { return }
        project.runners = runners
        self.project = project
        revalidate()
        notify()
    }

    /// Switch to Run and start if a goal is present; otherwise focus the goal field.
    func play() {
        selectedTab = .run
        let trimmed = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            focusRunGoal = true
            statusMessage = "Enter a goal, then Play"
            errorMessage = nil
            notify()
            return
        }
        startRun()
    }

    func consumeFocusRunGoal() {
        focusRunGoal = false
    }

    func startRun() {
        guard let project, let traceStore else { return }
        if isRunning {
            statusMessage = "Run already in progress"
            notify()
            return
        }
        if pendingApproval != nil {
            selectedTab = .run
            statusMessage = "Approve or reject the pending handoff first"
            notify()
            return
        }
        if !validationIssues.isEmpty {
            errorMessage = "Fix org validation issues before running"
            notify()
            return
        }
        let trimmed = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            selectedTab = .run
            focusRunGoal = true
            statusMessage = "Enter a goal, then Play"
            errorMessage = nil
            notify()
            return
        }
        runSession += 1
        let session = runSession
        isRunning = true
        errorMessage = nil
        statusMessage = "Run starting…"
        runPhase = "starting"
        runIteration = nil
        notify()
        let engine = RunEngine(store: traceStore)
        self.engine = engine
        Task {
            await attachRunProgressHandler(to: engine, session: session)
            do {
                let run = try await engine.start(project: project, goal: goalDraft)
                guard isCurrentRunSession(session), self.engine === engine else { return }
                await refreshFromEngine(engine, run: run)
                if run.status == .awaitingApproval {
                    statusMessage = "Awaiting approval"
                } else if run.status == .succeeded {
                    statusMessage = "Run succeeded"
                } else if run.status == .failed {
                    statusMessage = "Run failed"
                }
            } catch {
                guard isCurrentRunSession(session), self.engine === engine else { return }
                errorMessage = error.localizedDescription
                await refreshFromEngine(engine, run: await engine.currentRun)
            }
            guard isCurrentRunSession(session), self.engine === engine else { return }
            await engine.setProgressHandler(nil)
            isRunning = false
            runPhase = nil
            runIteration = nil
            refreshRecentRuns()
            notify()
        }
    }

    func approve() {
        guard let engine else { return }
        let session = runSession
        isRunning = true
        notify()
        Task {
            await attachRunProgressHandler(to: engine, session: session)
            do {
                let run = try await engine.approve()
                guard isCurrentRunSession(session), self.engine === engine else { return }
                await refreshFromEngine(engine, run: run)
                statusMessage = run.status == .succeeded ? "Run succeeded" : "Approved; continuing"
            } catch {
                guard isCurrentRunSession(session), self.engine === engine else { return }
                errorMessage = error.localizedDescription
            }
            guard isCurrentRunSession(session), self.engine === engine else { return }
            await engine.setProgressHandler(nil)
            isRunning = false
            runPhase = nil
            runIteration = nil
            refreshRecentRuns()
            notify()
        }
    }

    func rejectApproval() {
        guard let engine else { return }
        Task {
            do {
                let run = try await engine.rejectApproval(notes: "Rejected by user")
                await refreshFromEngine(engine, run: run)
                statusMessage = "Approval rejected"
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshRecentRuns()
            notify()
        }
    }

    func cancelRun() {
        guard let engine else { return }
        let session = runSession
        Task {
            try? await engine.cancel()
            guard isCurrentRunSession(session), self.engine === engine else { return }
            await refreshFromEngine(engine, run: await engine.currentRun)
            isRunning = false
            runPhase = nil
            runIteration = nil
            statusMessage = "Cancelled"
            refreshRecentRuns()
            notify()
        }
    }

    func retryRun() {
        guard let engine else { return }
        let session = runSession
        isRunning = true
        notify()
        Task {
            await attachRunProgressHandler(to: engine, session: session)
            do {
                try await engine.retryActiveNode()
                guard isCurrentRunSession(session), self.engine === engine else { return }
                await refreshFromEngine(engine, run: await engine.currentRun)
            } catch {
                guard isCurrentRunSession(session), self.engine === engine else { return }
                errorMessage = error.localizedDescription
            }
            guard isCurrentRunSession(session), self.engine === engine else { return }
            await engine.setProgressHandler(nil)
            isRunning = false
            runPhase = nil
            runIteration = nil
            refreshRecentRuns()
            notify()
        }
    }

    func loadRun(_ run: RunRecord) {
        self.run = run
        selectedTab = .trace
        notify()
        Task {
            do {
                events = try await traceStore?.events(runId: run.id) ?? []
            } catch {
                errorMessage = error.localizedDescription
            }
            notify()
        }
    }

    func exportTrace() {
        guard let run, let traceStore else { return }
        Task {
            do {
                let data = try await traceStore.exportTraceJSON(runId: run.id)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "trace-\(run.id).json"
                panel.allowedContentTypes = [.json]
                if panel.runModal() == .OK, let url = panel.url {
                    try data.write(to: url)
                    exportPath = url.path
                    statusMessage = "Exported trace to \(url.path)"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            notify()
        }
    }

    func ensureArtifactsGitignore() {
        guard let project else { return }
        do {
            try yamlStore.ensureArtifactsGitignore(projectRoot: project.root)
            statusMessage = "Ensured artifacts .gitignore"
        } catch {
            errorMessage = error.localizedDescription
        }
        notify()
    }

    // MARK: - Org mutations

    func addNode() {
        mutateOrg { org in
            let id = "node_\(org.nodes.count + 1)"
            org.nodes.append(
                OrgNode(
                    id: id,
                    role: "Role",
                    runner: project?.runners.runners.keys.sorted().first ?? "echo_fixture",
                    instructions: "Describe this role.",
                    done: .allOf([.artifact("output.md")]),
                    maxIterations: 3
                )
            )
            let offset = Double(org.nodes.count) * 24
            layout.nodes[id] = NodePosition(x: 120 + offset, y: 120 + offset)
            selectedNodeId = id
            selectedEdgeId = nil
        }
    }

    func replaceNode(_ node: OrgNode) {
        mutateOrg { org in
            if let idx = org.nodes.firstIndex(where: { $0.id == node.id }) {
                org.nodes[idx] = node
            }
        }
    }

    func deleteNode(id: String) {
        mutateOrg { org in
            org.nodes.removeAll { $0.id == id }
            org.edges.removeAll { $0.from == id || $0.to == id || $0.targets.contains(id) }
            if org.entry == id { org.entry = org.nodes.first?.id }
            layout.nodes.removeValue(forKey: id)
            if selectedNodeId == id { selectedNodeId = org.entryNodeId }
        }
    }

    func setEntry(_ id: String) {
        mutateOrg { org in
            org.entry = id
        }
    }

    func addFixedEdge(from: String? = nil, to: String? = nil) {
        mutateOrg { org in
            guard let from = from ?? org.nodes.first?.id else { return }
            let to = to ?? org.nodes.dropFirst().first?.id ?? from
            let edge = OrgEdge(from: from, to: to, type: .fixed, on: .success)
            org.edges.append(edge)
            selectedEdgeId = edge.id
            selectedNodeId = nil
        }
    }

    func addRouterEdge(from: String? = nil) {
        mutateOrg { org in
            guard let from = from ?? org.nodes.first?.id else { return }
            let targets = Array(org.nodes.filter { $0.id != from }.prefix(2).map(\.id))
            let edge = OrgEdge(
                from: from,
                type: .router,
                targets: targets.isEmpty ? [from] : targets,
                requiresApproval: true
            )
            org.edges.append(edge)
            selectedEdgeId = edge.id
            selectedNodeId = nil
        }
    }

    func replaceEdge(_ edge: OrgEdge) {
        mutateOrg { org in
            if let idx = org.edges.firstIndex(where: { $0.id == edge.id }) {
                org.edges[idx] = edge
            }
        }
    }

    func deleteEdge(id: String) {
        mutateOrg { org in
            org.edges.removeAll { $0.id == id }
            if selectedEdgeId == id { selectedEdgeId = nil }
        }
    }

    private func mutateOrg(_ body: (inout OrgGraph) -> Void) {
        guard var project else { return }
        body(&project.org)
        self.project = project
        layout.ensurePositions(for: project.org)
        revalidate()
        notify()
    }

    private func isCurrentRunSession(_ session: Int) -> Bool {
        session == runSession
    }

    private func attachRunProgressHandler(to engine: RunEngine, session: Int) async {
        await engine.setProgressHandler { @MainActor [weak self] snapshot in
            guard let self, self.isCurrentRunSession(session), self.engine === engine else { return }
            self.applyProgressSnapshot(snapshot, whileRunning: true)
        }
    }

    private func refreshFromEngine(_ engine: RunEngine, run: RunRecord?) async {
        self.run = run
        self.liveLog = await engine.liveLog
        self.pendingApproval = await engine.pendingApproval
        self.lastInspection = await engine.lastInspection
        self.runPhase = await engine.currentPhase
        self.runIteration = await engine.currentIteration
        if let run {
            self.events = (try? await traceStore?.events(runId: run.id)) ?? []
        }
    }

    private func applyProgressSnapshot(_ snapshot: RunProgressSnapshot, whileRunning: Bool) {
        if let snapshotRun = snapshot.run {
            run = snapshotRun
        }
        liveLog = snapshot.liveLog
        pendingApproval = snapshot.pendingApproval
        lastInspection = snapshot.lastInspection
        runPhase = snapshot.phase
        runIteration = snapshot.iteration
        if whileRunning {
            statusMessage = runningStatusMessage(from: snapshot)
        }
        notify()
    }

    private func runningStatusMessage(from snapshot: RunProgressSnapshot) -> String {
        if snapshot.run?.status == .awaitingApproval {
            return "Awaiting approval"
        }
        guard let nodeId = snapshot.run?.activeNodeId else {
            return snapshot.phase.map { "Running · \($0)" } ?? "Running…"
        }
        let role = project?.org.node(id: nodeId)?.role ?? nodeId
        var parts = ["Running \(role)"]
        if let phase = snapshot.phase {
            parts.append(phase)
        }
        if let iteration = snapshot.iteration,
           let max = project?.org.node(id: nodeId)?.maxIterations {
            parts.append("iteration \(iteration)/\(max)")
        }
        return parts.joined(separator: " · ")
    }

    private func refreshRecentRuns() {
        Task {
            recentRuns = (try? await traceStore?.recentRuns()) ?? []
            notify()
        }
    }
}
