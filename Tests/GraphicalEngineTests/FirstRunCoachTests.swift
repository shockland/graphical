import XCTest
@testable import GraphicalCLI

final class FirstRunCoachTests: XCTestCase {
    private var suiteDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteDefaults = UserDefaults(suiteName: "graphical.tests.firstRunCoach.\(UUID().uuidString)")
        FirstRunCoach.defaults = suiteDefaults
        FirstRunCoach.resetForTests()
    }

    override func tearDown() {
        FirstRunCoach.resetForTests()
        FirstRunCoach.defaults = .standard
        suiteDefaults = nil
        super.tearDown()
    }

    func testApprovalTipMentionsRolesAndRejectEdgeDistinction() {
        let tip = FirstRunCoach.approvalTip(fromRole: "Planner", toRole: "Implementer")
        XCTAssertTrue(tip.contains("Planner"))
        XCTAssertTrue(tip.contains("Implementer"))
        XCTAssertTrue(tip.contains("Reviewer"))
        XCTAssertTrue(tip.contains("reject edge"))
    }

    func testTipsAreOneShotInDefaults() {
        XCTAssertFalse(FirstRunCoach.hasSeenApprovalTip)
        XCTAssertFalse(FirstRunCoach.hasSeenHistoryTip)
        FirstRunCoach.hasSeenApprovalTip = true
        FirstRunCoach.hasSeenHistoryTip = true
        XCTAssertTrue(FirstRunCoach.hasSeenApprovalTip)
        XCTAssertTrue(FirstRunCoach.hasSeenHistoryTip)
        FirstRunCoach.resetForTests()
        XCTAssertFalse(FirstRunCoach.hasSeenApprovalTip)
        XCTAssertFalse(FirstRunCoach.hasSeenHistoryTip)
    }

    func testHistoryTipIsNonEmpty() {
        XCTAssertFalse(FirstRunCoach.historyTip.isEmpty)
        XCTAssertTrue(FirstRunCoach.historyTip.localizedCaseInsensitiveContains("History"))
    }
}
