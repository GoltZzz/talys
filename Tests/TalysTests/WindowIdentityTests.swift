import XCTest
import ApplicationServices
@testable import Talys

final class WindowIdentityTests: XCTestCase {
    func testSameWindowMatchesByProcessAndWindowID() {
        XCTAssertEqual(WindowIdentity(pid: 123, windowID: 42), WindowIdentity(pid: 123, windowID: 42))
        XCTAssertNotEqual(WindowIdentity(pid: 123, windowID: 42), WindowIdentity(pid: 124, windowID: 42))
        XCTAssertNotEqual(WindowIdentity(pid: 123, windowID: 42), WindowIdentity(pid: 123, windowID: 43))
    }

    func testUnavailableIdentityCannotMatchAnotherUnknownWindow() {
        XCTAssertNil(WindowIdentity(pid: 123, windowID: nil))
        XCTAssertNil(WindowIdentity(pid: 123, windowID: 0))
        XCTAssertNil(WindowIdentity(pid: 0, windowID: 42))
    }

    @MainActor
    func testRecordKeepsHandleEqualityWhenWindowIDIsUnavailable() async {
        let element = AXUIElementCreateApplication(123)
        let record = WindowRecord(id: 1, element: element, pid: 123, title: "Window")
        XCTAssertTrue(record.matches(element, identity: nil))
        XCTAssertFalse(record.matches(AXUIElementCreateApplication(124), identity: nil))
    }
}
