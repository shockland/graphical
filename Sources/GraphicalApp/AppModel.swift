import Foundation
import AppKit
import UniformTypeIdentifiers
import GraphicalDomain
import GraphicalEngine
import GraphicalCLI

@MainActor
protocol AppModelDelegate: AnyObject {
    /// Full-fidelity change: project switch, org edits, validation, tab switch, etc.
    /// Recipients should rebuild whatever depends on the changed state.
    func appModelDidChange(_ model: AppModel)
    /// Scoped run-progress tick (new log lines / phase / iteration / pending approval)
    /// fired many times per run. Recipients should update only run-status-adjacent UI
    /// (status bar, top bar running state, run console) rather than rebuilding
    /// unrelated workspaces (org canvas, trace list, runners) — see plans/013.
    func appModelRunProgressDidChange(_ model: AppModel)
    /// Unsaved-state or other chrome-only updates without rebuilding workspaces.
    func appModelDirtyStateDidChange(_ model: AppModel)
}

/// App shell coordinator: chrome one-shots + thin facade over ProjectSession / RunSession.
@MainActor
final class AppModel {
    weak var delegate: AppModelDelegate?

    private let projectSession = ProjectSession()
    private let runSession = RunSession()

    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    var selectedTab: AppTab = .org {
        didSet { notify() }
    }
    /// Set when Play is requested with an empty goal; Run console consumes and clears it.
    private(set) var focusRunGoal = false
    /// One-shot: org workspace should center the current selection on the canvas.
    private(set) var shouldCenterSelection = false
    /// One-shot: org workspace should fit the canvas to node bounds.
    private(set) var shouldFitCanvas = false
    /// One-shot request consumed by the window coordinator after a project is created.
    private var setupPresentationProjectRoot: URL?
    /// One-shot request to present the coding-tool-only setup sheet.
    private var codingToolSetupRequested = false

    var selectedNodeId: String?
    var selectedEdgeId: String?

    private(set) var traceStore: TraceStore?

    // MARK: - ProjectSession facade

    var project: GraphicalProject? { projectSession.project }
    var layout: CanvasLayout { projectSession.layout }
    var goalDraft: String {
        get { projectSession.goalDraft }
        set { projectSession.goalDraft = newValue }
    }
    var validationIssues: [OrgValidationIssue] { projectSession.validationIssues }
    var yamlStore: YAMLStore { projectSession.yamlStore }
    var hasUnsavedChanges: Bool { projectSession.hasUnsavedChanges }

    var projectReadiness: ProjectReadiness? {
        guard let project else { return nil }
        let projectRoot = project.root.standardizedFileURL
        let firstRunComplete = recentRuns.contains { run in
            run.status == .succeeded
                && URL(fileURLWithPath: run.projectRoot).standardizedFileURL.path == projectRoot.path
        }
        return projectSession.readiness(firstRunComplete: firstRunComplete)
    }

    // MARK: - RunSession facade

    var isRunning: Bool { runSession.isRunning }
    var run: RunRecord? { runSession.run }
    var events: [TraceEvent] { runSession.events }
    var liveLog: [String] { runSession.liveLog }
    var runPhase: String? { runSession.runPhase }
    var runIteration: Int? { runSession.runIteration }
    var pendingApproval: PendingApproval? { runSession.pendingApproval }
    var lastInspection: HandoffInspection? { runSession.lastInspection }

    /// Human-readable run progress for the Run console.
    func runProgressCopy() -> RunProgressCopy {
        runSession.progressCopy(org: project?.org)
    }
    var recentRuns: [RunRecord] { runSession.recentRuns }
    var exportPath: String? { runSession.exportPath }

    enum AppTab: String, CaseIterable, Identifiable {
        case org = "Workflow"
        case run = "Run"
        case trace = "History"
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

    func refreshDirtyIndicator() {
        delegate?.appModelDirtyStateDidChange(self)
    }

    private func notifyProgress() {
        delegate?.appModelRunProgressDidChange(self)
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
        setupPresentationProjectRoot = nil
        do {
            let created = try projectSession.open(at: url)
            if created {
                statusMessage = "Created .graphical project in \(url.path)"
            }
            selectedNodeId = project?.org.entryNodeId
            selectedEdgeId = nil
            runSession.refreshRecentRuns(traceStore: traceStore)
            setupPresentationProjectRoot = created ? project?.root.standardizedFileURL : nil
            selectedTab = .org
            errorMessage = nil
            notify()
        } catch {
            errorMessage = error.localizedDescription
            notify()
        }
    }

    func createProject(at url: URL) {
        setupPresentationProjectRoot = nil
        do {
            try projectSession.create(at: url)
            selectedNodeId = project?.org.entryNodeId
            selectedEdgeId = nil
            statusMessage = "Created Graphical project at \(url.path)"
            errorMessage = nil
            setupPresentationProjectRoot = project?.root.standardizedFileURL
            selectedTab = .org
            notify()
        } catch {
            errorMessage = error.localizedDescription
            notify()
        }
    }

