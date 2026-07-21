import Foundation
import GraphicalDomain

/// A selectable model id for org nodes (`{{model}}` / model_hint).
public struct CatalogModel: Equatable, Sendable, Hashable, Identifiable {
    public var id: String { slug }
    public var slug: String
    public var label: String

    public init(slug: String, label: String) {
        self.slug = slug
        self.label = label
    }

    public var menuTitle: String {
        if label == slug || label.isEmpty { return slug }
        return "\(label) — \(slug)"
    }
}

/// Kind-scoped model catalogs. Cursor live discovery only for `cursor_agent`.
public enum ModelCatalog {
    /// Claude Code stable aliases (preferred for most users).
    public static let claudeAliases: [CatalogModel] = [
        CatalogModel(slug: "default", label: "Default"),
        CatalogModel(slug: "best", label: "Best"),
        CatalogModel(slug: "fable", label: "Fable"),
        CatalogModel(slug: "opus", label: "Opus"),
        CatalogModel(slug: "sonnet", label: "Sonnet"),
        CatalogModel(slug: "haiku", label: "Haiku"),
        CatalogModel(slug: "opus[1m]", label: "Opus 1M"),
        CatalogModel(slug: "sonnet[1m]", label: "Sonnet 1M"),
        CatalogModel(slug: "opusplan", label: "Opus Plan")
    ]

    /// Small Codex starter list; freeform values still allowed via merge.
    public static let codexModels: [CatalogModel] = [
        CatalogModel(slug: "o3", label: "o3"),
        CatalogModel(slug: "o4-mini", label: "o4-mini"),
        CatalogModel(slug: "gpt-5.2", label: "GPT-5.2")
    ]

    /// Tiny Cursor fallback when live discovery fails.
    public static let cursorFallback: [CatalogModel] = [
        CatalogModel(slug: "auto", label: "Auto"),
        CatalogModel(slug: "composer-2.5", label: "Composer 2.5"),
        CatalogModel(slug: "gpt-5.2", label: "GPT-5.2")
    ]

    public static func presets(for kind: AgentKind) -> [CatalogModel] {
        switch kind {
        case .claudeCode: return claudeAliases
        case .codex: return codexModels
        case .cursorAgent: return cursorFallback
        case .custom: return []
        }
    }

    /// Parse `agent models` / `agent --list-models` text output.
    /// Lines look like: `claude-opus-4-8-high - Opus 4.8 1M`
    public static func parseAgentModelsOutput(_ text: String) -> [CatalogModel] {
        var seen = Set<String>()
        var models: [CatalogModel] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("available models") { continue }
            guard let dash = line.range(of: " - ") else { continue }
            let slug = String(line[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let label = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !slug.isEmpty, !slug.contains(where: \.isWhitespace), seen.insert(slug).inserted else {
                continue
            }
            models.append(CatalogModel(slug: slug, label: label.isEmpty ? slug : label))
        }
        return models
    }

    /// Merge catalog models with extras (e.g. values already used in the org).
    public static func merge(discovered: [CatalogModel], extras: [String]) -> [CatalogModel] {
        var seen = Set(discovered.map(\.slug))
        var result = discovered
        for raw in extras {
            let slug = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty, seen.insert(slug).inserted else { continue }
            result.append(CatalogModel(slug: slug, label: slug))
        }
        return result
    }

    /// Models for an agent kind. Live-probes Cursor only for `cursor_agent`.
    public static func models(
        for kind: AgentKind,
        using processRunner: any ProcessExecuting = ProcessRunner(),
        timeoutSeconds: Int = 12
    ) async -> [CatalogModel] {
        switch kind {
        case .claudeCode, .codex, .custom:
            return presets(for: kind)
        case .cursorAgent:
            return await discoverCursorModels(using: processRunner, timeoutSeconds: timeoutSeconds)
        }
    }

    private static func discoverCursorModels(
        using processRunner: any ProcessExecuting,
        timeoutSeconds: Int
    ) async -> [CatalogModel] {
        let probes: [(command: String, arguments: [String])] = [
            ("cursor-agent", ["models"]),
            ("cursor-agent", ["--list-models"]),
            ("agent", ["models"]),
            ("cursor", ["agent", "models"])
        ]
        for probe in probes {
            do {
                let result = try await processRunner.run(
                    command: probe.command,
                    arguments: probe.arguments,
                    workingDirectory: nil,
                    environment: [:],
                    timeoutSeconds: timeoutSeconds,
                    inheritEnvironment: true
                )
                guard result.succeeded else { continue }
                let parsed = parseAgentModelsOutput(result.stdout)
                if !parsed.isEmpty { return parsed }
            } catch {
                continue
            }
        }
        return cursorFallback
    }
}
