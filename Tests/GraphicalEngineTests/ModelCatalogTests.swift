import XCTest
@testable import GraphicalCLI
@testable import GraphicalDomain

final class ModelCatalogTests: XCTestCase {
    func testParseAgentModelsOutput() {
        let sample = """
        Available models

        auto - Auto (default)
        gpt-5.3-codex - Codex 5.3
        claude-opus-4-8-thinking-high - Opus 4.8 1M Thinking
        composer-2.5 - Composer 2.5
        """
        let models = ModelCatalog.parseAgentModelsOutput(sample)
        XCTAssertEqual(models.map(\.slug), [
            "auto",
            "gpt-5.3-codex",
            "claude-opus-4-8-thinking-high",
            "composer-2.5"
        ])
        XCTAssertEqual(models[0].label, "Auto (default)")
        XCTAssertEqual(models[2].menuTitle, "Opus 4.8 1M Thinking — claude-opus-4-8-thinking-high")
    }

    func testParseSkipsMalformedLines() {
        let sample = """
        Available models
        not-a-model-line
        slug with spaces - Bad
        good-slug - Good Label
        """
        let models = ModelCatalog.parseAgentModelsOutput(sample)
        XCTAssertEqual(models.map(\.slug), ["good-slug"])
    }

    func testMergeKeepsDiscoveredOrderAndAppendsExtras() {
        let discovered = [
            CatalogModel(slug: "auto", label: "Auto"),
            CatalogModel(slug: "opus", label: "Opus")
        ]
        let merged = ModelCatalog.merge(discovered: discovered, extras: ["opus", "custom-model", "  "])
        XCTAssertEqual(merged.map(\.slug), ["auto", "opus", "custom-model"])
    }

    func testClaudePresetsIncludeStableAliases() {
        let slugs = ModelCatalog.presets(for: .claudeCode).map(\.slug)
        for expected in ["default", "best", "fable", "opus", "sonnet", "haiku", "opus[1m]", "sonnet[1m]", "opusplan"] {
            XCTAssertTrue(slugs.contains(expected), "missing \(expected)")
        }
    }

    func testCustomKindHasNoPresets() {
        XCTAssertTrue(ModelCatalog.presets(for: .custom).isEmpty)
    }

    func testModelsForClaudeReturnsPresetsSynchronously() async {
        let models = await ModelCatalog.models(for: .claudeCode)
        XCTAssertEqual(models.map(\.slug), ModelCatalog.claudeAliases.map(\.slug))
    }
}