    func closeProject() {
        if hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved changes?"
            alert.informativeText = "Your workflow, layout, coding tools, or goal have changes that are not saved."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertSecondButtonReturn { return }
        }
        if isRunning {
            cancelRun()
        }
        runSession.bumpSessionForClose()
        projectSession.clear()
        selectedNodeId = nil
        selectedEdgeId = nil
        selectedTab = .org
        setupPresentationProjectRoot = nil
        codingToolSetupRequested = false
        errorMessage = nil
        statusMessage = "Project closed"
        notify()
    }

    @discardableResult
    func saveProject() -> Bool {
        do {
            guard try projectSession.save() else { return false }
            statusMessage = "Saved .graphical YAML"
            errorMessage = nil
            notify()
            return true
        } catch {
            errorMessage = error.localizedDescription
            notify()
            return false
        }
    }

    func revalidate() {
        projectSession.revalidate()
    }

    func updateOrg(_ org: OrgGraph) {
        projectSession.updateOrg(org)
        notify()
    }

    func updateLayout(_ layout: CanvasLayout, persist: Bool = false) {
        projectSession.updateLayout(layout, persist: persist)
        notify()
    }

    func setNodePosition(id: String, x: Double, y: Double, persist: Bool) {
        projectSession.setNodePosition(id: id, x: x, y: y, persist: persist)
    }

    func updateProjectName(_ name: String) {
        projectSession.updateProjectName(name)
        notify()
    }

    func updateRunners(_ runners: RunnersConfig) {
        projectSession.updateRunners(runners)
        notify()
    }

    @discardableResult
    func applyAgentPreset(_ presetID: String) -> Bool {
        do {
            let displayName = try projectSession.applyAgentPreset(presetID)
            errorMessage = nil
            statusMessage = "Using \(displayName)"
            notify()
            return true
        } catch CodingToolSetupError.unknownPreset(let id) {
            errorMessage = "Unknown coding tool preset: \(id)"
            notify()
            return false
        } catch {
            errorMessage = "Could not apply coding tool preset: \(error)"
            notify()
            return false
        }
    }

    @discardableResult
    func completeSetup(goal: String, presetID: String) -> Bool {
        goalDraft = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard applyAgentPreset(presetID), saveProject(), let project else {
            return false
        }

        revalidate()
        let readiness = ProjectReadiness.derive(
            goal: goalDraft,
            org: project.org,
            runners: project.runners,
            firstRunComplete: false
        )
        guard readiness.canRun else {
            errorMessage = "The project is not ready to run"
            notify()
            return false
        }
        selectedTab = .org
        selectedNodeId = project.org.entryNodeId
        selectedEdgeId = nil
        shouldFitCanvas = true
        shouldCenterSelection = true
        statusMessage =
            "Workflow ready — run Planner → Implementer → Reviewer when you’re ready"
        errorMessage = nil
        notify()
        return true
    }

    func openHistoryForCurrentRun() {
        guard let run else {
            selectedTab = .trace
            notify()
            return
        }
        loadRun(run)
    }

    func consumeSetupPresentationRequest() -> URL? {
        defer { setupPresentationProjectRoot = nil }
        return setupPresentationProjectRoot
    }

    func requestCodingToolSetup() {
        guard project != nil else { return }
        codingToolSetupRequested = true
        notify()
    }

    func consumeCodingToolSetupRequest() -> Bool {
        defer { codingToolSetupRequested = false }
        return codingToolSetupRequested
    }

    @discardableResult
    func applyCodingToolPreset(_ presetID: String) -> Bool {
        guard applyAgentPreset(presetID) else { return false }
        return saveProject()
    }

    func inferredCodingToolPresetID() -> String? {
        projectSession.inferredCodingToolPresetID()
    }

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

    func showRunGoalEditor() {
        focusRunGoal = true
        if selectedTab == .run {
            notify()
        } else {
            selectedTab = .run
        }
    }

