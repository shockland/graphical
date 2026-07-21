import XCTest
@testable import GraphicalDomain

final class ShellInvocationTests: XCTestCase {
    func testRecognizesZshLcAsShellInvocation() {
        XCTAssertTrue(
            ShellInvocation.isShellInterpreterInvocation(
                command: "/bin/zsh",
                args: ["-lc", "echo hi"]
            )
        )
    }

    func testNonShellCommandIsLiteral() {
        XCTAssertFalse(
            ShellInvocation.isShellInterpreterInvocation(
                command: "claude",
                args: ["-p", "prompt"]
            )
        )
    }

    func testRepairUsesSharedClassifierForZsh() {
        let shredded = RunnerTemplate(
            command: "/bin/zsh",
            args: ["-lc", "line1", "line2"],
            kind: .custom
        )
        let repaired = RunnerArgsEditing.repairingShreddedShellScript(shredded)
        XCTAssertEqual(repaired.args, ["-lc", "line1\nline2"])
    }
}
