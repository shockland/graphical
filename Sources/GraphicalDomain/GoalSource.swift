import Foundation

/// Policy for the Goal source: prefer `GOAL.md` (or `config.goalFile`) when present,
/// keep `project.yaml`'s `goal` field in sync on commit (plans/014).
public enum GoalSource {
    /// Prefers the goal file when it resolves inside the project root and is non-empty;
    /// otherwise returns the YAML `goal` field.
    public static func loadDraft(from project: GraphicalProject, store: YAMLStore) -> String {
        if let fromFile = try? store.loadGoalText(projectRoot: project.root, config: project.config),
           !fromFile.isEmpty {
            return fromFile
        }
        return project.config.goal
    }

    /// Writes `text` into both `config.goal` (in-memory) and the goal file on disk.
    /// Caller is responsible for persisting the rest of the project via `YAMLStore.save`.
    public static func commit(
        _ text: String,
        to project: inout GraphicalProject,
        store: YAMLStore
    ) throws {
        project.config.goal = text
        try store.writeGoalText(text, projectRoot: project.root, config: project.config)
    }
}
