import Foundation

// MARK: - Project

public struct ProjectConfig: Codable, Equatable, Sendable {
    public var name: String
    public var goal: String
    public var goalFile: String?
    public var defaultMaxIterations: Int
    public var defaultTimeoutSeconds: Int
    /// When `false` (default), `.cliFinished` trace events omit raw stdout/stderr text —
    /// only sizes/exit status are persisted to the durable SQLite trace store, since CLI
    /// output routinely echoes secrets (tokens, `.env` contents). Opt in per-project to
    /// aid debugging; see plans/011-trace-output-redaction.md.
    public var traceCLIOutput: Bool
    /// Lane count `X` for `SeedTemplate.agenticMesh(width:)`. Runtime does not
    /// re-expand the org; changing width requires re-seeding. Default 3; bounds
    /// enforced by `OrgValidator` when the mesh seed is validated.
    public var meshWidth: Int
    /// When `true` (default), fan-out targets run as a concurrent cohort (one
    /// process per lane). When `false`, lane heads drain sequentially.
    public var parallelFanOut: Bool

    public init(
        name: String,
        goal: String = "",
        goalFile: String? = "GOAL.md",
        defaultMaxIterations: Int = 5,
        defaultTimeoutSeconds: Int = 600,
        traceCLIOutput: Bool = false,
        meshWidth: Int = 3,
        parallelFanOut: Bool = true
    ) {
        self.name = name
        self.goal = goal
        self.goalFile = goalFile
        self.defaultMaxIterations = defaultMaxIterations
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.traceCLIOutput = traceCLIOutput
        self.meshWidth = meshWidth
        self.parallelFanOut = parallelFanOut
    }

    // No CodingKeys remapping: on-disk `project.yaml` uses these camelCase property
    // names verbatim (see `goalFile`, `defaultMaxIterations`). Custom `init(from:)`
    // only exists to default newer fields for pre-existing project files.
    private enum CodingKeys: String, CodingKey {
        case name, goal, goalFile, defaultMaxIterations, defaultTimeoutSeconds, traceCLIOutput, meshWidth
        case parallelFanOut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        goalFile = try container.decodeIfPresent(String.self, forKey: .goalFile)
        defaultMaxIterations = try container.decodeIfPresent(Int.self, forKey: .defaultMaxIterations) ?? 5
        defaultTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .defaultTimeoutSeconds) ?? 600
        traceCLIOutput = try container.decodeIfPresent(Bool.self, forKey: .traceCLIOutput) ?? false
        meshWidth = try container.decodeIfPresent(Int.self, forKey: .meshWidth) ?? 3
        parallelFanOut = try container.decodeIfPresent(Bool.self, forKey: .parallelFanOut) ?? true
    }
}

// MARK: - Done checks

public enum DoneCheck: Codable, Equatable, Sendable {
    case artifact(String)
    case shell(String)
    case routerNext

    private enum CodingKeys: String, CodingKey {
        case artifact
        case shell
        case routerNext = "router_next"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .artifact) {
            self = .artifact(path)
            return
        }
        if let command = try container.decodeIfPresent(String.self, forKey: .shell) {
            self = .shell(command)
            return
        }
        if let router = try container.decodeIfPresent(Bool.self, forKey: .routerNext), router {
            self = .routerNext
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown done check")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .artifact(let path):
            try container.encode(path, forKey: .artifact)
        case .shell(let command):
            try container.encode(command, forKey: .shell)
        case .routerNext:
            try container.encode(true, forKey: .routerNext)
        }
    }

    /// Stable label shared by retry hints, evaluator results, and Still Missing lists.
    public var displayName: String {
        switch self {
        case .artifact(let path): return "artifact:\(path)"
        case .shell(let command): return "shell:\(command)"
        case .routerNext: return "router_next"
        }
    }
}

public enum DoneCheckGroup: Codable, Equatable, Sendable {
    case allOf([DoneCheck])
    case anyOf([DoneCheck])

    private enum CodingKeys: String, CodingKey {
        case allOf = "all_of"
        case anyOf = "any_of"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let checks = try container.decodeIfPresent([DoneCheck].self, forKey: .allOf) {
            self = .allOf(checks)
            return
        }
        if let checks = try container.decodeIfPresent([DoneCheck].self, forKey: .anyOf) {
            self = .anyOf(checks)
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Expected all_of or any_of")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allOf(let checks):
            try container.encode(checks, forKey: .allOf)
        case .anyOf(let checks):
            try container.encode(checks, forKey: .anyOf)
        }
    }

