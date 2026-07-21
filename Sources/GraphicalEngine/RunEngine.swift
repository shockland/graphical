import Foundation
import GraphicalDomain
import GraphicalCLI

public enum RunEngineError: Error, LocalizedError, Equatable {
    case invalidOrg([String])
    case missingRunner(String)
    case missingEntry
    case missingNode(String)
    case routerTargetNotAllowed(String)
    case missingRouterNext
    case noOutgoingEdge(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOrg(let issues): return "Invalid org: \(issues.joined(separator: "; "))"
        case .missingRunner(let name): return "Missing runner '\(name)'"
        case .missingEntry: return "Org has no entry node"
        case .missingNode(let id): return "Missing node '\(id)'"
        case .routerTargetNotAllowed(let id): return "Router target '\(id)' not in allowlist"
        case .missingRouterNext: return "Router node did not produce next hop"
        case .noOutgoingEdge(let id): return "No outgoing edge from '\(id)'"
        case .cancelled: return "Run cancelled"
        case .failed(let message): return message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidOrg:
            return "Fix the workflow issues shown in the validation banner, then try Play again."
        case .missingRunner:
            return "Open Agents to add or fix that runner, or re-pick a coding tool."
        case .missingEntry:
            return "In Org, set an entry step for the workflow."
        case .missingNode:
            return "In Org, restore the missing step or fix edges that point to it."
        case .routerTargetNotAllowed:
            return "Have the router choose a next hop that is on its allowlist, or widen the allowlist."
        case .missingRouterNext:
            return "Ensure the router step writes a valid next hop (next.json) before finishing."
        case .noOutgoingEdge:
            return "In Org, add a success edge from that step to the next step."
        case .cancelled:
            return nil
        case .failed(let message):
            return Self.recoverySuggestion(forFailedMessage: message)
        }
    }

    /// Recovery copy for free-form `.failed` messages thrown mid-run.
    static func recoverySuggestion(forFailedMessage message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("exhausted iterations") || lower.contains("without passing done-checks") {
            return "Retry the step, loosen that step's done-checks, or raise maxIterations."
        }
        if lower.contains("on: reject") || lower.contains("reject.json") {
            return "In Org, add an outgoing edge with on: reject from that step."
        }
        if lower.contains("no pending approval") {
            return "Start or resume a run that pauses for approval, then Approve or Reject."
        }
        if lower.contains("no active node to retry") || lower.contains("can only retry") {
            return "Retry only works after a failed or cancelled run that still has an active step."
        }
        return "Open History for this run to inspect the failing step, then Retry or fix the workflow."
    }

    /// Builds the exhaustion failure message used when a node burns its iteration budget.
    public static func exhaustedIterationsMessage(
        role: String,
        nodeId: String,
        failedChecks: [String]
    ) -> String {
        let label = role.isEmpty ? nodeId : role
        var message = "\(label) exhausted iterations without passing done-checks"
        if !failedChecks.isEmpty {
            message += " (still failing: \(failedChecks.joined(separator: ", ")))"
        }
        return message
    }

    /// Builds the reject-without-edge failure message.
    public static func rejectWithoutEdgeMessage(role: String, nodeId: String) -> String {
        let label = role.isEmpty ? nodeId : role
        return "\(label) signaled reject.json but has no outgoing 'on: reject' edge"
    }
}

public struct PendingApproval: Equatable, Sendable {
    public var runId: String
    public var inspection: HandoffInspection
}

public struct RunProgressSnapshot: Sendable {
    public var run: RunRecord?
    public var liveLog: [String]
    public var pendingApproval: PendingApproval?
    public var lastInspection: HandoffInspection?
    public var phase: String?
    public var iteration: Int?
    /// Nodes currently inside their node loop (parallel fan-out can have several).
    public var activeNodeIds: [String]
}

