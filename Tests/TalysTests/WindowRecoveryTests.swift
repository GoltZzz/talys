import XCTest
@testable import Talys

final class WindowRecoveryTests: XCTestCase {
    private func withJournal(_ body: (inout RecoveryJournal, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try RecoveryJournal(url: directory.appendingPathComponent("recovery.json"))
        try body(&journal, directory)
    }

    private func entry(_ id: UInt32) -> RecoveryEntry {
        RecoveryEntry(pid: 123, launched: Date(timeIntervalSince1970: 100), windowID: id,
                      frame: CGRect(x: 120, y: 80, width: 800, height: 600))
    }

    @MainActor
    func testWindowIdentityAPIIsAvailableOnThisMac() async {
        XCTAssertTrue(WindowRecovery.supportsWindowIdentity)
    }

    func testReusedPIDCannotMatchAnEarlierProcess() {
        let old = entry(1)
        XCTAssertTrue(old.matchesProcess(pid: 123, launched: old.launched))
        XCTAssertFalse(old.matchesProcess(pid: 123, launched: old.launched.addingTimeInterval(1)))
        XCTAssertFalse(old.matchesProcess(pid: 124, launched: old.launched))
    }

    func testMissingAppLaunchDateFallsBackToProcessStartTime() {
        let start = Date(timeIntervalSince1970: 123.456)
        let identity = RecoveryProcessIdentity.resolve(launchDate: nil, processStartTime: start)
        XCTAssertEqual(identity?.date, start)
        XCTAssertEqual(identity?.usesProcessStartTime, true)
        XCTAssertNil(RecoveryProcessIdentity.resolve(launchDate: nil, processStartTime: nil))
        let appIdentity = RecoveryProcessIdentity.resolve(launchDate: start, processStartTime: nil)
        XCTAssertEqual(appIdentity?.date, start)
        XCTAssertEqual(appIdentity?.usesProcessStartTime, false)
    }

    func testKernelProcessStartTimeIsStable() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = RecoveryProcessIdentity.startTime(pid: pid)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, RecoveryProcessIdentity.startTime(pid: pid))
        XCTAssertNil(RecoveryProcessIdentity.startTime(pid: -1))
    }

    func testLegacyJournalAndFallbackIdentitySurviveReload() throws {
        try withJournal { journal, _ in
            // Pre-fallback journals do not contain usesProcessStartTime.
            try FileManager.default.createDirectory(at: journal.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacy = """
            [{"pid":123,"launched":100,"windowID":1,"frame":[[120,80],[800,600]]}]
            """
            try Data(legacy.utf8).write(to: journal.url)
            let old = try RecoveryJournal(url: journal.url)
            XCTAssertNil(old.entries.first?.usesProcessStartTime)
            XCTAssertEqual(old.entries[0].timestamp(launchDate: old.entries[0].launched, processStartTime: nil), old.entries[0].launched)
            var fallback = entry(2)
            fallback.usesProcessStartTime = true
            // Recovery must keep checking the kernel timestamp even if AppKit later provides a date.
            XCTAssertEqual(fallback.timestamp(launchDate: fallback.launched.addingTimeInterval(10), processStartTime: fallback.launched), fallback.launched)
            try journal.replace(old.entries + [fallback])
            let reloaded = try RecoveryJournal(url: journal.url)
            XCTAssertEqual(reloaded.entries, old.entries + [fallback])
            XCTAssertFalse(fallback.matchesProcess(pid: fallback.pid, launched: fallback.launched.addingTimeInterval(1)))
        }
    }

    func testPendingRecoveryDoesNotRewriteJournal() throws {
        try withJournal { journal, directory in
            try journal.replace([entry(1)])
            let oldData = try Data(contentsOf: journal.url)
            XCTAssertEqual(try journal.recover { _ in .pending }, 0)
            XCTAssertEqual(try Data(contentsOf: journal.url), oldData)
            // A subsequent process can still retry the record.
            XCTAssertEqual(try RecoveryJournal(url: journal.url).entries, [entry(1)])
        }
    }

    func testInterruptedSessionRetainsOriginalFrameAcrossReload() throws {
        try withJournal { journal, _ in
            try journal.replace([entry(1)])
            let restarted = try RecoveryJournal(url: journal.url)
            XCTAssertEqual(restarted.entries, [entry(1)])
        }
    }

    func testRecoveryRetainsMissingOrUnmovableWindowsAndIsRetryable() throws {
        try withJournal { journal, _ in
            try journal.replace([entry(1), entry(2), entry(3)])
            let count = try journal.recover { value in
                switch value.windowID {
                case 1: return .recovered
                case 2: return .gone
                default: return .pending
                }
            }
            XCTAssertEqual(count, 1)
            XCTAssertEqual(try RecoveryJournal(url: journal.url).entries, [entry(3)])
            XCTAssertEqual(try journal.recover { _ in .recovered }, 1)
            XCTAssertTrue(try RecoveryJournal(url: journal.url).entries.isEmpty)
            XCTAssertEqual(try journal.recover { _ in XCTFail("Already recovered"); return .pending }, 0)
        }
    }

    func testFailedCommitDoesNotForgetRecovery() throws {
        try withJournal { journal, directory in
            try journal.replace([entry(1)])
            try FileManager.default.removeItem(at: directory)
            try Data().write(to: directory) // Blocks recreation of the journal's parent directory.
            XCTAssertThrowsError(try journal.recover { _ in .recovered })
            XCTAssertEqual(journal.entries, [entry(1)])
        }
    }

    func testCorruptJournalIsPreserved() throws {
        try withJournal { journal, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let corrupt = Data("broken journal".utf8)
            try corrupt.write(to: journal.url)
            XCTAssertThrowsError(try RecoveryJournal(url: journal.url))
            XCTAssertEqual(try Data(contentsOf: journal.url), corrupt)
        }
    }

    func testRecoveryFitsDisconnectedDisplayAndOversizedWindows() {
        let bounds = CGRect(x: -1440, y: 40, width: 1440, height: 860)
        let fitted = RecoveryJournal.fitted(CGRect(x: 3000, y: 2000, width: 1800, height: 1200), in: bounds)
        XCTAssertEqual(fitted, bounds)
        XCTAssertTrue(RecoveryJournal.reachable(fitted, in: bounds))
        // Minimum-size apps may remain larger than the display, but the title bar is usable.
        XCTAssertTrue(RecoveryJournal.reachable(CGRect(x: -1440, y: 40, width: 1800, height: 1200), in: bounds))
        XCTAssertFalse(RecoveryJournal.reachable(CGRect(x: -1, y: 899, width: 800, height: 600), in: bounds))
        let normal = CGRect(x: -1200, y: 100, width: 800, height: 600)
        XCTAssertEqual(RecoveryJournal.fitted(normal, in: bounds), normal)
    }
}
