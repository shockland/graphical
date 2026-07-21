import Foundation
@preconcurrency import Yams

public enum GraphicalPaths {
    public static let directoryName = ".graphical"
    public static let projectFile = "project.yaml"
    public static let orgFile = "org.yaml"
    public static let runnersFile = "runners.yaml"
    public static let layoutFile = "layout.yaml"
    public static let artifactsDir = "artifacts"

    public static func graphicalDir(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func projectYAML(projectRoot: URL) -> URL {
        graphicalDir(projectRoot: projectRoot).appendingPathComponent(projectFile)
    }

    public static func orgYAML(projectRoot: URL) -> URL {
        graphicalDir(projectRoot: projectRoot).appendingPathComponent(orgFile)
    }

    public static func runnersYAML(projectRoot: URL) -> URL {
        graphicalDir(projectRoot: projectRoot).appendingPathComponent(runnersFile)
    }

    public static func layoutYAML(projectRoot: URL) -> URL {
        graphicalDir(projectRoot: projectRoot).appendingPathComponent(layoutFile)
    }

    public static func artifactsRoot(projectRoot: URL) -> URL {
        graphicalDir(projectRoot: projectRoot).appendingPathComponent(artifactsDir, isDirectory: true)
    }

    public static func runArtifacts(projectRoot: URL, runId: String) -> URL {
        artifactsRoot(projectRoot: projectRoot).appendingPathComponent(runId, isDirectory: true)
    }

    public static func nodeArtifacts(projectRoot: URL, runId: String, nodeId: String) -> URL {
        runArtifacts(projectRoot: projectRoot, runId: runId)
            .appendingPathComponent(nodeId, isDirectory: true)
    }
}

public struct GraphicalProject: Equatable, Sendable {
    public var root: URL
    public var config: ProjectConfig
    public var org: OrgGraph
    public var runners: RunnersConfig

    public init(root: URL, config: ProjectConfig, org: OrgGraph, runners: RunnersConfig) {
        self.root = root
        self.config = config
        self.org = org
        self.runners = runners
    }
}

public enum YAMLStoreError: Error, LocalizedError, Equatable {
    case notADirectory(URL)
    case missingGraphicalDir(URL)
    case encodeFailed(String)
    case decodeFailed(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url): return "Not a directory: \(url.path)"
        case .missingGraphicalDir(let url): return "Missing .graphical at \(url.path)"
        case .encodeFailed(let msg): return "YAML encode failed: \(msg)"
        case .decodeFailed(let msg): return "YAML decode failed: \(msg)"
        case .ioFailed(let msg): return "I/O failed: \(msg)"
        }
    }
}

public struct YAMLStore: @unchecked Sendable {
    private let encoder = YAMLEncoder()
    private let decoder = YAMLDecoder()
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exists(at projectRoot: URL) -> Bool {
        fileManager.fileExists(atPath: GraphicalPaths.projectYAML(projectRoot: projectRoot).path)
    }

    public func createProject(
        at projectRoot: URL,
        name: String? = nil,
        seedTemplate: Bool = true
    ) throws -> GraphicalProject {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: projectRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw YAMLStoreError.notADirectory(projectRoot)
        }

        let dir = GraphicalPaths.graphicalDir(projectRoot: projectRoot)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: GraphicalPaths.artifactsRoot(projectRoot: projectRoot),
            withIntermediateDirectories: true
        )

        let projectName = name ?? projectRoot.lastPathComponent
        let config = ProjectConfig(name: projectName, goal: "Describe the project goal.")
        let org = seedTemplate ? SeedTemplate.plannerImplementerReviewer() : OrgGraph()
        let runners = seedTemplate ? SeedTemplate.defaultRunners() : RunnersConfig()

        let project = GraphicalProject(root: projectRoot, config: config, org: org, runners: runners)
        try save(project)
        let layout = CanvasLayout.autoLayout(org: org)
        try saveLayout(layout, projectRoot: projectRoot)
        try ensureArtifactsGitignore(projectRoot: projectRoot)
        try ensureGoalFile(projectRoot: projectRoot, config: config)
        return project
    }

    public func load(from projectRoot: URL) throws -> GraphicalProject {
        guard exists(at: projectRoot) else {
            throw YAMLStoreError.missingGraphicalDir(projectRoot)
        }
        let config: ProjectConfig = try decode(from: GraphicalPaths.projectYAML(projectRoot: projectRoot))
        let org: OrgGraph = try decode(from: GraphicalPaths.orgYAML(projectRoot: projectRoot))
        let runners: RunnersConfig = try decode(from: GraphicalPaths.runnersYAML(projectRoot: projectRoot))
        return GraphicalProject(root: projectRoot, config: config, org: org, runners: runners)
    }

    public func save(_ project: GraphicalProject) throws {
        try encode(project.config, to: GraphicalPaths.projectYAML(projectRoot: project.root))
        try encode(project.org, to: GraphicalPaths.orgYAML(projectRoot: project.root))
        try encode(project.runners, to: GraphicalPaths.runnersYAML(projectRoot: project.root))
    }

    public func saveConfig(_ config: ProjectConfig, projectRoot: URL) throws {
        try encode(config, to: GraphicalPaths.projectYAML(projectRoot: projectRoot))
    }

    public func saveOrg(_ org: OrgGraph, projectRoot: URL) throws {
        try encode(org, to: GraphicalPaths.orgYAML(projectRoot: projectRoot))
    }

    public func saveRunners(_ runners: RunnersConfig, projectRoot: URL) throws {
        try encode(runners, to: GraphicalPaths.runnersYAML(projectRoot: projectRoot))
    }

    public func loadLayout(projectRoot: URL, org: OrgGraph) throws -> CanvasLayout {
        let url = GraphicalPaths.layoutYAML(projectRoot: projectRoot)
        var layout: CanvasLayout
        if fileManager.fileExists(atPath: url.path) {
            layout = try decode(from: url)
        } else {
            layout = CanvasLayout.autoLayout(org: org)
            try saveLayout(layout, projectRoot: projectRoot)
        }
        layout.ensurePositions(for: org)
        return layout
    }

    public func saveLayout(_ layout: CanvasLayout, projectRoot: URL) throws {
        try encode(layout, to: GraphicalPaths.layoutYAML(projectRoot: projectRoot))
    }

    public func ensureArtifactsGitignore(projectRoot: URL) throws {
        let gitignore = GraphicalPaths.artifactsRoot(projectRoot: projectRoot)
            .appendingPathComponent(".gitignore")
        if !fileManager.fileExists(atPath: gitignore.path) {
            try "*\n!.gitignore\n".write(to: gitignore, atomically: true, encoding: .utf8)
        }
    }

    private func ensureGoalFile(projectRoot: URL, config: ProjectConfig) throws {
        guard let goalFile = config.goalFile else { return }
        let url = projectRoot.appendingPathComponent(goalFile)
        if !fileManager.fileExists(atPath: url.path) {
            let body = "# Goal\n\n\(config.goal)\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func encodeToString<T: Encodable>(_ value: T) throws -> String {
        do {
            return try encoder.encode(value)
        } catch {
            throw YAMLStoreError.encodeFailed(error.localizedDescription)
        }
    }

    public func decodeFromString<T: Decodable>(_ type: T.Type, string: String) throws -> T {
        do {
            return try decoder.decode(type, from: string)
        } catch {
            throw YAMLStoreError.decodeFailed(error.localizedDescription)
        }
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let text = try encodeToString(value)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw YAMLStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(from url: URL) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw YAMLStoreError.ioFailed(error.localizedDescription)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw YAMLStoreError.decodeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