    public var checks: [DoneCheck] {
        switch self {
        case .allOf(let checks), .anyOf(let checks):
            return checks
        }
    }
}

// MARK: - Nodes

public struct OrgNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var runner: String
    public var model: String?
    public var instructions: String
    public var done: DoneCheckGroup
    public var maxIterations: Int
    public var timeoutSeconds: Int?

    public init(
        id: String,
        role: String,
        runner: String,
        model: String? = nil,
        instructions: String = "",
        done: DoneCheckGroup = .allOf([]),
        maxIterations: Int = 5,
        timeoutSeconds: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.runner = runner
        self.model = model
        self.instructions = instructions
        self.done = done
        self.maxIterations = maxIterations
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, runner, model, instructions, done
        case maxIterations = "max_iterations"
        case timeoutSeconds = "timeout_seconds"
    }
}

// MARK: - Edges / handoffs

public enum EdgeCondition: String, Codable, Equatable, Sendable {
    case always
    case success
    case fail
    case reject
}

public enum EdgeType: String, Codable, Equatable, Sendable {
    case fixed
    case router
    /// Activate all `targets` after the source succeeds (AND), unlike `.router` (XOR).
    case fanOut = "fan_out"
    /// Barrier edge: destination runs only after all inbound `.join` predecessors succeed.
    case join
}

public enum HandoffField: String, Codable, Equatable, CaseIterable, Sendable {
    case summary
    case artifacts
    case checks
    case next
    case notes
}

public struct OrgEdge: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var from: String
    public var to: String?
    public var type: EdgeType
    public var targets: [String]
    public var on: EdgeCondition
    public var pass: [HandoffField]
    public var requiresApproval: Bool

    public init(
        id: String? = nil,
        from: String,
        to: String? = nil,
        type: EdgeType = .fixed,
        targets: [String] = [],
        on: EdgeCondition = .success,
        pass: [HandoffField] = [.summary, .artifacts, .checks],
        requiresApproval: Bool = false
    ) {
        self.id = id ?? "\(from)->\(to ?? targets.joined(separator: ","))"
        self.from = from
        self.to = to
        self.type = type
        self.targets = targets
        self.on = on
        self.pass = pass
        self.requiresApproval = requiresApproval
    }

    private enum CodingKeys: String, CodingKey {
        case id, from, to, type, targets, on, pass
        case requiresApproval = "requires_approval"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        type = try container.decodeIfPresent(EdgeType.self, forKey: .type) ?? (to == nil ? .router : .fixed)
        targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        on = try container.decodeIfPresent(EdgeCondition.self, forKey: .on) ?? .success
        pass = try container.decodeIfPresent([HandoffField].self, forKey: .pass) ?? [.summary, .artifacts, .checks]
        requiresApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresApproval) ?? false
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "\(from)->\(to ?? targets.joined(separator: ","))"
    }
}

public struct OrgGraph: Codable, Equatable, Sendable {
    public var nodes: [OrgNode]
    public var edges: [OrgEdge]
    public var entry: String?

    public init(nodes: [OrgNode] = [], edges: [OrgEdge] = [], entry: String? = nil) {
        self.nodes = nodes
        self.edges = edges
        self.entry = entry
    }

    public func node(id: String) -> OrgNode? {
        nodes.first { $0.id == id }
    }

    public func outgoingEdges(from nodeId: String) -> [OrgEdge] {
        edges.filter { $0.from == nodeId }
    }

    /// Node ids reachable via success/always edges (fixed `to` or router targets).
    /// Order follows edge declaration; duplicates are dropped. Reject/fail edges omitted.
    public func successNextNodeIds(from nodeId: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for edge in outgoingEdges(from: nodeId) {
            guard edge.on == .success || edge.on == .always else { continue }
            let nexts: [String]
            switch edge.type {
            case .fixed, .join:
                nexts = edge.to.map { [$0] } ?? []
            case .router, .fanOut:
                nexts = edge.targets
            }
            for next in nexts where seen.insert(next).inserted {
                result.append(next)
            }
        }
        return result
    }

