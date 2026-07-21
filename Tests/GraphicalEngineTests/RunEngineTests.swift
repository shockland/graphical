import XCTest
@testable import GraphicalDomain
@testable import GraphicalEngine
@testable import GraphicalCLI

final class RunEngineTests: XCTestCase {
    func testVerticalSliceWithApproval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        let project = try store.createProject(at: root, name: "Slice", seedTemplate: true)
        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace)

        let first = try await engine.start(project: project, goal: "Build a vertical slice")
        XCTAssertEqual(first.status, .awaitingApproval)
        let firstLog = await engine.liveLog
        XCTAssertTrue(
            firstLog.contains { $0.contains("[planner stdout] Fixture runner completed") },
            "Expected agent stdout in the live log, got: \(firstLog)"
        )

        let pending = await engine.pendingApproval
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.inspection.toNode, "implementer")
        XCTAssertFalse(pending!.inspection.passed.summary.isEmpty)

        let finished = try await engine.approve()
        let events = try await trace.events(runId: finished.id)
        XCTAssertEqual(
            finished.status,
            .succeeded,
            "Expected success, events: \(events.map(\.message))"
        )

        XCTAssertTrue(events.contains { $0.kind == .runStarted })
        XCTAssertTrue(events.contains { $0.kind == .awaitingApproval })
        XCTAssertTrue(events.contains { $0.kind == .approved })
        XCTAssertTrue(events.contains { $0.kind == .routed })
        XCTAssertTrue(events.contains { $0.kind == .runSucceeded })

        let plan = GraphicalPaths.nodeArtifacts(projectRoot: root, runId: finished.id, nodeId: "planner")
            .appendingPathComponent("plan.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.path))

        let json = try await trace.exportTraceJSON(runId: finished.id)
        XCTAssertFalse(json.isEmpty)
    }

    func testRouterRejectsUnknownTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-bad-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "Bad", seedTemplate: true)
        project.runners.runners["echo_fixture"] = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                OUT={{node_artifacts}}
                mkdir -p "$OUT"
                echo plan > "$OUT/plan.md"
                printf '%s\\n' '{"node_id":"ghost","reason":"bad"}' > "$OUT/next.json"
                """
            ],
            cwd: "{{project_root}}"
        )

        let engine = RunEngine(store: try TraceStore(inMemory: true))
        do {
            _ = try await engine.start(project: project, goal: "x")
            XCTFail("Expected router allowlist failure")
        } catch let error as RunEngineError {
            XCTAssertEqual(error, .routerTargetNotAllowed("ghost"))
        }
    }

    func testInvokeProgressPublishesSubstepsAndHeartbeat() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-heartbeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "Heartbeat", seedTemplate: true)
        project.org = OrgGraph(
            nodes: [
                OrgNode(
                    id: "worker",
                    role: "Worker",
                    runner: "slow_fixture",
                    done: .allOf([.artifact("done.txt")]),
                    maxIterations: 1
                )
            ],
            edges: [],
            entry: "worker"
        )
        project.runners.runners["slow_fixture"] = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                OUT={{node_artifacts}}
                mkdir -p "$OUT"
                sleep 0.45
                echo ok > "$OUT/done.txt"
                echo "Fixture runner completed"
                """
            ],
            cwd: "{{project_root}}"
        )

        let engine = RunEngine(
            store: try TraceStore(inMemory: true),
            progressHeartbeatNanoseconds: 100_000_000,
            progressHeartbeatLogEvery: 2
        )
        let phases = ProgressPhaseCollector()
        await engine.setProgressHandler { snapshot in
            await phases.append(snapshot.phase)
        }

        let run = try await engine.start(project: project, goal: "prove liveness")
        XCTAssertEqual(run.status, .succeeded)

        let log = await engine.liveLog
        XCTAssertTrue(log.contains { $0.contains("writing working packet") }, "log: \(log)")
        XCTAssertTrue(log.contains { $0.contains("launching slow_fixture") }, "log: \(log)")
        XCTAssertTrue(log.contains { $0.contains("waiting for agent output") }, "log: \(log)")
        XCTAssertTrue(log.contains { $0.contains("still working") }, "log: \(log)")
        XCTAssertTrue(log.contains { $0.contains("evaluating done-checks") }, "log: \(log)")

        let seenPhases = await phases.values
        XCTAssertTrue(
            seenPhases.contains { ($0 ?? "").contains("waiting for agent") },
            "Expected waiting phase with elapsed time, got: \(seenPhases)"
        )
        XCTAssertTrue(
            seenPhases.contains { ($0 ?? "").contains("evaluating checks") },
            "Expected evaluating-checks phase, got: \(seenPhases)"
        )
    }

    func testWorkingPacketMentionsRejectJsonOnlyWhenRejectEdgeExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-packet-reject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "PacketDocs", seedTemplate: true)
        let nodeA = OrgNode(id: "a", role: "A", runner: "echo_fixture", done: .allOf([.artifact("output.md")]))
        let nodeB = OrgNode(id: "b", role: "B", runner: "echo_fixture", done: .allOf([.artifact("output.md")]))
        let edgeAB = OrgEdge(from: "a", to: "b", type: .fixed, on: .success)
        let edgeBA = OrgEdge(from: "b", to: "a", type: .fixed, on: .reject)
        project.org = OrgGraph(nodes: [nodeA, nodeB], edges: [edgeAB, edgeBA], entry: "a")

        let run = RunRecord(projectRoot: root.path, goal: "packet docs")
        let packetB = WorkingPacketBuilder.build(
            project: project,
            run: run,
            node: nodeB,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: root
        )
        XCTAssertTrue(packetB.contains("reject.json"), "Expected node with an 'on: reject' edge to be told about reject.json")

        let packetA = WorkingPacketBuilder.build(
            project: project,
            run: run,
            node: nodeA,
            iteration: 1,
            inbound: nil,
            missingChecks: [],
            nodeArtifacts: root
        )
        XCTAssertFalse(packetA.contains("reject.json"), "Node without an 'on: reject' edge should not mention reject.json")
    }

    func testTemplateRenderer() {
        let context = RunnerContext(
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            promptFile: URL(fileURLWithPath: "/tmp/packet.md"),
            nodeArtifacts: URL(fileURLWithPath: "/tmp/out"),
            runArtifacts: URL(fileURLWithPath: "/tmp/run"),
            runId: "r1",
            nodeId: "planner",
            model: "opus"
        )
        let rendered = TemplateRenderer.render("{{project_root}}/{{node_id}}/{{model}}", context: context)
        XCTAssertEqual(rendered, "/tmp/proj/planner/opus")
    }

    func testShellEscapeSingleQuotedRoundTrips() {
        XCTAssertEqual(ShellEscape.singleQuoted("foo"), "'foo'")
        XCTAssertEqual(ShellEscape.singleQuoted("a'b"), "'a'\\''b'")
        XCTAssertEqual(ShellEscape.singleQuoted(""), "''")
        XCTAssertEqual(ShellEscape.singleQuoted("$(touch /tmp/pwned)"), "'$(touch /tmp/pwned)'")
    }

    func testTemplateRendererShellSingleQuotedEncoding() {
        let context = RunnerContext(
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            promptFile: URL(fileURLWithPath: "/tmp/packet.md"),
            nodeArtifacts: URL(fileURLWithPath: "/tmp/out"),
            runArtifacts: URL(fileURLWithPath: "/tmp/run"),
            runId: "r1",
            nodeId: "planner",
            model: "opus"
        )
        let rendered = TemplateRenderer.render(
            "echo {{model}}",
            context: context,
            encoding: .shellSingleQuoted
        )
        XCTAssertEqual(rendered, "echo 'opus'")
    }

    func testTemplateRendererEscapesInjectionAttemptsForBashRunners() {
        let context = RunnerContext(
            projectRoot: URL(fileURLWithPath: "/tmp/evil$(touch /tmp/pwned)"),
            promptFile: URL(fileURLWithPath: "/tmp/pack\"et.md"),
            nodeArtifacts: URL(fileURLWithPath: "/tmp/out"),
            runArtifacts: URL(fileURLWithPath: "/tmp/run"),
            runId: "r1",
            nodeId: "planner",
            model: "`whoami`"
        )
        let runner = RunnerTemplate(
            command: "/bin/bash",
            args: ["-lc", "cd {{project_root}} && cat {{prompt_file}} --model {{model}}"],
            cwd: "{{project_root}}"
        )
        let rendered = TemplateRenderer.render(runner: runner, context: context)
        // The rendered script text should carry the dangerous substrings only inside
        // single quotes, never as bare unquoted shell metacharacters.
        XCTAssertTrue(rendered.args[1].contains("'/tmp/evil$(touch /tmp/pwned)'"))
        XCTAssertTrue(rendered.args[1].contains("'/tmp/pack\"et.md'"))
        XCTAssertTrue(rendered.args[1].contains("'`whoami`'"))
        // cwd is consumed directly by Process, not re-parsed by a shell — must stay literal.
        XCTAssertEqual(rendered.cwd, "/tmp/evil$(touch /tmp/pwned)")
    }

    func testTemplateRendererDoesNotShellQuoteNonShellRunners() {
        let context = RunnerContext(
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            promptFile: URL(fileURLWithPath: "/tmp/packet.md"),
            nodeArtifacts: URL(fileURLWithPath: "/tmp/out"),
            runArtifacts: URL(fileURLWithPath: "/tmp/run"),
            runId: "r1",
            nodeId: "planner",
            model: "opus"
        )
        let runner = RunnerTemplate(command: "claude", args: ["-p", "{{prompt_file}}", "--model", "{{model}}"])
        let rendered = TemplateRenderer.render(runner: runner, context: context)
        XCTAssertEqual(rendered.args, ["-p", "/tmp/packet.md", "--model", "opus"])
    }

    func testEchoFixtureRunnerSurvivesProjectRootWithSpaceAndQuote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical shell \"test\" \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, name: "ShellSafe", seedTemplate: true)
        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace)
        let first = try await engine.start(project: project, goal: "shell-safe root")
        XCTAssertEqual(first.status, .awaitingApproval, "Expected planner to succeed even with a project root containing spaces/quotes")
    }

    func testCancelSetsStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, seedTemplate: true)
        let engine = RunEngine(store: try TraceStore(inMemory: true))
        let run = try await engine.start(project: project, goal: "c")
        XCTAssertEqual(run.status, .awaitingApproval)
        try await engine.cancel()
        let current = await engine.currentRun
        XCTAssertEqual(current?.status, .cancelled)
    }

    func testCancelAfterSucceededDoesNotOverwriteStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-cancel-after-success-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "Terminal", seedTemplate: true)
        project.org = OrgGraph(
            nodes: [
                OrgNode(
                    id: "worker",
                    role: "Worker",
                    runner: "echo_fixture",
                    done: .allOf([.artifact("plan.md")]),
                    maxIterations: 1
                )
            ],
            edges: [],
            entry: "worker"
        )
        project.runners.runners["echo_fixture"] = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                OUT={{node_artifacts}}
                mkdir -p "$OUT"
                echo ok > "$OUT/plan.md"
                echo "Fixture runner completed"
                """
            ],
            cwd: "{{project_root}}"
        )

        let store = try TraceStore(inMemory: true)
        let engine = RunEngine(store: store)
        let run = try await engine.start(project: project, goal: "finish then cancel")
        XCTAssertEqual(run.status, .succeeded)

        try await engine.cancel()
        let current = await engine.currentRun
        XCTAssertEqual(current?.status, .succeeded)

        let events = try await store.events(runId: run.id)
        XCTAssertTrue(events.contains { $0.kind == .runSucceeded })
        XCTAssertFalse(events.contains { $0.kind == .runCancelled })
    }

    func testCancelDuringInvokeStaysCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-cancel-invoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, seedTemplate: true)
        let blockingRunner = BlockingProcessRunner()
        let engine = RunEngine(store: try TraceStore(inMemory: true), processRunner: blockingRunner)

        let startTask = Task {
            try await engine.start(project: project, goal: "cancel mid-invoke")
        }

        try await blockingRunner.waitUntilStarted()
        try await engine.cancel()
        blockingRunner.release()

        do {
            _ = try await startTask.value
            XCTFail("Expected RunEngineError.cancelled")
        } catch RunEngineError.cancelled {
            // expected
        }

        let current = await engine.currentRun
        XCTAssertEqual(current?.status, .cancelled)
    }

    func testDoneCheckEvaluatorShellCheckUsesNonLoginShellAndMinimalEnv() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-shellcheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.shell("[ -z \"${GRAPHICAL_TEST_SECRET:-}\" ] && [ -n \"$PATH\" ]")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertTrue(passed, "Expected minimal-env shell check to pass, results: \(results)")
    }

    func testProcessRunnerInheritEnvironmentFalseStillSeesAllowlistAndOverrides() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            command: "/bin/bash",
            arguments: ["-c", "echo \"$FOO/$PATH\""],
            workingDirectory: nil,
            environment: ["FOO": "bar"],
            timeoutSeconds: 5,
            inheritEnvironment: false
        )
        XCTAssertTrue(result.succeeded)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(output.hasPrefix("bar/"), "Expected FOO override and PATH allowlist, got: \(output)")
        XCTAssertFalse(output.hasSuffix("/"), "Expected non-empty PATH, got: \(output)")
    }

    func testProcessRunnerCapturesTruncatedFlagWithBoundedSize() async throws {
        let runner = ProcessRunner()
        // Write well beyond the per-stream cap so truncation kicks in.
        let result = try await runner.run(
            command: "/bin/bash",
            arguments: ["-c", "yes x | head -c 2000000"],
            workingDirectory: nil,
            environment: [:],
            timeoutSeconds: 15,
            inheritEnvironment: true
        )
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, ProcessRunner.maxCaptureBytesPerStream)
    }

    func testProcessRunnerDeliversOutputBeforeProcessExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let signal = root.appendingPathComponent("output-received")

        let result = try await ProcessRunner().run(
            command: "/bin/bash",
            arguments: [
                "-c",
                #"printf first; while [ ! -e "$SIGNAL" ]; do sleep 0.02; done; printf second"#
            ],
            workingDirectory: nil,
            environment: ["SIGNAL": signal.path],
            timeoutSeconds: 3,
            inheritEnvironment: true,
            onOutput: { chunk in
                guard chunk.stream == .stdout, !chunk.data.isEmpty else { return }
                FileManager.default.createFile(atPath: signal.path, contents: Data())
            }
        )

        XCTAssertTrue(result.succeeded, "Process should only exit after its live output callback runs")
        XCTAssertEqual(result.stdout, "firstsecond")
    }

    func testDoneCheckEvaluatorRejectsArtifactPathEscape() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-escape-\(UUID().uuidString)", isDirectory: true)
        let nodeArtifacts = root.appendingPathComponent("artifacts/run1/node1", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeArtifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Plant the file the escaping check tries to read, just outside nodeArtifacts.
        let secret = nodeArtifacts.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try "leaked".write(to: secret, atomically: true, encoding: .utf8)

        let evaluator = DoneCheckEvaluator()
        let (passed, results) = await evaluator.evaluate(
            group: .allOf([.artifact("../secret.txt")]),
            nodeArtifacts: nodeArtifacts,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(passed)
        XCTAssertEqual(results.first?.detail, "Path escapes node artifacts")
    }

    func testRetryActiveNodePreservesInboundHandoff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-retry-inbound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "Retry", seedTemplate: true)
        // Node "a" is satisfied by the echo_fixture wildcard case (writes output.md).
        // Node "b" requires an artifact the runner never creates, so it always
        // exhausts its iteration budget and the run fails with "b" active.
        let nodeA = OrgNode(
            id: "a",
            role: "A",
            runner: "echo_fixture",
            done: .allOf([.artifact("output.md")]),
            maxIterations: 1
        )
        let nodeB = OrgNode(
            id: "b",
            role: "B",
            runner: "echo_fixture",
            done: .allOf([.artifact("never-created.md")]),
            maxIterations: 1
        )
        let edge = OrgEdge(from: "a", to: "b", type: .fixed, on: .success, pass: [.summary, .artifacts, .checks])
        project.org = OrgGraph(nodes: [nodeA, nodeB], edges: [edge], entry: "a")

        let engine = RunEngine(store: try TraceStore(inMemory: true))
        do {
            _ = try await engine.start(project: project, goal: "retry inbound")
            XCTFail("Expected node b to exhaust iterations and fail the run")
        } catch let error as RunEngineError {
            guard case .failed(let message) = error else {
                XCTFail("Expected .failed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("B"), "Expected role in exhaustion message, got: \(message)")
            XCTAssertTrue(
                message.contains("never-created.md"),
                "Expected failed check name in exhaustion message, got: \(message)"
            )
            XCTAssertNotNil(error.recoverySuggestion)
        }

        let failedRun = await engine.currentRun
        XCTAssertEqual(failedRun?.activeNodeId, "b")
        XCTAssertEqual(failedRun?.status, .failed)

        do {
            try await engine.retryActiveNode()
            XCTFail("Expected retry to fail again since the artifact is still missing")
        } catch RunEngineError.failed {
            // expected
        }

        guard let runId = failedRun?.id else {
            XCTFail("Missing run id")
            return
        }
        let packet = GraphicalPaths.nodeArtifacts(projectRoot: root, runId: runId, nodeId: "b")
            .appendingPathComponent("packet-1.md")
        let contents = try String(contentsOf: packet, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("## Inbound Handoff"),
            "Expected retry packet to include inbound handoff section, got:\n\(contents)"
        )
        XCTAssertTrue(
            contents.contains("A completed"),
            "Expected retry packet to carry forward node A's summary, got:\n\(contents)"
        )
    }

    func testDoneCheckEvaluatorShellDetailIsCappedAndOmitsStdoutOnSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-shelldetail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()

        let (passed, passResults) = await evaluator.evaluate(
            group: .allOf([.shell("echo this-should-not-appear-in-detail-on-success")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertTrue(passed)
        XCTAssertEqual(passResults.first?.detail, "exit 0")

        let longOutput = String(repeating: "x", count: 5000)
        let (failed, failResults) = await evaluator.evaluate(
            group: .allOf([.shell("echo '\(longOutput)' 1>&2; exit 1")]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(failed)
        let detail = failResults.first?.detail ?? ""
        XCTAssertLessThanOrEqual(detail.count, DoneCheckEvaluator.maxDetailLength)
        XCTAssertFalse(detail.contains(longOutput), "Detail must not carry the full stderr body")
    }

    func testDoneCheckEvaluatorFailsClosedOnEmptyGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-emptydone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let evaluator = DoneCheckEvaluator()
        let (allOfPassed, allOfResults) = await evaluator.evaluate(
            group: .allOf([]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(allOfPassed)
        XCTAssertFalse(allOfResults.isEmpty)

        let (anyOfPassed, anyOfResults) = await evaluator.evaluate(
            group: .anyOf([]),
            nodeArtifacts: root,
            projectRoot: root,
            routerNext: nil
        )
        XCTAssertFalse(anyOfPassed)
        XCTAssertFalse(anyOfResults.isEmpty)
    }

    func testRejectJsonRoutesViaRejectEdgeThenSucceedsOnSecondPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-reject-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "RejectEdge", seedTemplate: true)
        project.runners.runners["runner_a"] = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                set -euo pipefail
                OUT={{node_artifacts}}
                mkdir -p "$OUT"
                echo ok > "$OUT/output.md"
                """
            ],
            cwd: "{{project_root}}"
        )
        // First visit: signal reject via reject.json. Second visit (after routing
        // back from "a"): clear the marker/reject.json so "b" completes normally.
        project.runners.runners["runner_b"] = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                set -euo pipefail
                OUT={{node_artifacts}}
                mkdir -p "$OUT"
                if [ -f "$OUT/visited.marker" ]; then
                  rm -f "$OUT/reject.json"
                  echo second > "$OUT/output.md"
                else
                  touch "$OUT/visited.marker"
                  echo first > "$OUT/output.md"
                  printf '%s\\n' '{"reject":true,"reason":"needs rework"}' > "$OUT/reject.json"
                fi
                """
            ],
            cwd: "{{project_root}}"
        )

        let nodeA = OrgNode(id: "a", role: "A", runner: "runner_a", done: .allOf([.artifact("output.md")]), maxIterations: 1)
        let nodeB = OrgNode(id: "b", role: "B", runner: "runner_b", done: .allOf([.artifact("output.md")]), maxIterations: 1)
        let edgeAtoB = OrgEdge(from: "a", to: "b", type: .fixed, on: .success)
        let edgeBtoA = OrgEdge(from: "b", to: "a", type: .fixed, on: .reject)
        project.org = OrgGraph(nodes: [nodeA, nodeB], edges: [edgeAtoB, edgeBtoA], entry: "a")

        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace)
        let finished = try await engine.start(project: project, goal: "reject loop")

        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertNil(finished.activeNodeId)

        let events = try await trace.events(runId: finished.id)
        XCTAssertTrue(events.contains { $0.kind == .rejected && $0.nodeId == "b" })
        XCTAssertTrue(events.contains { $0.kind == .routed && $0.message.contains("Reject edge to a") })
        XCTAssertEqual(events.filter { $0.kind == .nodeSucceeded && $0.nodeId == "b" }.count, 2)
    }

    func testRejectJsonWithoutRejectEdgeFailsRunWithClearError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-reject-no-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "RejectNoEdge", seedTemplate: true)
        project.runners.runners["runner_solo"] = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                """
                set -euo pipefail
                OUT={{node_artifacts}}
                mkdir -p "$OUT"
                echo ok > "$OUT/output.md"
                printf '%s\\n' '{"reject":true,"reason":"always rejects"}' > "$OUT/reject.json"
                """
            ],
            cwd: "{{project_root}}"
        )
        let solo = OrgNode(id: "solo", role: "Solo", runner: "runner_solo", done: .allOf([.artifact("output.md")]), maxIterations: 1)
        project.org = OrgGraph(nodes: [solo], edges: [], entry: "solo")

        let engine = RunEngine(store: try TraceStore(inMemory: true))
        do {
            _ = try await engine.start(project: project, goal: "reject with no edge")
            XCTFail("Expected reject.json without an 'on: reject' edge to fail the run")
        } catch let error as RunEngineError {
            guard case .failed(let message) = error else {
                XCTFail("Expected .failed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("reject"), "Expected a reject-related error message, got: \(message)")
            XCTAssertTrue(message.contains("Solo"), "Expected role in reject message, got: \(message)")
            let suggestion = error.recoverySuggestion ?? ""
            XCTAssertTrue(suggestion.contains("on: reject"), "Expected reject-edge recovery, got: \(suggestion)")
        }

        let current = await engine.currentRun
        XCTAssertEqual(current?.status, .failed)
    }

    func testHappyPathWithoutRejectJsonStillSucceeds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-no-reject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, name: "NoReject", seedTemplate: true)
        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace)
        let first = try await engine.start(project: project, goal: "no reject happy path")
        XCTAssertEqual(first.status, .awaitingApproval)
        let finished = try await engine.approve()
        XCTAssertEqual(finished.status, .succeeded)
    }

    func testCliFinishedPayloadOmitsStdoutByDefault() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-trace-redact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, name: "TraceRedact", seedTemplate: true)
        XCTAssertFalse(project.config.traceCLIOutput, "Expected traceCLIOutput to default to false")

        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace)
        let first = try await engine.start(project: project, goal: "trace redaction")
        XCTAssertEqual(first.status, .awaitingApproval)

        let events = try await trace.events(runId: first.id)
        let cliEvents = events.filter { $0.kind == .cliFinished }
        XCTAssertFalse(cliEvents.isEmpty)
        for event in cliEvents {
            guard let json = event.payloadJSON,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("Expected decodable payloadJSON")
                continue
            }
            XCTAssertNil(object["stdout"], "Default trace payload must not include raw stdout")
            XCTAssertNil(object["stderr"], "Default trace payload must not include raw stderr")
            XCTAssertNotNil(object["stdoutBytes"])
            XCTAssertNotNil(object["stderrBytes"])
            XCTAssertNotNil(object["exitCode"])
        }
    }

    func testCliFinishedPayloadIncludesPreviewWhenOptedIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-trace-optin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "TraceOptIn", seedTemplate: true)
        project.config.traceCLIOutput = true

        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace)
        let first = try await engine.start(project: project, goal: "trace opt in")
        XCTAssertEqual(first.status, .awaitingApproval)

        let events = try await trace.events(runId: first.id)
        let cliEvent = events.first { $0.kind == .cliFinished }
        let json = try XCTUnwrap(cliEvent?.payloadJSON)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        )
        XCTAssertNotNil(object["stdoutPreview"], "Expected stdout preview when traceCLIOutput is opted in")
    }

    func testTraceStoreExportRedactsLegacyStdoutStderrFields() async throws {
        let trace = try TraceStore(inMemory: true)
        let run = RunRecord(projectRoot: "/tmp/x", goal: "g")
        try await trace.saveRun(run)
        try await trace.append(
            TraceEvent(
                runId: run.id,
                kind: .cliFinished,
                message: "legacy row",
                payloadJSON: #"{"exitCode":0,"stdout":"super secret token","stderr":""}"#
            )
        )

        let data = try await trace.exportTraceJSON(runId: run.id)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("super secret token"), "Legacy stdout body must be redacted on export")
    }

    func testRejectApprovalFailsRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-reject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try YAMLStore().createProject(at: root, seedTemplate: true)
        let engine = RunEngine(store: try TraceStore(inMemory: true))
        _ = try await engine.start(project: project, goal: "reject me")
        let run = try await engine.rejectApproval(notes: "nope")
        XCTAssertEqual(run.status, .failed)
    }

    func testLiveLogStreamsChunksBeforeProcessExitAndKeepsTraceRedacted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-stream-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "StreamLive", seedTemplate: true)
        project.org = OrgGraph(
            nodes: [
                OrgNode(
                    id: "worker",
                    role: "Worker",
                    runner: "stream_fixture",
                    done: .allOf([.shell("true")]),
                    maxIterations: 1
                )
            ],
            edges: [],
            entry: "worker"
        )
        project.runners.runners["stream_fixture"] = RunnerTemplate(
            command: "/usr/bin/true",
            args: [],
            cwd: "{{project_root}}"
        )
        XCTAssertFalse(project.config.traceCLIOutput)

        let streaming = StreamingChunkProcessRunner(
            chunks: [
                ProcessOutputChunk(stream: .stdout, data: Data("hel".utf8)),
                ProcessOutputChunk(stream: .stdout, data: Data("lo-stream\n".utf8)),
                ProcessOutputChunk(stream: .stderr, data: Data("warn-line\n".utf8))
            ],
            stdout: "hello-stream\n",
            stderr: "warn-line\n"
        )

        let trace = try TraceStore(inMemory: true)
        let engine = RunEngine(store: trace, processRunner: streaming)
        let midInvoke = MidInvokeLogProbe()
        streaming.midInvokeProbe = {
            let log = await engine.liveLog
            let finished = streaming.isFinished
            await midInvoke.record(log: log, processFinished: finished)
        }

        let seenStreamingProgress = ProgressPhaseCollector()
        await engine.setProgressHandler { snapshot in
            if snapshot.liveLog.contains(where: { $0.contains("hello-stream") }) {
                await seenStreamingProgress.append("saw-hello")
            }
        }

        let run = try await engine.start(project: project, goal: "stream live log")
        XCTAssertEqual(run.status, .succeeded)

        let probe = await midInvoke.snapshot()
        XCTAssertFalse(probe.processFinished, "Probe must run before process finish")
        XCTAssertTrue(
            probe.log.contains { $0.contains("[worker stdout] hello-stream") },
            "Expected incomplete chunks reassembled in liveLog mid-invoke, got: \(probe.log)"
        )
        XCTAssertTrue(
            probe.log.contains { $0.contains("[worker stderr] warn-line") },
            "Expected stderr in liveLog mid-invoke, got: \(probe.log)"
        )

        let phases = await seenStreamingProgress.values
        XCTAssertTrue(phases.contains("saw-hello"), "Expected progress publish before exit")

        let log = await engine.liveLog
        XCTAssertTrue(log.contains { $0.contains("[worker stdout] hello-stream") }, "log: \(log)")

        let events = try await trace.events(runId: run.id)
        let cliEvents = events.filter { $0.kind == .cliFinished }
        XCTAssertFalse(cliEvents.isEmpty)
        for event in cliEvents {
            guard let json = event.payloadJSON,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("Expected decodable payloadJSON")
                continue
            }
            XCTAssertNil(object["stdout"])
            XCTAssertNil(object["stderr"])
            XCTAssertNil(object["stdoutPreview"])
            XCTAssertNotNil(object["stdoutBytes"])
        }
    }

    func testLiveLogFlushesIncompleteFinalLineAndFormatsStreamJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-stream-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try YAMLStore().createProject(at: root, name: "StreamJSON", seedTemplate: true)
        project.org = OrgGraph(
            nodes: [
                OrgNode(
                    id: "worker",
                    role: "Worker",
                    runner: "stream_fixture",
                    done: .allOf([.shell("true")]),
                    maxIterations: 1
                )
            ],
            edges: [],
            entry: "worker"
        )
        project.runners.runners["stream_fixture"] = RunnerTemplate(
            command: "/usr/bin/true",
            args: [],
            cwd: "{{project_root}}"
        )

        let delta = #"{"type":"assistant","timestamp_ms":1,"message":{"role":"assistant","content":[{"type":"text","text":"partial-delta"}]}}"#
        let tool = #"{"type":"tool_call","subtype":"started","tool_call":{"writeToolCall":{"args":{"path":"out.md"}}}}"#
        let streaming = StreamingChunkProcessRunner(
            chunks: [
                ProcessOutputChunk(stream: .stdout, data: Data("\(delta)\n\(tool)\nno-newline-yet".utf8))
            ],
            stdout: "\(delta)\n\(tool)\nno-newline-yet",
            stderr: ""
        )

        let engine = RunEngine(store: try TraceStore(inMemory: true), processRunner: streaming)
        let run = try await engine.start(project: project, goal: "stream json")
        XCTAssertEqual(run.status, .succeeded)

        let log = await engine.liveLog
        XCTAssertTrue(log.contains { $0.contains("[worker stdout] partial-delta") }, "log: \(log)")
        XCTAssertTrue(log.contains { $0.contains("[worker stdout] write out.md") }, "log: \(log)")
        XCTAssertTrue(log.contains { $0.contains("[worker stdout] no-newline-yet") }, "log: \(log)")
        XCTAssertFalse(log.contains { $0.contains("\"type\":\"assistant\"") }, "Raw JSON should be formatted away")
    }

    /// Live Cursor play against this repo's `.graphical/` config. Opt-in:
    /// `GRAPHICAL_LIVE=1 swift test --filter testLiveCursorPlayOnProject`
    func testLiveCursorPlayOnProject() async throws {
        guard ProcessInfo.processInfo.environment["GRAPHICAL_LIVE"] == "1" else {
            throw XCTSkip("Set GRAPHICAL_LIVE=1 to run the live Cursor play")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try YAMLStore().load(from: root)
        XCTAssertEqual(project.org.node(id: "planner")?.runner, "cursor_agent")
        XCTAssertNotNil(project.runners.agent(named: "cursor_agent"))

        let store = try TraceStore(inMemory: true)
        let engine = RunEngine(store: store)
        let run = try await engine.start(project: project, goal: project.config.goal)
        let log = await engine.liveLog
        let events = try await store.events(runId: run.id)
        XCTAssertEqual(
            run.status,
            .succeeded,
            """
            Live Cursor play failed with status \(run.status). active=\(run.activeNodeId ?? "nil")
            log:
            \(log.joined(separator: "\n"))
            events:
            \(events.map { "\($0.kind.rawValue): \($0.message)" }.joined(separator: "\n"))
            """
        )
    }
}

/// Collects phase strings from `RunProgressSnapshot` for liveness assertions.
private actor ProgressPhaseCollector {
    private(set) var values: [String?] = []

    func append(_ phase: String?) {
        values.append(phase)
    }
}

private actor MidInvokeLogProbe {
    private(set) var log: [String] = []
    private(set) var processFinished = true

    func record(log: [String], processFinished: Bool) {
        self.log = log
        self.processFinished = processFinished
    }

    func snapshot() -> (log: [String], processFinished: Bool) {
        (log, processFinished)
    }
}

/// Yields `ProcessOutputChunk`s mid-invoke for live-log streaming tests.
private final class StreamingChunkProcessRunner: ProcessExecuting, @unchecked Sendable {
    private let chunks: [ProcessOutputChunk]
    private let stdout: String
    private let stderr: String
    private let lock = NSLock()
    private var finished = false
    var midInvokeProbe: (@Sendable () async -> Void)?

    init(chunks: [ProcessOutputChunk], stdout: String, stderr: String) {
        self.chunks = chunks
        self.stdout = stdout
        self.stderr = stderr
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool
    ) async throws -> ProcessResult {
        // Done-check path (`shell: true`).
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool,
        onOutput: @escaping @Sendable (ProcessOutputChunk) async -> Void
    ) async throws -> ProcessResult {
        for chunk in chunks {
            await onOutput(chunk)
            await Task.yield()
        }
        if let midInvokeProbe {
            await midInvokeProbe()
        }
        lock.lock()
        finished = true
        lock.unlock()
        return ProcessResult(exitCode: 0, stdout: stdout, stderr: stderr)
    }

    func cancelCurrent() {}
}

/// Blocks in `run` until `release()` or `cancelCurrent()` so tests can cancel mid-invoke.
private final class BlockingProcessRunner: ProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Int,
        inheritEnvironment: Bool
    ) async throws -> ProcessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started = true
            let waiters = startedWaiters
            startedWaiters = []
            lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
            continuation.resume()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            finishWaiters.append(continuation)
            lock.unlock()
        }

        return ProcessResult(exitCode: 1, stdout: "", stderr: "", cancelled: true)
    }

    func cancelCurrent() {
        release()
    }

    func waitUntilStarted() async throws {
        let alreadyStarted: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return started
        }()
        if alreadyStarted { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if self.started {
                        self.lock.unlock()
                        continuation.resume()
                    } else {
                        self.startedWaiters.append(continuation)
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw BlockingProcessRunnerError.startTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func release() {
        lock.lock()
        let waiters = finishWaiters
        finishWaiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum BlockingProcessRunnerError: Error {
    case startTimeout
}
