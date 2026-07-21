import XCTest
@testable import GraphicalDomain

final class RunnerArgsEditingTests: XCTestCase {
    func testSingleLineArgsRoundTripAsPlainLines() {
        let args = ["-p", "{{prompt_file}}", "--model", "{{model}}"]
        let encoded = RunnerArgsEditing.encodeForEditor(args)
        XCTAssertEqual(encoded, "-p\n{{prompt_file}}\n--model\n{{model}}")
        XCTAssertEqual(RunnerArgsEditing.decodeFromEditor(encoded), args)
    }

    func testMultilineShellScriptRoundTripViaYAML() {
        let script = """
        set -euo pipefail
        export PATH="$HOME/.local/bin:$PATH"
        cursor-agent -p --trust --force --workspace {{project_root}} --model {{model}} "$(cat {{prompt_file}})"
        """
        let args = ["-lc", script]
        let encoded = RunnerArgsEditing.encodeForEditor(args)
        XCTAssertTrue(encoded.contains("-lc") || encoded.contains("- -lc"), encoded)
        let decoded = RunnerArgsEditing.decodeFromEditor(encoded)
        XCTAssertEqual(decoded.count, 2, "encoded:\n\(encoded)\ndecoded:\n\(decoded)")
        XCTAssertEqual(decoded[0], "-lc")
        XCTAssertEqual(decoded[1], script)
    }

    func testPlainDashPFlagIsNotMistakenForYAMLList() {
        let text = "-p\n{{prompt_file}}\n--model\n{{model}}"
        XCTAssertEqual(
            RunnerArgsEditing.decodeFromEditor(text),
            ["-p", "{{prompt_file}}", "--model", "{{model}}"]
        )
    }

    func testRepairsShreddedBashLcScript() {
        let shredded = RunnerTemplate(
            command: "/bin/bash",
            args: [
                "-lc",
                "set -euo pipefail",
                "export PATH=\"$HOME/.local/bin:$PATH\"",
                "cursor-agent -p --trust --force --workspace {{project_root}} --model {{model}} \"$(cat {{prompt_file}})\""
            ],
            kind: .cursorAgent
        )
        let repaired = RunnerArgsEditing.repairingShreddedShellScript(shredded)
        XCTAssertEqual(repaired.args.count, 2)
        XCTAssertEqual(repaired.args[0], "-lc")
        XCTAssertTrue(repaired.args[1].contains("set -euo pipefail"))
        XCTAssertTrue(repaired.args[1].contains("cursor-agent"))
        XCTAssertTrue(repaired.args[1].contains("export PATH="))
    }

    func testLoadRepairsShreddedCursorRunnerOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphical-shred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = YAMLStore()
        _ = try store.createProject(at: root, name: "Shred", seedTemplate: true)
        let shredded = RunnersConfig(runners: [
            "cursor_agent": RunnerTemplate(
                command: "/bin/bash",
                args: [
                    "-lc",
                    "set -euo pipefail",
                    "cursor-agent -p --workspace {{project_root}} --model {{model}} \"$(cat {{prompt_file}})\""
                ],
                kind: .cursorAgent,
                defaultModel: "cursor-grok-4.5-high"
            )
        ])
        try store.saveRunners(shredded, projectRoot: root)

        let loaded = try store.load(from: root)
        let args = try XCTUnwrap(loaded.runners.runners["cursor_agent"]?.args)
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0], "-lc")
        XCTAssertTrue(args[1].contains("cursor-agent"))
        XCTAssertTrue(args[1].contains("set -euo pipefail"))
    }
}