    /// Predecessors that must succeed before `nodeId` may run, via inbound `.join` edges.
    public func joinPredecessors(of nodeId: String) -> [String] {
        edges
            .filter { $0.type == .join && $0.to == nodeId }
            .map(\.from)
    }

    public var entryNodeId: String? {
        entry ?? nodes.first?.id
    }
}

// MARK: - Canvas layout (UI positions; not part of org semantics)

public struct NodePosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CanvasLayout: Codable, Equatable, Sendable {
    public var nodes: [String: NodePosition]

    public init(nodes: [String: NodePosition] = [:]) {
        self.nodes = nodes
    }

    /// Layered BFS from entry for first-open / missing positions.
    public static func autoLayout(
        org: OrgGraph,
        nodeWidth: Double = 180,
        nodeHeight: Double = 72
    ) -> CanvasLayout {
        let ids = org.nodes.map(\.id)
        guard !ids.isEmpty else { return CanvasLayout() }

        let entry = org.entryNodeId ?? ids[0]
        var layerOf: [String: Int] = [:]
        var queue: [String] = [entry]
        layerOf[entry] = 0
        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            let layer = layerOf[id] ?? 0
            for edge in org.outgoingEdges(from: id) {
                let nexts: [String]
                switch edge.type {
                case .fixed, .join:
                    nexts = edge.to.map { [$0] } ?? []
                case .router, .fanOut:
                    nexts = edge.targets
                }
                for next in nexts where layerOf[next] == nil && ids.contains(next) {
                    layerOf[next] = layer + 1
                    queue.append(next)
                }
            }
        }
        for id in ids where layerOf[id] == nil {
            layerOf[id] = (layerOf.values.max() ?? 0) + 1
        }

        var byLayer: [Int: [String]] = [:]
        for id in ids {
            byLayer[layerOf[id] ?? 0, default: []].append(id)
        }

        let hGap = nodeWidth + 80
        let vGap = nodeHeight + 48
        var positions: [String: NodePosition] = [:]
        for (layer, layerIds) in byLayer {
            let sorted = layerIds.sorted()
            for (index, id) in sorted.enumerated() {
                positions[id] = NodePosition(
                    x: 80 + Double(layer) * hGap,
                    y: 80 + Double(index) * vGap
                )
            }
        }
        return CanvasLayout(nodes: positions)
    }

    public mutating func ensurePositions(for org: OrgGraph) {
        let missing = org.nodes.map(\.id).filter { nodes[$0] == nil }
        guard !missing.isEmpty else { return }
        let generated = CanvasLayout.autoLayout(org: org)
        for id in missing {
            if let pos = generated.nodes[id] {
                nodes[id] = pos
            }
        }
    }
}

// MARK: - Agents (on-disk: runners.yaml / node.runner)

/// Provider kind for an agent; drives which model catalog the UI offers.
public enum AgentKind: String, Codable, Equatable, Sendable, CaseIterable {
    case claudeCode = "claude_code"
    case cursorAgent = "cursor_agent"
    case codex = "codex"
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursorAgent: return "Cursor Agent"
        case .codex: return "Codex"
        case .custom: return "Custom"
        }
    }
}

public struct RunnerTemplate: Codable, Equatable, Sendable {
    public var command: String
    public var args: [String]
    public var cwd: String?
    public var env: [String: String]
    /// Which agent CLI / model catalog this template targets.
    public var kind: AgentKind
    /// Used when a node does not set `model` (nil = leave to CLI default).
    public var defaultModel: String?

    public init(
        command: String,
        args: [String] = [],
        cwd: String? = "{{project_root}}",
        env: [String: String] = [:],
        kind: AgentKind = .custom,
        defaultModel: String? = nil
    ) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.kind = kind
        self.defaultModel = defaultModel
    }

    private enum CodingKeys: String, CodingKey {
        case command, args, cwd, env, kind
        case defaultModel = "default_model"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        kind = try container.decodeIfPresent(AgentKind.self, forKey: .kind) ?? .custom
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
    }

    /// Node override wins; otherwise agent default; nil means CLI default.
    public func effectiveModel(nodeModel: String?) -> String? {
        if let nodeModel, !nodeModel.isEmpty { return nodeModel }
        if let defaultModel, !defaultModel.isEmpty { return defaultModel }
        return nil
    }
}

