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
}

public actor RunEngine {
    public private(set) var currentRun: RunRecord?
    public private(set) var pendingApproval: PendingApproval?
    public private(set) var lastInspection: HandoffInspection?
    public private(set) var liveLog: [String] = []
    public private(set) var currentPhase: String?
    public private(set) var currentIteration: Int?

    private let store: TraceStore
    private let cli: CLIRunner
    private let checker: DoneCheckEvaluator
    private let fileManager: FileManager

    private var cancelRequested = false
    private var project: GraphicalProject?
    /// Inbound handoff retained across approval pause for retry after approve.
    private var pausedInbound: HandoffContract?
    private var progressHandler: (@Sendable (RunProgressSnapshot) async -> Void)?

    public init(
        store: TraceStore,
        processRunner: any ProcessExecuting = ProcessRunner()
    ) {
        self.store = store
        self.cli = CLIRunner(processRunner: processRunner)
        self.checker = DoneCheckEvaluator(processRunner: processRunner)
        self.fileManager = .default
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
            iteration: currentIteration
        )
    }

    /// Starts a run. Returns when succeeded, failed, cancelled, or awaiting approval.
    public func start(project: GraphicalProject, goal: String?) async throws -> RunRecord {
        let issues = OrgValidator.validate(org: project.org, runners: project.runners)
        if !issues.isEmpty {
            throw RunEngineError.invalidOrg(issues.map(\.message))
        }
        guard let entry = project.org.entryNodeId else {
            throw RunEngineError.missingEntry
        }

        cancelRequested = false
        pendingApproval = nil
        lastInspection = nil
        pausedInbound = nil
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
        try await store.saveRun(run)
        currentRun = run
        try await trace(runId: run.id, kind: .runStarted, message: "Run started at \(entry)", nodeId: entry)
        log("Run started at \(entry)")
        await publishProgress()

        try await executeFrom(nodeId: entry, inbound: nil, run: &run, project: project)
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
        pausedInbound = nil
        run.status = .running
        run.updatedAt = Date()
        try await store.saveRun(run)
        currentRun = run

        try await executeFrom(
            nodeId: destination,
            inbound: contract,
            run: &run,
            project: project
        )
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
        run.status = .failed
        run.updatedAt = Date()
        try await store.saveRun(run)
        currentRun = run
        try await trace(runId: run.id, kind: .runFailed, message: "Run failed after approval rejection")
        return run
    }

    public func cancel() async throws {
        cancelRequested = true
        if var run = currentRun {
            run.status = .cancelled
            run.updatedAt = Date()
            try await store.saveRun(run)
            currentRun = run
            try await trace(runId: run.id, kind: .runCancelled, message: "Run cancelled")
        }
    }

    public func retryActiveNode() async throws {
        guard var run = currentRun, let nodeId = run.activeNodeId, let project else {
            throw RunEngineError.failed("No active node to retry")
        }
        guard run.status == .failed || run.status == .cancelled else {
            throw RunEngineError.failed("Can only retry failed/cancelled runs")
        }
        cancelRequested = false
        run.status = .running
        run.updatedAt = Date()
        try await store.saveRun(run)
        currentRun = run
        try await trace(runId: run.id, kind: .retry, message: "Retrying node \(nodeId)", nodeId: nodeId)
        try await executeFrom(nodeId: nodeId, inbound: nil, run: &run, project: project)
    }

    // MARK: - Core loop

    private func executeFrom(
        nodeId: String,
        inbound: HandoffContract?,
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

        run.activeNodeId = nodeId
        run.status = .running
        run.updatedAt = Date()
        try await store.saveRun(run)
        currentRun = run
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

        var missingHints: [String] = node.done.checks.map { checkLabel($0) }
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
            currentPhase = "invoking agent"
            currentIteration = iteration
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
                modelHint: effectiveModel
            )
            let promptURL = nodeArtifacts.appendingPathComponent("packet-\(iteration).md")
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

            let result = try await cli.invoke(template: runner, context: context, timeoutSeconds: timeout)
            try await trace(
                runId: run.id,
                kind: .cliFinished,
                message: result.timedOut
                    ? "CLI timed out"
                    : "CLI exit \(result.exitCode)",
                nodeId: nodeId,
                iteration: iteration,
                payloadJSON: encodeJSON([
                    "exitCode": result.exitCode,
                    "timedOut": result.timedOut,
                    "stdout": String(result.stdout.prefix(2000)),
                    "stderr": String(result.stderr.prefix(2000))
                ])
            )
            log("[\(nodeId)] cli exit \(result.exitCode)")
            currentPhase = "evaluating checks"
            await publishProgress()

            routerNext = loadRouterNext(from: nodeArtifacts)
            let evaluation = await checker.evaluate(
                group: node.done,
                nodeArtifacts: nodeArtifacts,
                projectRoot: project.root,
                routerNext: routerNext
            )
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
                let contract = buildContract(
                    nodeArtifacts: nodeArtifacts,
                    checks: lastChecks,
                    routerNext: routerNext,
                    summaryFallback: "Node \(nodeId) failed done-checks"
                )
                try await handoff(
                    from: node,
                    edge: failEdge,
                    contract: contract,
                    run: &run,
                    project: project
                )
                return
            }

            run.status = .failed
            run.updatedAt = Date()
            try await store.saveRun(run)
            currentRun = run
            try await trace(
                runId: run.id,
                kind: .nodeFailed,
                message: "Node \(nodeId) exhausted iterations",
                nodeId: nodeId
            )
            try await trace(runId: run.id, kind: .runFailed, message: "Run failed at \(nodeId)")
            throw RunEngineError.failed("Node \(nodeId) exhausted iterations without passing done-checks")
        }

        try await trace(
            runId: run.id,
            kind: .nodeSucceeded,
            message: "Node \(nodeId) completed",
            nodeId: nodeId
        )

        let contract = buildContract(
            nodeArtifacts: nodeArtifacts,
            checks: lastChecks,
            routerNext: routerNext,
            summaryFallback: "\(node.role) completed"
        )

        // Terminal node? no success/always outgoing edges and not router needing hop
        let successEdges = project.org.outgoingEdges(from: nodeId).filter { $0.on == .success || $0.on == .always }
        if successEdges.isEmpty {
            run.status = .succeeded
            run.activeNodeId = nil
            run.updatedAt = Date()
            try await store.saveRun(run)
            currentRun = run
            currentPhase = "completed"
            currentIteration = nil
            log("Run succeeded")
            await publishProgress()
            try await trace(runId: run.id, kind: .runSucceeded, message: "Run succeeded at terminal node \(nodeId)")
            return
        }

        // Pick edge
        let edge: OrgEdge
        let destination: String
        if let routerEdge = successEdges.first(where: { $0.type == .router }) {
            guard let next = routerNext ?? loadRouterNext(from: nodeArtifacts) else {
                throw RunEngineError.missingRouterNext
            }
            guard routerEdge.targets.contains(next.nodeId) else {
                throw RunEngineError.routerTargetNotAllowed(next.nodeId)
            }
            edge = routerEdge
            destination = next.nodeId
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Router chose \(destination): \(next.reason)",
                nodeId: nodeId,
                payloadJSON: encodeJSON(next)
            )
        } else if let fixed = successEdges.first(where: { $0.type == .fixed }), let to = fixed.to {
            edge = fixed
            destination = to
            try await trace(
                runId: run.id,
                kind: .routed,
                message: "Fixed edge to \(destination)",
                nodeId: nodeId
            )
        } else {
            throw RunEngineError.noOutgoingEdge(nodeId)
        }

        var outbound = contract
        if let next = routerNext {
            outbound.next = next
        }

        try await handoff(
            from: node,
            edge: edge,
            contract: outbound,
            forcedDestination: destination,
            run: &run,
            project: project
        )
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
            run.status = .awaitingApproval
            run.updatedAt = Date()
            try await store.saveRun(run)
            currentRun = run
            pendingApproval = PendingApproval(runId: run.id, inspection: inspection)
            pausedInbound = filtered.passed
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

        try await executeFrom(nodeId: destination, inbound: filtered.passed, run: &run, project: project)
    }

    // MARK: - Helpers

    private func buildContract(
        nodeArtifacts: URL,
        checks: [CheckResult],
        routerNext: RouterNext?,
        summaryFallback: String
    ) -> HandoffContract {
        let summaryURL = nodeArtifacts.appendingPathComponent("summary.txt")
        let summary: String
        if let text = try? String(contentsOf: summaryURL, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            summary = summaryFallback
            try? summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        }

        let artifactFiles = (try? fileManager.contentsOfDirectory(atPath: nodeArtifacts.path)) ?? []
        let artifacts = artifactFiles
            .filter { !$0.hasPrefix("packet-") && $0 != "summary.txt" }
            .map { nodeArtifacts.appendingPathComponent($0).path }

        return HandoffContract(
            summary: summary,
            artifacts: artifacts,
            checks: checks,
            next: routerNext,
            notes: nil
        )
    }

    private func loadRouterNext(from nodeArtifacts: URL) -> RouterNext? {
        let url = nodeArtifacts.appendingPathComponent("next.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RouterNext.self, from: data)
    }

    private func checkLabel(_ check: DoneCheck) -> String {
        switch check {
        case .artifact(let path): return "artifact:\(path)"
        case .shell(let command): return "shell:\(command)"
        case .routerNext: return "router_next"
        }
    }

    private func log(_ line: String) {
        liveLog.append(line)
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
