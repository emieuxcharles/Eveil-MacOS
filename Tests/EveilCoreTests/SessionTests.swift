import XCTest
@testable import EveilCore
import EveilIPC

final class TestClock: SessionClock {
    var wall = Date(timeIntervalSince1970: 1000)
    var monotonic: TimeInterval = 100
    func advance(_ seconds: Double) { wall.addTimeInterval(seconds); monotonic += seconds }
}
final class TestPower: PowerDriver {
    var settings = PowerSettings(lowPower: [.battery: 0, .ac: 1], sleepDisabled: true)
    var failLowPower = false
    var failSleepPermission = false
    var ignoreLowPower = false
    var sleepRequests = 0
    var events: [String] = []
    func read() throws -> PowerSettings { settings }
    func setLowPower(_ value: Int, source: PowerSource) throws {
        events.append("low:\(source.rawValue):\(value)")
        if failLowPower { throw TestError.failure }
        if !ignoreLowPower { settings.lowPower[source] = value }
    }
    func setSleepDisabled(_ disabled: Bool) throws {
        events.append("sleep:\(disabled)")
        if failSleepPermission { throw TestError.failure }
        settings.sleepDisabled = disabled
    }
    func requestSleep() throws { sleepRequests += 1 }
}
enum TestError: Error { case failure }
final class TestJournal: SessionJournal {
    var value: SessionRecord?
    var corrupt = false
    var failSave = false
    var failRemove = false
    var saveCount = 0
    var onSave: (() -> Void)?
    func load() throws -> SessionRecord? { if corrupt { throw TestError.failure }; return value }
    func save(_ record: SessionRecord) throws {
        if failSave { throw TestError.failure }
        saveCount += 1; value = record; onSave?()
    }
    func remove() throws { if failRemove { throw TestError.failure }; value = nil }
}
final class SessionTests: XCTestCase {
    var clock: TestClock!; var power: TestPower!; var journal: TestJournal!; var engine: SessionEngine!
    override func setUp() {
        clock = TestClock(); power = TestPower(); journal = TestJournal()
        engine = SessionEngine(clock: clock, power: power, journal: journal)
    }
    func start(_ duration: Int = 3600, owner: String = "one") throws { try engine.start(duration: duration, owner: owner) }
    func testDurationsAreStrictAndUnlimitedHasNoDeadline() throws {
        for duration in [-1, 1, 30, 3599, 3601, Int.max] { XCTAssertThrowsError(try start(duration)) }
        try start(0); XCTAssertNil(engine.snapshot.deadline); XCTAssertEqual(engine.snapshot.phase, .active)
    }
    func testJournalIsSavedBeforeMutationAndEachSourceIsRestored() throws {
        journal.onSave = { XCTAssertTrue(self.power.events.isEmpty) }
        try start(); journal.onSave = nil
        XCTAssertEqual(power.settings.lowPower, [.battery: 1, .ac: 1]); XCTAssertTrue(power.settings.sleepDisabled)
        try engine.stop(cause: .user)
        XCTAssertEqual(power.settings.lowPower, [.battery: 0, .ac: 1]); XCTAssertFalse(power.settings.sleepDisabled)
        XCTAssertNil(journal.value); XCTAssertEqual(engine.snapshot.phase, .idle)
    }
    func testDurationUsesMonotonicAndWallClockDoesNotExtendIt() throws {
        try start(); clock.wall.addTimeInterval(-6000)
        for _ in 0..<359 { clock.advance(10); try engine.heartbeat(owner: "one"); engine.tick() }
        clock.advance(10); engine.tick()
        XCTAssertEqual(engine.snapshot.phase, .idle); XCTAssertEqual(engine.snapshot.stopCause, .expired)
    }
    func testForwardWallDeadlineEndsSession() throws {
        try start(); clock.wall.addTimeInterval(3600); engine.tick()
        XCTAssertEqual(engine.snapshot.stopCause, .expired); XCTAssertFalse(power.settings.sleepDisabled)
    }
    func testReadOnlyClientsCannotRenewAndSecondOwnerCannotReplace() throws {
        try start(); XCTAssertThrowsError(try start(owner: "two")); XCTAssertThrowsError(try engine.heartbeat(owner: "two"))
        for _ in 0..<5 { clock.advance(5); _ = engine.snapshot; engine.disconnected(owner: "two"); engine.tick() }
        XCTAssertEqual(engine.snapshot.stopCause, .heartbeatLost); XCTAssertFalse(power.settings.sleepDisabled)
    }
    func testOwnerDisconnectRestoresImmediately() throws {
        try start(); engine.disconnected(owner: "one")
        XCTAssertEqual(engine.snapshot.phase, .idle); XCTAssertEqual(engine.snapshot.stopCause, .disconnected)
    }
    func testStartCannotMutateWhenJournalWriteFails() {
        journal.failSave = true; XCTAssertThrowsError(try start()); XCTAssertTrue(power.events.isEmpty)
    }
    func testFailureRollbackAllowsSleepAndRetainsDurableRecovery() throws {
        try start(); power.failLowPower = true
        XCTAssertThrowsError(try engine.stop(cause: .user))
        XCTAssertFalse(power.settings.sleepDisabled); XCTAssertNotNil(journal.value)
        XCTAssertEqual(engine.snapshot.phase, .recovering); XCTAssertThrowsError(try start())
        power.failLowPower = false; engine.tick()
        XCTAssertEqual(engine.snapshot.phase, .idle); XCTAssertNil(engine.snapshot.error); XCTAssertNil(journal.value)
    }
    func testFailedSleepPermissionRestorationRemainsVisible() throws {
        try start(); power.failSleepPermission = true
        XCTAssertThrowsError(try engine.stop(cause: .user)); XCTAssertNotNil(journal.value)
        power.failSleepPermission = false; engine.tick(); XCTAssertFalse(power.settings.sleepDisabled)
    }
    func testVerificationPreventsClaimingActive() {
        power.ignoreLowPower = true; XCTAssertThrowsError(try start()); XCTAssertNotEqual(engine.snapshot.phase, .active)
        XCTAssertFalse(power.settings.sleepDisabled)
    }
    func testDaemonRestartRestoresBeforeNewStart() throws {
        try start(); let restarted = SessionEngine(clock: clock, power: power, journal: journal)
        XCTAssertFalse(power.settings.sleepDisabled); XCTAssertEqual(power.settings.lowPower[.battery], 0)
        XCTAssertEqual(restarted.snapshot.phase, .idle); XCTAssertEqual(restarted.snapshot.stopCause, .daemonRestart)
    }
    func testCorruptJournalBlocksNewSessionAndAllowsSleep() {
        journal.corrupt = true; power.settings.sleepDisabled = true
        let restarted = SessionEngine(clock: clock, power: power, journal: journal)
        XCTAssertThrowsError(try restarted.start(duration: 3600, owner: "one")); XCTAssertFalse(power.settings.sleepDisabled)
        XCTAssertEqual(restarted.snapshot.phase, .recovering); XCTAssertNotNil(restarted.snapshot.error)
    }
    func testWakeStopsAndDoesNotResume() throws {
        try start(); engine.wake(); XCTAssertEqual(engine.snapshot.stopCause, .wake)
        engine.tick(); XCTAssertEqual(engine.snapshot.phase, .idle)
    }
    func testThermalRejectsStartAndRequestsSleepOnceAcrossRetriesAndRestart() throws {
        engine.thermal = .serious; XCTAssertThrowsError(try start()); engine.thermal = .nominal
        try start(); journal.failRemove = true; engine.thermal = .critical; engine.tick()
        XCTAssertFalse(power.settings.sleepDisabled); XCTAssertEqual(power.sleepRequests, 1)
        XCTAssertEqual(journal.value?.stopCause, .thermal); XCTAssertEqual(journal.value?.sleepRequested, true)
        engine.wake(); engine.tick(); XCTAssertEqual(power.sleepRequests, 1)
        let restarted = SessionEngine(clock: clock, power: power, journal: journal)
        XCTAssertEqual(power.sleepRequests, 1); journal.failRemove = false; restarted.tick()
        XCTAssertEqual(restarted.snapshot.phase, .idle)
    }
    func testJournalRemovalFailureRetriesWithoutLosingOriginals() throws {
        try start(); journal.failRemove = true; XCTAssertThrowsError(try engine.stop(cause: .user))
        journal.failRemove = false; engine.tick(); XCTAssertNil(journal.value); XCTAssertEqual(engine.snapshot.phase, .idle)
    }
    func testFailedInitialSaveBlocksNewSessionUntilRecovery() {
        journal.failSave = true; XCTAssertThrowsError(try start())
        journal.failSave = false
        XCTAssertThrowsError(try start())
        engine.tick(); XCTAssertEqual(engine.snapshot.phase, .idle)
    }
    func testCorruptJournalCanRecoverAfterOperatorRepair() {
        journal.corrupt = true
        let restarted = SessionEngine(clock: clock, power: power, journal: journal)
        journal.corrupt = false; restarted.tick()
        XCTAssertEqual(restarted.snapshot.phase, .idle); XCTAssertNil(restarted.snapshot.error)
    }

    func testThermalSleepIntentWriteFailureRetriesTheRequest() throws {
        try start(); journal.failSave = true; engine.thermal = .serious; engine.tick()
        XCTAssertFalse(power.settings.sleepDisabled); XCTAssertEqual(power.sleepRequests, 0)
        journal.failSave = false; engine.tick()
        XCTAssertEqual(power.sleepRequests, 1); XCTAssertEqual(engine.snapshot.phase, .idle)
    }
    func testNewSessionCapturesCurrentSourceSettings() throws {
        try start(); try engine.stop(cause: .user)
        power.settings.lowPower = [.battery: 1, .ac: 0]
        try start(); try engine.stop(cause: .user)
        XCTAssertEqual(power.settings.lowPower, [.battery: 1, .ac: 0])
    }

}