public struct RunnersConfig: Codable, Equatable, Sendable {
    public var runners: [String: RunnerTemplate]

    public init(runners: [String: RunnerTemplate] = [:]) {
        self.runners = runners
    }

    public func agent(named name: String) -> RunnerTemplate? {
        runners[name]
    }
}

// MARK: - Handoff contract

public struct RouterNext: Codable, Equatable, Sendable {
    public var nodeId: String
    public var reason: String

    public init(nodeId: String, reason: String) {
        self.nodeId = nodeId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case reason
    }
}

public struct CheckResult: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(name)-\(passed)" }
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(name: String, passed: Bool, detail: String = "") {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public struct HandoffContract: Codable, Equatable, Sendable {
    public var summary: String
    public var artifacts: [String]
    public var checks: [CheckResult]
    public var next: RouterNext?
    public var notes: String?

    public init(
        summary: String = "",
        artifacts: [String] = [],
        checks: [CheckResult] = [],
        next: RouterNext? = nil,
        notes: String? = nil
    ) {
        self.summary = summary
        self.artifacts = artifacts
        self.checks = checks
        self.next = next
        self.notes = notes
    }

    public func filtered(passing fields: [HandoffField]) -> (passed: HandoffContract, withheld: [HandoffField]) {
        let allowed = Set(fields)
        var withheld: [HandoffField] = []
        var result = HandoffContract()

        for field in HandoffField.allCases {
            let include = allowed.contains(field)
            switch field {
            case .summary:
                if include { result.summary = summary } else if !summary.isEmpty { withheld.append(field) }
            case .artifacts:
                if include { result.artifacts = artifacts } else if !artifacts.isEmpty { withheld.append(field) }
            case .checks:
                if include { result.checks = checks } else if !checks.isEmpty { withheld.append(field) }
            case .next:
                if include { result.next = next } else if next != nil { withheld.append(field) }
            case .notes:
                if include { result.notes = notes } else if notes != nil { withheld.append(field) }
            }
        }
        return (result, withheld)
    }
}

// MARK: - Run / Trace

public enum RunStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case awaitingApproval
    case succeeded
    case failed
    case cancelled
}

public struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var projectRoot: String
    public var goal: String
    public var status: RunStatus
    public var activeNodeId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        projectRoot: String,
        goal: String,
        status: RunStatus = .pending,
        activeNodeId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectRoot = projectRoot
        self.goal = goal
        self.status = status
        self.activeNodeId = activeNodeId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TraceEventKind: String, Codable, Equatable, Sendable {
    case runStarted
    case iterationStarted
    case cliFinished
    case checksEvaluated
    case handoffBuilt
    case awaitingApproval
    case approved
    case rejected
    case routed
    case joinReady
    case nodeSucceeded
    case nodeFailed
    case runSucceeded
    case runFailed
    case runCancelled
    case retry
    case escalate
}

public struct TraceEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var runId: String
    public var nodeId: String?
    public var kind: TraceEventKind
    public var message: String
    public var iteration: Int?
    public var payloadJSON: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        runId: String,
        nodeId: String? = nil,
        kind: TraceEventKind,
        message: String,
        iteration: Int? = nil,
        payloadJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runId = runId
        self.nodeId = nodeId
        self.kind = kind
        self.message = message
        self.iteration = iteration
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

public struct HandoffInspection: Codable, Equatable, Sendable {
    public var edgeId: String
    public var fromNode: String
    public var toNode: String
    public var passed: HandoffContract
    public var withheld: [HandoffField]
    public var requiresApproval: Bool
    public var nextHopReason: String?

    public init(
        edgeId: String,
        fromNode: String,
        toNode: String,
        passed: HandoffContract,
        withheld: [HandoffField],
        requiresApproval: Bool,
        nextHopReason: String? = nil
    ) {
        self.edgeId = edgeId
        self.fromNode = fromNode
        self.toNode = toNode
        self.passed = passed
        self.withheld = withheld
        self.requiresApproval = requiresApproval
        self.nextHopReason = nextHopReason
    }
}
