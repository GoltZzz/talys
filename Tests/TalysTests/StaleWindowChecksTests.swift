import XCTest
import ApplicationServices
@testable import Talys

final class StaleWindowChecksTests: XCTestCase {
    func testRemovalWaitsForAvailableHomeDesktopAndWakeGrace() {
        XCTAssertFalse(StaleWindowChecks.canCheckRemoval(
            suspended: true, awayFromHome: false, uptime: 100, allowedAfter: 0))
        XCTAssertFalse(StaleWindowChecks.canCheckRemoval(
            suspended: false, awayFromHome: true, uptime: 100, allowedAfter: 0))
        XCTAssertFalse(StaleWindowChecks.canCheckRemoval(
            suspended: false, awayFromHome: false, uptime: 129.9, allowedAfter: 130))
        XCTAssertTrue(StaleWindowChecks.canCheckRemoval(
            suspended: false, awayFromHome: false, uptime: 130, allowedAfter: 130))
    }

    func testTemporaryFailuresNeverRemoveWindows() {
        var checks = StaleWindowChecks()
        for _ in 0..<10 {
            XCTAssertFalse(checks.shouldRemove(1, status: .cannotComplete, confirmedAbsent: true))
            XCTAssertFalse(checks.shouldRemove(2, status: .invalidUIElement, confirmedAbsent: false))
        }
    }

    func testClosedWindowRequiresThreeConsecutiveConfirmations() {
        var checks = StaleWindowChecks()
        XCTAssertFalse(checks.shouldRemove(1, status: .invalidUIElement, confirmedAbsent: true))
        XCTAssertFalse(checks.shouldRemove(1, status: .invalidUIElement, confirmedAbsent: true))
        XCTAssertTrue(checks.shouldRemove(1, status: .invalidUIElement, confirmedAbsent: true))
    }

    func testSuccessfulOrUnavailableQueryResetsConfirmation() {
        for status in [AXError.success, .cannotComplete] {
            var checks = StaleWindowChecks()
            XCTAssertFalse(checks.shouldRemove(1, status: .invalidUIElement, confirmedAbsent: true))
            XCTAssertFalse(checks.shouldRemove(1, status: status, confirmedAbsent: false))
            XCTAssertFalse(checks.shouldRemove(1, status: .invalidUIElement, confirmedAbsent: true))
            XCTAssertFalse(checks.shouldRemove(1, status: .invalidUIElement, confirmedAbsent: true))
        }
    }
}
