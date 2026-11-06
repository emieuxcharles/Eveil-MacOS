import XCTest
import Darwin
import EveilIPC
@testable import EveilCore

final class DriverJournalTests: XCTestCase {
    func testParserPreservesSourceSpecificSettings() throws {
        let result = try PMSetPowerDriver.parse(custom: "Battery Power:\n lowpowermode 0\nAC Power:\n lowpowermode 1\nUPS Power:\n lowpowermode 0\n", global: "System-wide power settings:\n SleepDisabled\t\t1\n")
        XCTAssertEqual(result.lowPower, [.battery: 0, .ac: 1, .ups: 0]); XCTAssertTrue(result.sleepDisabled)
    }
    func testParserRejectsMissingMalformedOrDuplicateValues() {
        for custom in ["", "AC Power:\n lowpowermode 3", "AC Power:\n lowpowermode 0\n lowpowermode 1"] {
            XCTAssertThrowsError(try PMSetPowerDriver.parse(custom: custom, global: "SleepDisabled 0"))
        }
        XCTAssertThrowsError(try PMSetPowerDriver.parse(custom: "AC Power:\n lowpowermode 1", global: "SleepDisabled 5"))
    }
    func testDurableJournalRoundtripPermissionsAndIdempotentRemoval() throws {
        let path = NSTemporaryDirectory() + "eveil-journal-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: path) }
        let journal = SecureSessionJournal(directory: path, requiredOwner: geteuid())
        XCTAssertNil(try journal.load())
        let record = SessionRecord(id: UUID(), originalLowPower: [.ac: 0], startedAt: Date(), deadline: nil, duration: 0)
        try journal.save(record); XCTAssertEqual(try journal.load()?.id, record.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: path + "/session.json")
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try journal.remove(); try journal.remove(); XCTAssertNil(try journal.load())
    }
    func testJournalRejectsCorruptionAndSymlink() throws {
        let path = NSTemporaryDirectory() + "eveil-journal-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: path) }
        let journal = SecureSessionJournal(directory: path, requiredOwner: geteuid())
        XCTAssertNil(try journal.load())
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: path + "/session.json"))
        chmod(path + "/session.json", 0o600)
        XCTAssertThrowsError(try journal.load())
        try FileManager.default.removeItem(atPath: path + "/session.json")
        try FileManager.default.createSymbolicLink(atPath: path + "/session.json", withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try journal.load())
    }
    func testCommandTimeoutIsBoundedAndCannotKillLaterCommand() throws {
        let start = Date()
        XCTAssertThrowsError(try BoundedCommandRunner.run(executable: "/bin/sleep", arguments: ["2"], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(try BoundedCommandRunner.run(executable: "/usr/bin/true", arguments: [], timeout: 1), "")
    }
    func testCommandFailureAndLargeOutputDoNotHang() throws {
        XCTAssertThrowsError(try BoundedCommandRunner.run(executable: "/usr/bin/false", arguments: [], timeout: 1))
        XCTAssertThrowsError(try BoundedCommandRunner.run(executable: "/usr/bin/yes", arguments: [], timeout: 0.05))
    }

}
