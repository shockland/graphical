import Foundation
import AppKit
import UniformTypeIdentifiers
import GraphicalDomain
import GraphicalEngine
import GraphicalCLI

/// Work-graph / Run lifecycle adapter over `RunEngine` (single-flight session).
@MainActor
final class RunSession {
    private(set) var isRunning = false
    private(set) var run: RunRecord?
    private(set) var events: [TraceEvent] = []
    private(set) var liveLog: [String] = []
    private(set) var runPhase: String?
    private(set) var runIteration: Int?
    private(set) var pendingApproval: PendingApproval?
    private(set) var lastInspection: HandoffInspection?
    private(set) var recentRuns: [RunRecord] = []
    private(set) var exportPath: String?

    private(set) var engine: RunEngine?
    /// Incremented when a new run session starts so stale async work cannot clear UI state.
    private var runSession = 0
    /// Non-nil for the lifetime of the owning start/approve/retry Task.
    private var runTask: Task<Void, Never>?
    /// Incremented on every `loadRun` so a stale event fetch cannot clobber a newer selection.
    private var loadGeneration = 0

    var hasActiveRunTask: Bool { runTask != nil }

    func clearUIState() {
        runSession += 1
        runTask = nil
        isRunning = false
        runPhase = nil
        runIteration = nil
        run = nil
        events = []
        liveLog = []
        pendingApproval = nil
        lastInspection = nil
        exportPath = nil
        engine = nil
    }

    func bumpSessionForClose() {
        runSession += 1
        runTask = nil
        isRunning = false
        runPhase = nil
        runIteration = nil
        engine = nil
    }

    func isCurrentRunSession(_ session: Int) -> Bool {
        session == runSession
    }

    func refreshRecentRuns(traceStore: TraceStore?) {
        Task {
            recentRuns = (try? await traceStore?.recentRuns()) ?? []
        }
    }

    func runningStatusMessage(from snapshot: RunProgressSnapshot, org: OrgGraph?) -> String {
        progressCopy(from: snapshot, org: org, isRunning: true).statusBar
    }

    /// Shared progress lines for the status bar and Run console.
    func progressCopy(
        from snapshot: RunProgressSnapshot? = nil,
        org: OrgGraph?,
        isRunning: Bool? = nil
    ) -> RunProgressCopy {
        let run = snapshot?.run ?? self.run
        let phase = snapshot?.phase ?? runPhase
        let iteration = snapshot?.iteration ?? runIteration
        let pending = snapshot?.pendingApproval ?? pendingApproval
        let inspection = pending?.inspection ?? snapshot?.lastInspection ?? lastInspection
        let knownNext: String?
        if let pending {
            knownNext = pending.inspection.toNode
        } else if let inspection, let active = run?.activeNodeId, inspection.fromNode == active {
            knownNext = inspection.toNode
        } else if let phase, phase.hasPrefix("handoff to ") {
            knownNext = String(phase.dropFirst("handoff to ".count))
        } else {
            knownNext = nil
        }
        return RunProgressCopy.make(
            status: run?.status,
            activeNodeId: run?.activeNodeId,
            phase: phase,
            iteration: iteration,
            org: org,
            knownNextNodeId: knownNext,
            runId: run?.id,
            isRunning: isRunning ?? self.isRunning
        )
    }

    func failedRunFallbackMessage(for run: RunRecord, org: OrgGraph?) -> String {
        let role: String?
        if let nodeId = run.activeNodeId {
            role = org?.node(id: nodeId)?.role ?? nodeId
        } else {
            role = nil
        }
        let diagnosis: String
        if let role, !role.isEmpty {
            diagnosis = "Run failed at \(role)."
        } else {
            diagnosis = "Run failed."
        }
        return "\(diagnosis) Open History for this run to inspect the failing step, then Retry or fix the workflow."
    }

    func applyProgressSnapshot(
        _ snapshot: RunProgressSnapshot,
        whileRunning: Bool,
        org: OrgGraph?
    ) -> String? {
        if let snapshotRun = snapshot.run {
            run = snapshotRun
        }
        liveLog = snapshot.liveLog
        pendingApproval = snapshot.pendingApproval
        lastInspection = snapshot.lastInspection
        runPhase = snapshot.phase
        runIteration = snapshot.iteration
        guard whileRunning else { return nil }
        return runningStatusMessage(from: snapshot, org: org)
    }

