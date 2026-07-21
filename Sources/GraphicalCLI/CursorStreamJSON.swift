import Foundation

/// Formats Cursor Agent `--output-format stream-json` NDJSON lines for the live run
/// console. Raw non-JSON lines pass through unchanged (Claude/Codex/demo fixtures).
public struct CursorStreamJSONFormatter: Sendable {
    /// Once a partial delta (`timestamp_ms`, no `model_call_id`) is seen, later
    /// assistant events without `timestamp_ms` are treated as end-of-turn duplicates.
    private var seenPartialDeltas = false

    public init() {}

    public enum LineResult: Equatable, Sendable {
        /// Line is not Cursor stream-json; show it as-is.
        case passthrough
        /// Recognized event that should not appear in the live log.
        case skip
        /// Human-readable status lines (tools, session init) — never coalesce.
        case display([String])
        /// Assistant text deltas — may be coalesced across events.
        case assistantText([String])
    }

    public mutating func format(line: String) -> LineResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return .passthrough
        }

        switch type {
        case "system":
            if object["subtype"] as? String == "init" {
                let model = object["model"] as? String
                if let model, !model.isEmpty {
                    return .display(["model \(model)"])
                }
                return .display(["session started"])
            }
            return .skip

        case "user":
            return .skip

        case "assistant":
            return formatAssistant(object)

        case "tool_call":
            return formatToolCall(object)

        case "result":
            // Canonical final text duplicates assistant deltas; skip to avoid noise.
            return .skip

        default:
            return .skip
        }
    }

    private mutating func formatAssistant(_ object: [String: Any]) -> LineResult {
        let hasTimestamp = object["timestamp_ms"] != nil
        let hasModelCallID = object["model_call_id"] != nil

        if hasModelCallID {
            return .skip
        }
        if hasTimestamp {
            seenPartialDeltas = true
        } else if seenPartialDeltas {
            return .skip
        }

        let text = assistantText(from: object)
        guard !text.isEmpty else { return .skip }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return lines.isEmpty ? .skip : .assistantText(lines)
    }

    private func formatToolCall(_ object: [String: Any]) -> LineResult {
        guard object["subtype"] as? String == "started" else { return .skip }
        guard let toolCall = object["tool_call"] as? [String: Any] else {
            return .display(["tool"])
        }
        if let read = toolCall["readToolCall"] as? [String: Any],
           let args = read["args"] as? [String: Any],
           let path = args["path"] as? String {
            return .display(["read \(path)"])
        }
        if let write = toolCall["writeToolCall"] as? [String: Any],
           let args = write["args"] as? [String: Any],
           let path = args["path"] as? String {
            return .display(["write \(path)"])
        }
        if let function = toolCall["function"] as? [String: Any],
           let name = function["name"] as? String {
            return .display(["tool \(name)"])
        }
        if let key = toolCall.keys.sorted().first {
            let label = key.replacingOccurrences(of: "ToolCall", with: "")
            return .display(["tool \(label)"])
        }
        return .display(["tool"])
    }

    private func assistantText(from object: [String: Any]) -> String {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return ""
        }
        return content.compactMap { part in
            guard part["type"] as? String == "text" || part["text"] != nil else { return nil }
            return part["text"] as? String
        }.joined()
    }
}