    func startRun() {
        guard let project, let traceStore else { return }
        if runSession.hasActiveRunTask {
            statusMessage = "Run already in progress"
            notify()
            return
        }
        if pendingApproval != nil {
            selectedTab = .run
            statusMessage = "Approve or reject what will be passed to the next step"
            notify()
            return
        }
        if !validationIssues.isEmpty {
            errorMessage = "Fix workflow validation issues before running"
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
        errorMessage = nil
        statusMessage = "Run starting…"
        notify()
        runSession.start(
            project: project,
            goal: goalDraft,
            traceStore: traceStore,
            onProgress: { [weak self] snapshot in
                guard let self else { return }
                if let message = self.runSession.applyProgressSnapshot(
                    snapshot,
                    whileRunning: true,
                    org: self.project?.org
                ) {
                    self.statusMessage = message
                }
                self.notifyProgress()
            },
            onFinished: { [weak self] status, error in
                guard let self else { return }
                if let status { self.statusMessage = status }
                if let error, self.errorMessage == nil { self.errorMessage = error }
                self.notify()
            }
        )
    }

    func approve() {
        if runSession.hasActiveRunTask {
            statusMessage = "Run already in progress"
            notify()
            return
        }
        notify()
        runSession.approve(
            projectOrg: project?.org,
            traceStore: traceStore,
            onProgress: { [weak self] snapshot in
                guard let self else { return }
                if let message = self.runSession.applyProgressSnapshot(
                    snapshot,
                    whileRunning: true,
                    org: self.project?.org
                ) {
                    self.statusMessage = message
                }
                self.notifyProgress()
            },
            onFinished: { [weak self] status, error in
                guard let self else { return }
                if let status { self.statusMessage = status }
                if let error, self.errorMessage == nil { self.errorMessage = error }
                self.notify()
            }
        )
    }

    func rejectApproval() {
        Task {
            let result = await runSession.rejectApproval(traceStore: traceStore)
            if let status = result.status { statusMessage = status }
            if let error = result.error { errorMessage = error }
            notify()
        }
    }

    func cancelRun() {
        runSession.cancel(traceStore: traceStore)
        statusMessage = "Cancelling…"
        notify()
    }

    func retryRun() {
        if runSession.hasActiveRunTask {
            statusMessage = "Run already in progress"
            notify()
            return
        }
        if !(run?.status == .failed || run?.status == .cancelled) {
            statusMessage = "Can only retry a failed or cancelled run"
            notify()
            return
        }
        notify()
        runSession.retry(
            projectOrg: project?.org,
            traceStore: traceStore,
            onProgress: { [weak self] snapshot in
                guard let self else { return }
                if let message = self.runSession.applyProgressSnapshot(
                    snapshot,
                    whileRunning: true,
                    org: self.project?.org
                ) {
                    self.statusMessage = message
                }
                self.notifyProgress()
            },
            onFinished: { [weak self] status, error in
                guard let self else { return }
                if let status { self.statusMessage = status }
                if let error, self.errorMessage == nil || status == "Can only retry a failed or cancelled run" {
                    self.errorMessage = error
                }
                self.notify()
            }
        )
    }

    func loadRun(_ run: RunRecord) {
        selectedTab = .trace
        notify()
        runSession.loadRun(run, traceStore: traceStore) { [weak self] error in
            guard let self else { return }
            if let error { self.errorMessage = error }
            self.notify()
        }
    }

    func exportTrace() {
        Task {
            let result = await runSession.exportTrace(traceStore: traceStore)
            if let path = result.path {
                statusMessage =
                    "Exported trace to \(path) — may still contain summaries/paths; treat as sensitive"
            }
            if let error = result.error {
                errorMessage = error
            }
            notify()
        }
    }

    func ensureArtifactsGitignore() {
        do {
            try projectSession.ensureArtifactsGitignore()
            statusMessage = "Ensured artifacts .gitignore"
        } catch {
            errorMessage = error.localizedDescription
        }
        notify()
    }

    // MARK: - Org mutations

    func addNode() {
        if let id = projectSession.addNode() {
            selectedNodeId = id
            selectedEdgeId = nil
        }
        notify()
    }

    func replaceNode(_ node: OrgNode) {
        projectSession.replaceNode(node)
        notify()
    }

    func deleteNode(id: String) {
        let nextSelection = projectSession.deleteNode(id: id)
        if selectedNodeId == id {
            selectedNodeId = nextSelection
        }
        notify()
    }

    func setEntry(_ id: String) {
        projectSession.setEntry(id)
        notify()
    }

    func addFixedEdge(from: String? = nil, to: String? = nil) {
        if let edgeId = projectSession.addFixedEdge(from: from, to: to) {
            selectedEdgeId = edgeId
            selectedNodeId = nil
        }
        notify()
    }

    func addRouterEdge(from: String? = nil, to: String? = nil) {
        if let edgeId = projectSession.addRouterEdge(from: from, to: to) {
            selectedEdgeId = edgeId
            selectedNodeId = nil
        }
        notify()
    }

    func replaceEdge(_ edge: OrgEdge) {
        projectSession.replaceEdge(edge)
        notify()
    }

    func deleteEdge(id: String) {
        projectSession.deleteEdge(id: id)
        if selectedEdgeId == id { selectedEdgeId = nil }
        notify()
    }

    func deleteSelection() {
        if let id = selectedNodeId {
            deleteNode(id: id)
        } else if let id = selectedEdgeId {
            deleteEdge(id: id)
        }
    }

    func focusValidationIssue(_ issue: OrgValidationIssue) {
        selectedTab = .org
        if let edgeId = issue.focusEdgeId {
            selectedEdgeId = edgeId
            selectedNodeId = nil
        } else if let nodeId = issue.focusNodeId {
            selectedNodeId = nodeId
            selectedEdgeId = nil
        }
        shouldCenterSelection = true
        notify()
    }

    func consumeCenterSelectionRequest() {
        shouldCenterSelection = false
    }

    func requestFitCanvas() {
        selectedTab = .org
        shouldFitCanvas = true
        notify()
    }

    func consumeFitCanvasRequest() -> Bool {
        let request = shouldFitCanvas
        shouldFitCanvas = false
        return request
    }
}