    func attachProgressHandler(
        to engine: RunEngine,
        session: Int,
        onProgress: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async {
        await engine.setProgressHandler { @MainActor [weak self] snapshot in
            guard let self, self.isCurrentRunSession(session), self.engine === engine else { return }
            onProgress(snapshot)
        }
    }

    func refreshFromEngine(_ engine: RunEngine, run: RunRecord?, traceStore: TraceStore?) async {
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

    func beginOwnedTask(
        engine: RunEngine,
        body: @escaping @MainActor (_ session: Int, _ engine: RunEngine) async -> Void
    ) {
        runSession += 1
        let session = runSession
        isRunning = true
        self.engine = engine
        runTask = Task {
            defer { if self.isCurrentRunSession(session) { self.runTask = nil } }
            await body(session, engine)
            guard self.isCurrentRunSession(session), self.engine === engine else { return }
            await engine.setProgressHandler(nil)
            self.isRunning = false
            self.runPhase = nil
            self.runIteration = nil
        }
    }

    /// Starts a run; caller supplies project/goal and progress/status hooks.
    func start(
        project: GraphicalProject,
        goal: String,
        traceStore: TraceStore,
        onProgress: @escaping @MainActor (RunProgressSnapshot) -> Void,
        onFinished: @escaping @MainActor (_ statusMessage: String?, _ errorMessage: String?) -> Void
    ) {
        let engine = RunEngine(store: traceStore)
        beginOwnedTask(engine: engine) { [weak self] session, engine in
            guard let self else { return }
            await self.attachProgressHandler(to: engine, session: session, onProgress: onProgress)
            var status: String?
            var errorMessage: String?
            do {
                let run = try await engine.start(project: project, goal: goal)
                guard self.isCurrentRunSession(session), self.engine === engine else { return }
                await self.refreshFromEngine(engine, run: run, traceStore: traceStore)
                if run.status == .awaitingApproval {
                    status = self.progressCopy(org: project.org, isRunning: false).statusBar
                } else if run.status == .succeeded {
                    status = "Done — all steps finished"
                } else if run.status == .failed {
                    status = "Run failed"
                    errorMessage = self.failedRunFallbackMessage(for: run, org: project.org)
                }
            } catch {
                guard self.isCurrentRunSession(session), self.engine === engine else { return }
                errorMessage = UserErrorFormatting.message(for: error)
                await self.refreshFromEngine(engine, run: await engine.currentRun, traceStore: traceStore)
            }
            guard self.isCurrentRunSession(session), self.engine === engine else { return }
            self.recentRuns = (try? await traceStore.recentRuns()) ?? self.recentRuns
            // Clear running state before onFinished notifies the UI. Otherwise the
            // Run console paints "Working · finishing" (isRunning + phase completed)
            // and never refreshes after beginOwnedTask later clears isRunning.
            await engine.setProgressHandler(nil)
            self.isRunning = false
            self.runPhase = nil
            self.runIteration = nil
            onFinished(status, errorMessage)
        }
    }

    func approve(
        projectOrg: OrgGraph?,
        traceStore: TraceStore?,
        onProgress: @escaping @MainActor (RunProgressSnapshot) -> Void,
        onFinished: @escaping @MainActor (_ statusMessage: String?, _ errorMessage: String?) -> Void
    ) {
        guard let engine else { return }
        guard pendingApproval != nil else { return }
        let session = runSession
        isRunning = true
        runTask = Task {
            defer { if self.isCurrentRunSession(session) { self.runTask = nil } }
            await self.attachProgressHandler(to: engine, session: session, onProgress: onProgress)
            var status: String?
            var errorMessage: String?
            do {
                let run = try await engine.approve()
                guard self.isCurrentRunSession(session), self.engine === engine else { return }
                await self.refreshFromEngine(engine, run: run, traceStore: traceStore)
                if run.status == .succeeded {
                    status = "Done — all steps finished"
                } else if run.status == .failed {
                    status = "Run failed"
                    errorMessage = self.failedRunFallbackMessage(for: run, org: projectOrg)
                } else {
                    status = "Approved; continuing"
                }
            } catch {
                guard self.isCurrentRunSession(session), self.engine === engine else { return }
                errorMessage = UserErrorFormatting.message(for: error)
            }
            guard self.isCurrentRunSession(session), self.engine === engine else { return }
            await engine.setProgressHandler(nil)
            self.isRunning = false
            self.runPhase = nil
            self.runIteration = nil
            if let traceStore {
                self.recentRuns = (try? await traceStore.recentRuns()) ?? self.recentRuns
            }
            onFinished(status, errorMessage)
        }
    }

    func rejectApproval(traceStore: TraceStore?) async -> (status: String?, error: String?) {
        guard let engine else { return (nil, nil) }
        guard pendingApproval != nil else { return (nil, nil) }
        do {
            let run = try await engine.rejectApproval(notes: "Rejected by user")
            await refreshFromEngine(engine, run: run, traceStore: traceStore)
            if let traceStore {
                recentRuns = (try? await traceStore.recentRuns()) ?? recentRuns
            }
            return ("Approval rejected", nil)
        } catch {
            return (nil, UserErrorFormatting.message(for: error))
        }
    }

    func cancel(traceStore: TraceStore?) {
        guard let engine else { return }
        let session = runSession
        Task {
            try? await engine.cancel()
            guard isCurrentRunSession(session), self.engine === engine else { return }
            await refreshFromEngine(engine, run: await engine.currentRun, traceStore: traceStore)
        }
    }

    func retry(
        projectOrg: OrgGraph?,
        traceStore: TraceStore?,
        onProgress: @escaping @MainActor (RunProgressSnapshot) -> Void,
        onFinished: @escaping @MainActor (_ statusMessage: String?, _ errorMessage: String?) -> Void
    ) {
        guard let engine else { return }
        guard run?.status == .failed || run?.status == .cancelled else {
            onFinished("Can only retry a failed or cancelled run", nil)
            return
        }
        let session = runSession
        isRunning = true
        runTask = Task {
            defer { if self.isCurrentRunSession(session) { self.runTask = nil } }
            await self.attachProgressHandler(to: engine, session: session, onProgress: onProgress)
            var status: String?
            var errorMessage: String?
            do {
                try await engine.retryActiveNode()
                guard self.isCurrentRunSession(session), self.engine === engine else { return }
                await self.refreshFromEngine(engine, run: await engine.currentRun, traceStore: traceStore)
                if let run = self.run {
                    if run.status == .failed {
                        status = "Run failed"
                        errorMessage = self.failedRunFallbackMessage(for: run, org: projectOrg)
                    } else if run.status == .succeeded {
                        status = "Done — all steps finished"
                    } else if run.status == .awaitingApproval {
                        status = self.progressCopy(org: projectOrg, isRunning: false).statusBar
                    }
                }
            } catch {
                guard self.isCurrentRunSession(session), self.engine === engine else { return }
                errorMessage = UserErrorFormatting.message(for: error)
            }
            guard self.isCurrentRunSession(session), self.engine === engine else { return }
            await engine.setProgressHandler(nil)
            self.isRunning = false
            self.runPhase = nil
            self.runIteration = nil
            if let traceStore {
                self.recentRuns = (try? await traceStore.recentRuns()) ?? self.recentRuns
            }
            onFinished(status, errorMessage)
        }
    }

    func loadRun(_ run: RunRecord, traceStore: TraceStore?, onDone: @escaping @MainActor (String?) -> Void) {
        self.run = run
        loadGeneration += 1
        let generation = loadGeneration
        let id = run.id
        Task {
            do {
                let fetched = try await traceStore?.events(runId: id) ?? []
                guard generation == self.loadGeneration, self.run?.id == id else { return }
                events = fetched
                onDone(nil)
            } catch {
                guard generation == self.loadGeneration, self.run?.id == id else { return }
                onDone(error.localizedDescription)
            }
        }
    }

    func exportTrace(traceStore: TraceStore?) async -> (path: String?, error: String?) {
        guard let run, let traceStore else { return (nil, nil) }
        do {
            let data = try await traceStore.exportTraceJSON(runId: run.id)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "trace-\(run.id).json"
            panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                exportPath = url.path
                return (
                    url.path,
                    nil
                )
            }
            return (nil, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
