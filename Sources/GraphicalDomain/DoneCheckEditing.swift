import Foundation

/// Pure merge helper backing `OrgInspectorView.applyNode`. The inspector UI only edits
/// artifact paths and a router-next toggle; this keeps `.shell(...)` checks (and the
/// `allOf`/`anyOf` group kind) intact across an Apply so hand-authored checks the UI
/// cannot yet edit are not silently dropped.
public enum DoneCheckMerge {
    /// Merges UI-editable fields (artifact paths, router-next toggle) onto `existing`,
    /// preserving any `.shell` checks and the group's `allOf`/`anyOf` kind.
    ///
    /// - Order: new artifact checks first, then preserved shell checks (matching seed
    ///   template convention), then `.routerNext` last if enabled.
    /// - If `existing` was an empty `anyOf` and artifacts are being added, switches to
    ///   `allOf` — an empty `anyOf` has no meaningful "any" semantics to preserve.
    public static func applyArtifactEdits(
        existing: DoneCheckGroup,
        artifactPaths: [String],
        includeRouterNext: Bool
    ) -> DoneCheckGroup {
        let preservedShell = existing.checks.filter { check in
            if case .shell = check { return true }
            return false
        }

        var checks: [DoneCheck] = artifactPaths.map { .artifact($0) }
        checks.append(contentsOf: preservedShell)
        if includeRouterNext {
            checks.append(.routerNext)
        }

        switch existing {
        case .anyOf where existing.checks.isEmpty && !artifactPaths.isEmpty:
            return .allOf(checks)
        case .allOf:
            return .allOf(checks)
        case .anyOf:
            return .anyOf(checks)
        }
    }
}
