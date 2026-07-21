import Foundation
import GRDB
import GraphicalDomain

public actor TraceStore {
    private let dbQueue: DatabaseQueue

    public init(directory: URL? = nil) throws {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Graphical", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("graphical.sqlite")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try Self.makeMigrator().migrate(dbQueue)
    }

    /// In-memory store for tests.
    public init(inMemory: Bool) throws {
        precondition(inMemory)
        dbQueue = try DatabaseQueue()
        try Self.makeMigrator().migrate(dbQueue)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "runs") { t in
                t.column("id", .text).primaryKey()
                t.column("project_root", .text).notNull()
                t.column("goal", .text).notNull()
                t.column("status", .text).notNull()
                t.column("active_node_id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "trace_events") { t in
                t.column("id", .text).primaryKey()
                t.column("run_id", .text).notNull().indexed()
                t.column("node_id", .text)
                t.column("kind", .text).notNull()
                t.column("message", .text).notNull()
                t.column("iteration", .integer)
                t.column("payload_json", .text)
                t.column("created_at", .datetime).notNull()
            }
        }
        return migrator
    }

    public func saveRun(_ run: RunRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO runs (id, project_root, goal, status, active_node_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  project_root = excluded.project_root,
                  goal = excluded.goal,
                  status = excluded.status,
                  active_node_id = excluded.active_node_id,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    run.id,
                    run.projectRoot,
                    run.goal,
                    run.status.rawValue,
                    run.activeNodeId,
                    run.createdAt,
                    run.updatedAt
                ]
            )
        }
    }

    public func append(_ event: TraceEvent) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO trace_events
                (id, run_id, node_id, kind, message, iteration, payload_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    event.id,
                    event.runId,
                    event.nodeId,
                    event.kind.rawValue,
                    event.message,
                    event.iteration,
                    event.payloadJSON,
                    event.createdAt
                ]
            )
        }
    }

    public func run(id: String) throws -> RunRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM runs WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return Self.run(from: row)
        }
    }

    public func recentRuns(limit: Int = 50) throws -> [RunRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM runs ORDER BY created_at DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map(Self.run(from:))
        }
    }

    public func events(runId: String) throws -> [TraceEvent] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM trace_events WHERE run_id = ? ORDER BY created_at ASC",
                arguments: [runId]
            )
            return rows.map(Self.event(from:))
        }
    }

    public func exportTraceJSON(runId: String) throws -> Data {
        let run = try run(id: runId)
        let events = try events(runId: runId)
        let payload: [String: Any] = [
            "run": [
                "id": run?.id as Any,
                "projectRoot": run?.projectRoot as Any,
                "goal": run?.goal as Any,
                "status": run?.status.rawValue as Any,
                "activeNodeId": run?.activeNodeId as Any
            ],
            "events": events.map { event in
                [
                    "id": event.id,
                    "nodeId": event.nodeId as Any,
                    "kind": event.kind.rawValue,
                    "message": event.message,
                    "iteration": event.iteration as Any,
                    "payloadJSON": event.payloadJSON as Any,
                    "createdAt": ISO8601DateFormatter().string(from: event.createdAt)
                ] as [String: Any]
            }
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func run(from row: Row) -> RunRecord {
        RunRecord(
            id: row["id"],
            projectRoot: row["project_root"],
            goal: row["goal"],
            status: RunStatus(rawValue: row["status"]) ?? .failed,
            activeNodeId: row["active_node_id"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func event(from row: Row) -> TraceEvent {
        TraceEvent(
            id: row["id"],
            runId: row["run_id"],
            nodeId: row["node_id"],
            kind: TraceEventKind(rawValue: row["kind"]) ?? .cliFinished,
            message: row["message"],
            iteration: row["iteration"],
            payloadJSON: row["payload_json"],
            createdAt: row["created_at"]
        )
    }
}