public actor RunEngine {
    public private(set) var currentRun: RunRecord?
    public private(set) var pendingApproval: PendingApproval?
    public private(set) var lastInspection: HandoffInspection?
    public private(set) var liveLog: [String] = []
    public private(set) var currentPhase: String?
    public private(set) var currentIteration: Int?

    private let store: TraceStore
    private let processRunner: any ProcessExecuting
    private let cli: CLIRunner
    private let checker: DoneCheckEvaluator
    private let fileManager: FileManager
    /// How often to refresh phase/status while an agent CLI is running with little
    /// or no stdout — keeps the Run console from looking frozen.
    private let progressHeartbeatNanoseconds: UInt64
    /// Emit a live-log "still working…" line every N heartbeats (0 = never).
    private let progressHeartbeatLogEvery: Int

    private var cancelRequested = false
    private var project: GraphicalProject?
    /// Inbound handoff retained across approval pause for retry after approve.
    private var pausedInbound: HandoffContract?
    /// Multi-inbound retained when pausing approval after a join (rare; MVP gates post-auditor).
    private var pausedInbounds: [(fromNodeId: String, contract: HandoffContract)] = []
    /// Last non-nil inbound handoff a node was actually entered with, keyed by node id.
    /// Lets `retryActiveNode` re-enter a failed mid-graph node without dropping the
    /// prior summary/artifacts it was given (see plan 008).
    private var lastInboundByNode: [String: HandoffContract] = [:]
    /// Multi-inbound packets for join destinations (e.g. auditor), keyed by node id.
    private var lastMultiInboundByNode: [String: [(fromNodeId: String, contract: HandoffContract)]] = [:]
    /// Nodes that have succeeded in the current run (join barrier tracking).
    private var completedNodes: Set<String> = []
    /// Filtered handoffs waiting at a join destination: dest → (from → contract).
    private var joinInbound: [String: [String: HandoffContract]] = [:]
    /// Ready queue of lane heads / join destinations.
    private var readyQueue: [ReadyWork] = []
    private var isDrainingReadyQueue = false
    /// Nodes currently executing their node loop (multiple during parallel fan-out).
    private var workingNodeIds: Set<String> = []
    private var progressHandler: (@Sendable (RunProgressSnapshot) async -> Void)?
    private var invokeHeartbeatTask: Task<Void, Never>?
    private var invokeStartedAt: Date?
    private var agentOutputReceived = false
    private var invokeNodeId: String?
    /// Incomplete stdout/stderr lines spanning `ProcessOutputChunk`s.
    private var stdoutLineRemainder = ""
    private var stderrLineRemainder = ""
    private var streamJSONFormatter = CursorStreamJSONFormatter()
    /// Coalesces tiny stream-json assistant deltas into fewer live-log lines.
    private var pendingAssistantText = ""
    private var lastStreamPublishAt: Date?
    /// Soft cap on in-memory live log lines (CLI text is never written to SQLite).
    public static let maxLiveLogLines = 2_000
    /// Minimum interval between progress publishes while streaming agent output.
    private static let streamPublishMinInterval: TimeInterval = 0.1
    /// Flush coalesced assistant deltas once they reach this size.
    private static let assistantCoalesceLimit = 120

    private struct ReadyWork {
        var nodeId: String
        var inbound: HandoffContract?
        var inbounds: [(fromNodeId: String, contract: HandoffContract)]
        /// Fan-out siblings share a cohort id so they can drain concurrently.
        var cohortID: UUID?
    }
    public init(
        store: TraceStore,
        processRunner: any ProcessExecuting = ProcessRunner(),
        progressHeartbeatNanoseconds: UInt64 = 2_000_000_000,
        progressHeartbeatLogEvery: Int = 5
    ) {
        self.store = store
        self.processRunner = processRunner
        self.cli = CLIRunner(processRunner: processRunner)
        self.checker = DoneCheckEvaluator(processRunner: processRunner)
        self.fileManager = .default
        self.progressHeartbeatNanoseconds = progressHeartbeatNanoseconds
        self.progressHeartbeatLogEvery = progressHeartbeatLogEvery
    }

    public func setProgressHandler(_ handler: (@Sendable (RunProgressSnapshot) async -> Void)?) {
        progressHandler = handler
    }

    public func snapshot() -> RunProgressSnapshot {
        RunProgressSnapshot(
            run: currentRun,
            liveLog: liveLog,
            pendingApproval: pendingApproval,
            lastInspection: lastInspection,
            phase: currentPhase,
            iteration: currentIteration,
            activeNodeIds: workingNodeIds.sorted()
        )
    }

    /// Starts a run. Returns when succeeded, failed, cancelled, or awaiting approval.
    public func start(project: GraphicalProject, goal: String?) async throws -> RunRecord {
        let issues = OrgValidator.validate(org: project.org, runners: project.runners)
            .filter { !$0.isWarning }
        if !issues.isEmpty {
            throw RunEngineError.invalidOrg(issues.map(\.message))
        }
        guard let entry = project.org.entryNodeId else {
            throw RunEngineError.missingEntry
        }

        cancelRequested = false
        processRunner.prepareForNewRun()
        pendingApproval = nil
        lastInspection = nil
        pausedInbound = nil
        pausedInbounds = []
        lastInboundByNode = [:]
        lastMultiInboundByNode = [:]
        completedNodes = []
        joinInbound = [:]
        readyQueue = []
        isDrainingReadyQueue = false
        workingNodeIds = []
        stopInvokeHeartbeat()
        liveLog = []
        currentPhase = "starting"
        currentIteration = nil
        self.project = project

        var run = RunRecord(
            projectRoot: project.root.path,
            goal: goal ?? project.config.goal,
            status: .running,
            activeNodeId: entry
        )
        try await commitRun(run)
        try await trace(runId: run.id, kind: .runStarted, message: "Run started at \(entry)", nodeId: entry)
        log("Run started at \(entry)")
        await publishProgress()

        enqueueReady(nodeId: entry, inbound: nil)
        try await drainReadyQueue(run: &run, project: project)
        return currentRun ?? run
    }

    public func approve(notes: String? = nil) async throws -> RunRecord {
        guard var run = currentRun, let pending = pendingApproval, let project else {
            throw RunEngineError.failed("No pending approval")
        }
        var contract = pending.inspection.passed
        if let notes, !notes.isEmpty {
            contract.notes = notes
        }
        try await trace(
            runId: run.id,
            kind: .approved,
            message: "Approved handoff to \(pending.inspection.toNode)",
            nodeId: pending.inspection.fromNode,
            payload: pending.inspection
        )
        let destination = pending.inspection.toNode
        pendingApproval = nil
        let inbound = contract
        let inbounds = pausedInbounds
        pausedInbound = nil
        pausedInbounds = []
        cancelRequested = false
        processRunner.prepareForNewRun()
        run.status = .running
        run.updatedAt = Date()
        try await commitRun(run)

        if inbounds.isEmpty {
            enqueueReady(nodeId: destination, inbound: inbound)
        } else {
            enqueueReady(nodeId: destination, inbounds: inbounds)
        }
        try await drainReadyQueue(run: &run, project: project)
        return currentRun ?? run
    }

    public func rejectApproval(notes: String) async throws -> RunRecord {
        guard var run = currentRun, let pending = pendingApproval else {
            throw RunEngineError.failed("No pending approval")
        }
        try await trace(
            runId: run.id,
            kind: .rejected,
            message: "Rejected handoff: \(notes)",
            nodeId: pending.inspection.fromNode
        )
        pendingApproval = nil
        pausedInbound = nil
        pausedInbounds = []
        run.status = .failed
        run.updatedAt = Date()
        try await commitRun(run)
        try await trace(runId: run.id, kind: .runFailed, message: "Run failed after approval rejection")
        return run
    }

    public func cancel() async throws {
        cancelRequested = true
        processRunner.cancelCurrent()
        stopInvokeHeartbeat()
        guard var run = currentRun else { return }
        // Cancel is a stuck-UI escape hatch; never clobber a terminal outcome.
        if run.status == .succeeded || run.status == .failed || run.status == .cancelled {
            return
        }
        // Drop a pending approval gate so the Run console doesn't keep Approve/Reject
        // enabled after the user cancels out of an awaiting-approval pause.
        pendingApproval = nil
        pausedInbound = nil
        pausedInbounds = []
        currentPhase = "cancelling"
        await publishProgress()
        run.status = .cancelled
        run.updatedAt = Date()
        try await commitRun(run)
        try await trace(runId: run.id, kind: .runCancelled, message: "Run cancelled")
    }

    public func retryActiveNode() async throws {
        guard var run = currentRun, let nodeId = run.activeNodeId, let project else {
            throw RunEngineError.failed("No active node to retry")
        }
        guard run.status == .failed || run.status == .cancelled else {
            throw RunEngineError.failed("Can only retry failed/cancelled runs")
        }
        cancelRequested = false
        processRunner.prepareForNewRun()
        run.status = .running
        run.updatedAt = Date()
        try await commitRun(run)
        try await trace(runId: run.id, kind: .retry, message: "Retrying node \(nodeId)", nodeId: nodeId)
        if let multi = lastMultiInboundByNode[nodeId], !multi.isEmpty {
            enqueueReady(nodeId: nodeId, inbounds: multi)
        } else {
            enqueueReady(nodeId: nodeId, inbound: lastInboundByNode[nodeId])
        }
        try await drainReadyQueue(run: &run, project: project)
    }

    // MARK: - Ready queue / mesh scheduling

    private func enqueueReady(
        nodeId: String,
        inbound: HandoffContract? = nil,
        inbounds: [(fromNodeId: String, contract: HandoffContract)] = [],
        cohortID: UUID? = nil
    ) {
        readyQueue.append(
            ReadyWork(nodeId: nodeId, inbound: inbound, inbounds: inbounds, cohortID: cohortID)
        )
    }

    private func drainReadyQueue(run: inout RunRecord, project: GraphicalProject) async throws {
        if isDrainingReadyQueue { return }
        isDrainingReadyQueue = true
        defer { isDrainingReadyQueue = false }

        while !readyQueue.isEmpty {
            if cancelRequested { throw RunEngineError.cancelled }
            // Stop draining if an approval gate paused the run.
            if run.status == .awaitingApproval { return }

            if project.config.parallelFanOut,
               let cohortID = readyQueue.first?.cohortID,
               readyQueue.filter({ $0.cohortID == cohortID }).count > 1 {
                let batch = readyQueue.filter { $0.cohortID == cohortID }
                readyQueue.removeAll { $0.cohortID == cohortID }
                try await executeParallelCohort(batch, run: &run, project: project)
            } else {
                let work = readyQueue.removeFirst()
                let pendingCount = readyQueue.count
                if pendingCount > 0 {
                    currentPhase = "lane queue: \(pendingCount) waiting"
                    log("Ready queue: running \(work.nodeId) (\(pendingCount) still waiting)")
                    await publishProgress()
                }
                try await executeFrom(
                    nodeId: work.nodeId,
                    inbound: work.inbound,
                    inbounds: work.inbounds,
                    run: &run,
                    project: project
                )
            }

            if let latest = currentRun {
                run = latest
            }
            if run.status == .awaitingApproval
                || run.status == .succeeded
                || run.status == .failed
                || run.status == .cancelled {
                return
            }
        }
    }

    /// Runs fan-out lane heads concurrently; each lane still depth-firsts until join.
    private func executeParallelCohort(
        _ batch: [ReadyWork],
        run: inout RunRecord,
        project: GraphicalProject
    ) async throws {
        let names = batch.map(\.nodeId).joined(separator: ", ")
        currentPhase = "parallel lanes: \(batch.count)"
        log("Running \(batch.count) lanes in parallel: \(names)")
        await publishProgress()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for work in batch {
                    group.addTask {
                        try await self.executeLaneWork(work, project: project)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            cancelRequested = true
            processRunner.cancelCurrent()
            throw error
        }

        if let latest = currentRun {
            run = latest
        }
    }

    private func executeLaneWork(_ work: ReadyWork, project: GraphicalProject) async throws {
        if cancelRequested || Task.isCancelled { throw RunEngineError.cancelled }
        guard var run = currentRun else {
            throw RunEngineError.failed("Missing run state for parallel lane")
        }
        try await executeFrom(
            nodeId: work.nodeId,
            inbound: work.inbound,
            inbounds: work.inbounds,
            run: &run,
            project: project
        )
        mergeLaneRun(run)
    }

    /// Merges a lane's local `RunRecord` copy without letting `.running` clobber a
    /// settled status written by a sibling lane (fail / cancel / approval / success).
    private func mergeLaneRun(_ laneRun: RunRecord) {
        syncCurrentRun(laneRun)
    }

    /// Persists run state; ignores `.running` writes that would clobber a settled status.
    private func commitRun(_ run: RunRecord) async throws {
        syncCurrentRun(run)
        if let current = currentRun {
            try await store.saveRun(current)
        }
    }

    private func syncCurrentRun(_ run: RunRecord) {
        if let current = currentRun, run.status == .running, Self.isSettled(current.status) {
            return
        }
        currentRun = run
    }

    private static func isSettled(_ status: RunStatus) -> Bool {
        switch status {
        case .awaitingApproval, .succeeded, .failed, .cancelled:
            return true
        case .running, .pending:
            return false
        }
    }

    // MARK: - Core loop

    private func executeFrom(
        nodeId: String,
        inbound: HandoffContract?,
        inbounds: [(fromNodeId: String, contract: HandoffContract)] = [],
        run: inout RunRecord,
        project: GraphicalProject
    ) async throws {
        if cancelRequested { throw RunEngineError.cancelled }

        guard let node = project.org.node(id: nodeId) else {
            throw RunEngineError.missingNode(nodeId)
        }
        guard let runner = project.runners.runners[node.runner] else {
            throw RunEngineError.missingRunner(node.runner)
        }

        if !inbounds.isEmpty {
            lastMultiInboundByNode[nodeId] = inbounds
        } else if let inbound {
            lastInboundByNode[nodeId] = inbound
        }

        workingNodeIds.insert(nodeId)
        defer { workingNodeIds.remove(nodeId) }

        run.activeNodeId = nodeId
        try throwIfCancelled()
        run.status = .running
        run.updatedAt = Date()
        try await commitRun(run)
        currentPhase = "preparing"
        currentIteration = nil
        log("→ \(node.role) (\(nodeId))")
        await publishProgress()

        let nodeArtifacts = GraphicalPaths.nodeArtifacts(
            projectRoot: project.root,
            runId: run.id,
            nodeId: nodeId
        )
        try fileManager.createDirectory(at: nodeArtifacts, withIntermediateDirectories: true)

        var missingHints: [String] = node.done.checks.map(\.displayName)
        var lastChecks: [CheckResult] = []
        var routerNext: RouterNext?
        var succeeded = false

        let timeout = node.timeoutSeconds ?? project.config.defaultTimeoutSeconds

        for iteration in 1...node.maxIterations {
            if cancelRequested { throw RunEngineError.cancelled }

            try await trace(
                runId: run.id,
                kind: .iterationStarted,
                message: "Iteration \(iteration)/\(node.maxIterations)",
                nodeId: nodeId,
                iteration: iteration
            )
            currentIteration = iteration
            currentPhase = "preparing packet"
            log("[\(nodeId)] iteration \(iteration)/\(node.maxIterations)")
            await publishProgress()

            let effectiveModel = runner.effectiveModel(nodeModel: node.model)
            let packet = WorkingPacketBuilder.build(
                project: project,
                run: run,
                node: node,
                iteration: iteration,
                inbound: inbound,
                missingChecks: missingHints,
                nodeArtifacts: nodeArtifacts,
                modelHint: effectiveModel,
                inbounds: inbounds
            )
            let promptURL = nodeArtifacts.appendingPathComponent("packet-\(iteration).md")
            log("[\(nodeId)] writing working packet…")
            currentPhase = "writing packet"
            await publishProgress()
            try packet.write(to: promptURL, atomically: true, encoding: .utf8)

            let context = RunnerContext(
                projectRoot: project.root,
                promptFile: promptURL,
                nodeArtifacts: nodeArtifacts,
                runArtifacts: GraphicalPaths.runArtifacts(projectRoot: project.root, runId: run.id),
                runId: run.id,
                nodeId: nodeId,
                model: effectiveModel
            )

            var launchLine = "[\(nodeId)] launching \(node.runner)"
            if let model = effectiveModel, !model.isEmpty {
                launchLine += " · model \(model)"
            }
            log(launchLine)
            currentPhase = "launching agent"
            await publishProgress()

            startInvokeHeartbeat(nodeId: nodeId)
            await publishProgress()
            let result: ProcessResult
            do {
                result = try await cli.invoke(
                    template: runner,
                    context: context,
                    timeoutSeconds: timeout,
                    onOutput: { [weak self] chunk in
                        await self?.streamAgentOutput(chunk, nodeId: nodeId)
                    }
                )
                await flushAgentOutput(nodeId: nodeId)
            } catch {
                await flushAgentOutput(nodeId: nodeId)
                stopInvokeHeartbeat()
                throw error
            }
            stopInvokeHeartbeat()
            try throwIfCancelled()
            try await trace(
                runId: run.id,
                kind: .cliFinished,
                message: result.timedOut
                    ? "CLI timed out"
                    : "CLI exit \(result.exitCode)",
                nodeId: nodeId,
                iteration: iteration,
                payloadJSON: encodeJSON(
                    cliFinishedPayload(result: result, includeOutput: project.config.traceCLIOutput)
                )
            )
            if result.timedOut {
                log("[\(nodeId)] cli timed out")
            } else {
                log("[\(nodeId)] cli exit \(result.exitCode)")
            }
            currentPhase = "evaluating checks"
            log("[\(nodeId)] evaluating done-checks…")
            await publishProgress()

            routerNext = NodeArtifacts.loadRouterNext(from: nodeArtifacts)
            let evaluation = await checker.evaluate(
                group: node.done,
                nodeArtifacts: nodeArtifacts,
                projectRoot: project.root,
                routerNext: routerNext
            )
            try throwIfCancelled()
            lastChecks = evaluation.results
            try await trace(
                runId: run.id,
                kind: .checksEvaluated,
                message: evaluation.passed ? "Done-checks passed" : "Done-checks failed",
                nodeId: nodeId,
                iteration: iteration,
                payloadJSON: encodeJSON(evaluation.results)
            )

            if evaluation.passed {
                succeeded = true
                log("[\(nodeId)] done-checks passed")
                await publishProgress()
                break
            }
            missingHints = evaluation.results.filter { !$0.passed }.map(\.name)
            log("[\(nodeId)] done-checks failed; retrying")
            await publishProgress()
        }

        if !succeeded {
            // Try escalate via fail edge
            if let failEdge = project.org.outgoingEdges(from: nodeId).first(where: { $0.on == .fail }),
               let to = failEdge.to {
                try await trace(
                    runId: run.id,
                    kind: .escalate,
                    message: "Escalating to \(to) after budget exhausted",
                    nodeId: nodeId
                )
                let contract = NodeArtifacts.buildContract(
                    nodeArtifacts: nodeArtifacts,
                    checks: lastChecks,
                    routerNext: routerNext,
                    summaryFallback: "Node \(nodeId) failed done-checks"
                )
                workingNodeIds.remove(nodeId)
                await publishProgress()
                try await handoff(
                    from: node,
                    edge: failEdge,
                    contract: contract,
                    run: &run,
                    project: project
                )
                return
            }

            try throwIfCancelled()
            run.status = .failed
            run.updatedAt = Date()
            try await commitRun(run)
            try await trace(
                runId: run.id,
                kind: .nodeFailed,
                message: "Node \(nodeId) exhausted iterations",
                nodeId: nodeId
            )
            try await trace(runId: run.id, kind: .runFailed, message: "Run failed at \(nodeId)")
            throw RunEngineError.failed(
                RunEngineError.exhaustedIterationsMessage(
                    role: node.role,
                    nodeId: nodeId,
                    failedChecks: missingHints
                )
            )
        }

        try await trace(
            runId: run.id,
            kind: .nodeSucceeded,
            message: "Node \(nodeId) completed",
            nodeId: nodeId
        )
        completedNodes.insert(nodeId)
        // Drop glow before routing so a depth-first lane handoff doesn't keep the
        // parent lit while its child runs (parallel siblings stay highlighted).
        workingNodeIds.remove(nodeId)
        await publishProgress()

        let contract = NodeArtifacts.buildContract(
            nodeArtifacts: nodeArtifacts,
            checks: lastChecks,
            routerNext: routerNext,
            summaryFallback: "\(node.role) completed"
        )

        // Reject routing (plan 009 / plans/009-decision.md): a node whose done-checks
        // passed can still signal "send this back" by writing reject.json. Checked
        // before success routing; absent (or reject: false) falls through unchanged.
        if let reject = NodeArtifacts.loadReject(from: nodeArtifacts), reject.reject {
            try await routeReject(
                reject: reject,
                from: node,
                contract: contract,
                routerNext: routerNext,
                nodeArtifacts: nodeArtifacts,
                run: &run,
                project: project
            )
            return
        }

        // Terminal node? no success/always outgoing edges
        let outgoing = project.org.outgoingEdges(from: nodeId)
        let successEdges = outgoing.filter { $0.on == .success || $0.on == .always }
        if successEdges.isEmpty {
            try throwIfCancelled()
            run.status = .succeeded
            run.activeNodeId = nil
            run.updatedAt = Date()
            try await commitRun(run)
            currentPhase = "completed"
            currentIteration = nil
            log("Run succeeded")
            await publishProgress()
            try await trace(runId: run.id, kind: .runSucceeded, message: "Run succeeded at terminal node \(nodeId)")
            return
        }

        var outbound = contract
        if let next = routerNext {
            outbound.next = next
        }

        // Fan-out: enqueue all targets with the same filtered contract (AND-activate).
        if let fanOut = EdgeRouting.fanOutEdge(in: outgoing, on: [.success, .always]) {
            let filtered = outbound.filtered(passing: fanOut.pass)
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Fan-out to \(fanOut.targets.joined(separator: ", "))",
                nodeId: nodeId
            )
            let cohortID = project.config.parallelFanOut && fanOut.targets.count > 1
                ? UUID()
                : nil
            for target in fanOut.targets {
                let inspection = HandoffInspection(
                    edgeId: fanOut.id,
                    fromNode: node.id,
                    toNode: target,
                    passed: filtered.passed,
                    withheld: filtered.withheld,
                    requiresApproval: false,
                    nextHopReason: outbound.next?.reason
                )
                lastInspection = inspection
                try await trace(
                    runId: run.id,
                    kind: .handoffBuilt,
                    message: "Handoff \(node.id) → \(target)",
                    nodeId: node.id,
                    payloadJSON: encodeJSON(inspection)
                )
                enqueueReady(nodeId: target, inbound: filtered.passed, cohortID: cohortID)
            }
            let mode = cohortID == nil ? "queued" : "parallel"
            currentPhase = "fan-out: \(fanOut.targets.count) lanes \(mode)"
            log("[\(nodeId)] fan-out → \(fanOut.targets.count) lanes (\(mode))")
            await publishProgress()
            return
        }

        let selection = try selectOutgoingEdge(
            outgoing: outgoing,
            on: [.success, .always],
            nodeId: nodeId,
            routerNext: routerNext,
            nodeArtifacts: nodeArtifacts
        )
        if let next = selection.chosenRouterNext {
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Router chose \(selection.destination): \(next.reason)",
                nodeId: nodeId,
                payloadJSON: encodeJSON(next)
            )
        } else if selection.edge.type == .join {
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Join edge to \(selection.destination)",
                nodeId: nodeId
            )
        } else {
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Fixed edge to \(selection.destination)",
                nodeId: nodeId
            )
        }

        if selection.edge.type == .join {
            try await scheduleJoin(
                from: node,
                edge: selection.edge,
                destination: selection.destination,
                contract: outbound,
                run: &run,
                project: project
            )
            return
        }

        try await handoff(
            from: node,
            edge: selection.edge,
            contract: outbound,
            forcedDestination: selection.destination,
            run: &run,
            project: project
        )
    }

    /// Records a join inbound; when all predecessors have arrived, enqueues the destination.
    private func scheduleJoin(
        from node: OrgNode,
        edge: OrgEdge,
        destination: String,
        contract: HandoffContract,
        run: inout RunRecord,
        project: GraphicalProject
    ) async throws {
        let filtered = contract.filtered(passing: edge.pass)
        let inspection = HandoffInspection(
            edgeId: edge.id,
            fromNode: node.id,
            toNode: destination,
            passed: filtered.passed,
            withheld: filtered.withheld,
            requiresApproval: edge.requiresApproval,
            nextHopReason: contract.next?.reason
        )
        lastInspection = inspection
        try await trace(
            runId: run.id,
            kind: .handoffBuilt,
            message: "Handoff \(node.id) → \(destination) (join)",
            nodeId: node.id,
            payloadJSON: encodeJSON(inspection)
        )

        var byFrom = joinInbound[destination] ?? [:]
        byFrom[node.id] = filtered.passed
        joinInbound[destination] = byFrom

        let predecessors = project.org.joinPredecessors(of: destination)
        let arrived = predecessors.filter { byFrom[$0] != nil }.count
        currentPhase = "join: \(arrived)/\(predecessors.count) at \(destination)"
        log("[\(node.id)] join → \(destination) (\(arrived)/\(predecessors.count))")
        await publishProgress()

        guard !predecessors.isEmpty, predecessors.allSatisfy({ byFrom[$0] != nil }) else {
            return
        }

        let inbounds = predecessors.compactMap { fromId -> (fromNodeId: String, contract: HandoffContract)? in
            guard let contract = byFrom[fromId] else { return nil }
            return (fromId, contract)
        }
        try await trace(
            runId: run.id,
            kind: .joinReady,
            message: "Join ready at \(destination) (\(inbounds.count) lanes)",
            nodeId: destination
        )
        log("Join barrier met at \(destination)")

        if edge.requiresApproval {
            // MVP: seed avoids approval on join; if set, pause with aggregated notes.
            let aggregate = HandoffContract(
                summary: "Join of \(inbounds.count) lanes ready for \(destination)",
                artifacts: inbounds.flatMap(\.contract.artifacts),
                notes: inbounds.map { "\($0.fromNodeId): \($0.contract.summary)" }.joined(separator: " | ")
            )
            let joinInspection = HandoffInspection(
                edgeId: edge.id,
                fromNode: node.id,
                toNode: destination,
                passed: aggregate,
                withheld: [],
                requiresApproval: true,
                nextHopReason: nil
            )
            lastInspection = joinInspection
            try throwIfCancelled()
            run.status = .awaitingApproval
            run.updatedAt = Date()
            try await commitRun(run)
            pendingApproval = PendingApproval(runId: run.id, inspection: joinInspection)
            pausedInbound = aggregate
            pausedInbounds = inbounds
            currentPhase = "awaiting approval"
            try await trace(
                runId: run.id,
                kind: .awaitingApproval,
                message: "Awaiting approval for \(destination)",
                nodeId: node.id,
                payloadJSON: encodeJSON(joinInspection)
            )
            log("Awaiting approval: join → \(destination)")
            await publishProgress()
            return
        }

        enqueueReady(nodeId: destination, inbounds: inbounds)
    }

    /// Routes a node-level reject signal to its `on: .reject` edge(s). Fails the run
    /// if reject was signaled but the node has no matching outgoing edge.
    private func routeReject(
        reject: RejectSignal,
        from node: OrgNode,
        contract: HandoffContract,
        routerNext: RouterNext?,
        nodeArtifacts: URL,
        run: inout RunRecord,
        project: GraphicalProject
    ) async throws {
        let outgoing = project.org.outgoingEdges(from: node.id)
        let rejectEdges = outgoing.filter { $0.on == .reject }
        guard !rejectEdges.isEmpty else {
            try throwIfCancelled()
            run.status = .failed
            run.updatedAt = Date()
            try await commitRun(run)
            try await trace(
                runId: run.id,
                kind: .nodeFailed,
                message: "Node \(node.id) signaled reject but has no outgoing 'on: reject' edge",
                nodeId: node.id
            )
            try await trace(runId: run.id, kind: .runFailed, message: "Run failed at \(node.id)")
            throw RunEngineError.failed(
                RunEngineError.rejectWithoutEdgeMessage(role: node.role, nodeId: node.id)
            )
        }

        var rejectContract = contract
        if let reason = reject.reason, !reason.isEmpty {
            rejectContract.notes = reason
        }
        try await trace(
            runId: run.id,
            kind: .rejected,
            message: "Node \(node.id) signaled reject: \(reject.reason ?? "")",
            nodeId: node.id
        )

        let selection = try selectOutgoingEdge(
            outgoing: outgoing,
            on: [.reject],
            nodeId: node.id,
            routerNext: routerNext,
            nodeArtifacts: nodeArtifacts
        )
        if let next = selection.chosenRouterNext {
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Reject router chose \(selection.destination): \(next.reason)",
                nodeId: node.id,
                payloadJSON: encodeJSON(next)
            )
        } else {
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Reject edge to \(selection.destination)",
                nodeId: node.id
            )
        }

        var outbound = rejectContract
        if let next = routerNext {
            outbound.next = next
        }

        try await handoff(
            from: node,
            edge: selection.edge,
            contract: outbound,
            forcedDestination: selection.destination,
            run: &run,
            project: project
        )
    }

    private func selectOutgoingEdge(
        outgoing: [OrgEdge],
        on: Set<EdgeCondition>,
        nodeId: String,
        routerNext: RouterNext?,
        nodeArtifacts: URL
    ) throws -> EdgeRouting.Selection {
        do {
            return try EdgeRouting.select(
                outgoing: outgoing,
                on: on,
                nodeId: nodeId,
                routerNext: routerNext,
                loadRouterNext: { NodeArtifacts.loadRouterNext(from: nodeArtifacts) }
            )
        } catch let error as EdgeRouting.Error {
            switch error {
            case .missingRouterNext:
                throw RunEngineError.missingRouterNext
            case .routerTargetNotAllowed(let id):
                throw RunEngineError.routerTargetNotAllowed(id)
            case .noOutgoingEdge(let id):
                throw RunEngineError.noOutgoingEdge(id)
            case .fanOutNotSelectable(let id):
                throw RunEngineError.failed("Node '\(id)' has a fan-out edge that must be scheduled by the engine")
            }
        }
    }

    private func handoff(
        from node: OrgNode,
        edge: OrgEdge,
        contract: HandoffContract,
        forcedDestination: String? = nil,
        run: inout RunRecord,
        project: GraphicalProject
    ) async throws {
        let destination = forcedDestination ?? edge.to ?? contract.next?.nodeId
        guard let destination else {
            throw RunEngineError.noOutgoingEdge(node.id)
        }

        let filtered = contract.filtered(passing: edge.pass)
        let inspection = HandoffInspection(
            edgeId: edge.id,
            fromNode: node.id,
            toNode: destination,
            passed: filtered.passed,
            withheld: filtered.withheld,
            requiresApproval: edge.requiresApproval,
            nextHopReason: contract.next?.reason
        )
        lastInspection = inspection
        currentPhase = "handoff to \(destination)"
        log("[\(node.id)] handoff → \(destination)")
        await publishProgress()
        try await trace(
            runId: run.id,
            kind: .handoffBuilt,
            message: "Handoff \(node.id) → \(destination)",
            nodeId: node.id,
            payloadJSON: encodeJSON(inspection)
        )

        if edge.requiresApproval {
            try throwIfCancelled()
            run.status = .awaitingApproval
            run.updatedAt = Date()
            try await commitRun(run)
            pendingApproval = PendingApproval(runId: run.id, inspection: inspection)
            pausedInbound = filtered.passed
            pausedInbounds = []
            currentPhase = "awaiting approval"
            try await trace(
                runId: run.id,
                kind: .awaitingApproval,
                message: "Awaiting approval for \(destination)",
                nodeId: node.id,
                payloadJSON: encodeJSON(inspection)
            )
            log("Awaiting approval: \(node.id) → \(destination)")
            await publishProgress()
            return
        }

        // Depth-first within a lane (fixed/router). Mesh fan-out/join use the ready queue.
        try await executeFrom(nodeId: destination, inbound: filtered.passed, run: &run, project: project)
    }

    // MARK: - Helpers

    private func throwIfCancelled() throws {
        if cancelRequested || currentRun?.status == .cancelled {
            throw RunEngineError.cancelled
        }
    }

    /// Trace payload for `.cliFinished`. Default (`includeOutput: false`, i.e.
    /// `ProjectConfig.traceCLIOutput` unset) persists only sizes/exit status to the
    /// durable SQLite trace store — never raw stdout/stderr, which routinely echoes
    /// secrets. See plans/011-trace-output-redaction.md.
    private func cliFinishedPayload(result: ProcessResult, includeOutput: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "exitCode": result.exitCode,
            "timedOut": result.timedOut,
            "truncated": result.truncated,
            "stdoutBytes": result.stdout.utf8.count,
            "stderrBytes": result.stderr.utf8.count
        ]
        if includeOutput {
            payload["stdoutPreview"] = String(result.stdout.prefix(2000))
            payload["stderrPreview"] = String(result.stderr.prefix(2000))
        }
        return payload
    }

    private func log(_ line: String) {
        liveLog.append(line)
        if liveLog.count > Self.maxLiveLogLines {
            liveLog.removeFirst(liveLog.count - Self.maxLiveLogLines)
        }
    }

    /// Agent output is intentionally kept in the in-memory live log only. Durable
    /// traces continue to follow the redaction policy in `cliFinishedPayload`.
    private func streamAgentOutput(_ chunk: ProcessOutputChunk, nodeId: String) async {
        let normalized = chunk.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return }

        let isStdout = chunk.stream == .stdout
        let remainder = isStdout ? stdoutLineRemainder : stderrLineRemainder
        let combined = remainder + normalized
        var parts = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let incomplete: String
        if combined.hasSuffix("\n") {
            incomplete = ""
            if parts.last?.isEmpty == true {
                parts.removeLast()
            }
        } else {
            incomplete = parts.popLast() ?? ""
        }
        if isStdout {
            stdoutLineRemainder = incomplete
        } else {
            stderrLineRemainder = incomplete
        }

        guard !parts.isEmpty else { return }

        if !agentOutputReceived {
            agentOutputReceived = true
            log("[\(nodeId)] receiving agent output…")
            currentPhase = invokePhaseLabel()
        }

        let streamLabel = isStdout ? "stdout" : "stderr"
        var appended = 0
        for part in parts {
            appended += appendFormattedAgentLine(part, nodeId: nodeId, streamLabel: streamLabel)
        }
        if appended > 0 {
            await publishStreamProgress(force: false)
        }
    }

    /// Flushes incomplete line buffers and coalesced assistant text after invoke ends.
    private func flushAgentOutput(nodeId: String) async {
        let leftovers: [(String, String)] = [
            (stdoutLineRemainder, "stdout"),
            (stderrLineRemainder, "stderr")
        ]
        stdoutLineRemainder = ""
        stderrLineRemainder = ""

        var appended = 0
        for (text, streamLabel) in leftovers where !text.isEmpty {
            if !agentOutputReceived {
                agentOutputReceived = true
                log("[\(nodeId)] receiving agent output…")
                currentPhase = invokePhaseLabel()
            }
            appended += appendFormattedAgentLine(text, nodeId: nodeId, streamLabel: streamLabel)
        }
        appended += flushPendingAssistantText(nodeId: nodeId)
        if appended > 0 {
            await publishStreamProgress(force: true)
        }
    }

    @discardableResult
    private func appendFormattedAgentLine(
        _ line: String,
        nodeId: String,
        streamLabel: String
    ) -> Int {
        // stderr stays raw; stream-json lives on stdout.
        if streamLabel == "stderr" {
            flushPendingAssistantText(nodeId: nodeId)
            log("[\(nodeId) \(streamLabel)] \(line)")
            return 1
        }

        switch streamJSONFormatter.format(line: line) {
        case .passthrough:
            flushPendingAssistantText(nodeId: nodeId)
            log("[\(nodeId) \(streamLabel)] \(line)")
            return 1
        case .skip:
            return 0
        case .display(let pieces):
            var count = flushPendingAssistantText(nodeId: nodeId)
            for piece in pieces {
                log("[\(nodeId) \(streamLabel)] \(piece)")
                count += 1
            }
            return count
        case .assistantText(let pieces):
            for piece in pieces {
                if pendingAssistantText.isEmpty {
                    pendingAssistantText = piece
                } else {
                    pendingAssistantText += piece
                }
            }
            if pendingAssistantText.count >= Self.assistantCoalesceLimit {
                flushPendingAssistantText(nodeId: nodeId)
            }
            // Count as activity even while text is still coalescing off the log.
            return pieces.isEmpty ? 0 : 1
        }
    }

    @discardableResult
    private func flushPendingAssistantText(nodeId: String) -> Int {
        guard !pendingAssistantText.isEmpty else { return 0 }
        let text = pendingAssistantText
        pendingAssistantText = ""
        log("[\(nodeId) stdout] \(text)")
        return 1
    }

    private func publishStreamProgress(force: Bool) async {
        let now = Date()
        if !force,
           let last = lastStreamPublishAt,
           now.timeIntervalSince(last) < Self.streamPublishMinInterval {
            return
        }
        // Flush coalesced deltas so the progress snapshot includes latest text.
        if let nodeId = invokeNodeId {
            flushPendingAssistantText(nodeId: nodeId)
        }
        lastStreamPublishAt = now
        await publishProgress()
    }

    private func startInvokeHeartbeat(nodeId: String) {
        stopInvokeHeartbeat()
        invokeNodeId = nodeId
        invokeStartedAt = Date()
        agentOutputReceived = false
        stdoutLineRemainder = ""
        stderrLineRemainder = ""
        streamJSONFormatter = CursorStreamJSONFormatter()
        pendingAssistantText = ""
        lastStreamPublishAt = nil
        currentPhase = invokePhaseLabel()
        log("[\(nodeId)] waiting for agent output…")

        let interval = progressHeartbeatNanoseconds
        guard interval > 0 else { return }

        invokeHeartbeatTask = Task { [weak self] in
            guard let self else { return }
            var ticks = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                ticks += 1
                await self.invokeHeartbeatTick(ticks: ticks)
            }
        }
    }

    private func stopInvokeHeartbeat() {
        invokeHeartbeatTask?.cancel()
        invokeHeartbeatTask = nil
        invokeStartedAt = nil
        invokeNodeId = nil
        agentOutputReceived = false
    }

    private func invokeHeartbeatTick(ticks: Int) async {
        guard invokeHeartbeatTask != nil, let nodeId = invokeNodeId else { return }
        currentPhase = invokePhaseLabel()
        if progressHeartbeatLogEvery > 0, ticks % progressHeartbeatLogEvery == 0 {
            let elapsed = invokeElapsedSeconds()
            log("[\(nodeId)] still working… \(Self.formatElapsed(elapsed))")
        }
        await publishProgress()
    }

    private func invokePhaseLabel() -> String {
        let elapsed = invokeElapsedSeconds()
        let activity = agentOutputReceived ? "receiving agent output" : "waiting for agent"
        return "\(activity) · \(Self.formatElapsed(elapsed))"
    }

    private func invokeElapsedSeconds() -> Int {
        guard let started = invokeStartedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(started)))
    }

    private static func formatElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let rem = seconds % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, rem)
        }
        return "\(seconds)s"
    }

    private func publishProgress() async {
        guard let progressHandler else { return }
        await progressHandler(snapshot())
    }

    private func trace(
        runId: String,
        kind: TraceEventKind,
        message: String,
        nodeId: String? = nil,
        iteration: Int? = nil,
        payloadJSON: String? = nil
    ) async throws {
        let event = TraceEvent(
            runId: runId,
            nodeId: nodeId,
            kind: kind,
            message: message,
            iteration: iteration,
            payloadJSON: payloadJSON
        )
        try await store.append(event)
    }

    private func trace<T: Encodable>(
        runId: String,
        kind: TraceEventKind,
        message: String,
        nodeId: String? = nil,
        iteration: Int? = nil,
        payload: T
    ) async throws {
        try await trace(
            runId: runId,
            kind: kind,
            message: message,
            nodeId: nodeId,
            iteration: iteration,
            payloadJSON: encodeJSON(payload)
        )
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
