import XCTest
import EveilCore

final class InstallerLifecycleTests: XCTestCase {
    private var fixture: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("LifecycleFixture") }
    private func waitForRelease(_ runner: InstallerLifecycleCommand, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while runner.isBusy && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(runner.isBusy)
    }
    func testLateNativeCallbackRetainsChildLockAndNeverResumesReplacement() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = folder.appendingPathComponent("native.lock").path
        let callbackFile = folder.appendingPathComponent("callback")
        let runner = InstallerLifecycleCommand(); var replacements = 0
        do { _ = try runner.run(executable: fixture, arguments: [lock, "0.8", callbackFile.path], timeout: 2); replacements += 1; XCTFail("Deadline must be reported") }
        catch { XCTAssertTrue(error is UnresolvedNativeOperation) }
        XCTAssertTrue(runner.isBusy); XCTAssertTrue(NativeLifecycleLock.isHeld(path: lock))
        XCTAssertThrowsError(try runner.run(executable: fixture, arguments: [lock, "0.01"]))
        let competing = Process(); competing.executableURL = fixture; competing.arguments = [lock, "0.01"]
        competing.standardOutput = Pipe(); competing.standardError = Pipe(); try competing.run(); competing.waitUntilExit()
        XCTAssertEqual(competing.terminationStatus, 4, "A second CLI must fail before unregister")
        let callbackDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: callbackFile.path) && Date() < callbackDeadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: callbackFile.path))
        XCTAssertTrue(runner.isBusy, "The callback alone does not end the settling interval")
        XCTAssertTrue(NativeLifecycleLock.isHeld(path: lock))
        XCTAssertThrowsError(try runner.run(executable: fixture, arguments: [lock, "0.01"]))
        waitForRelease(runner)
        XCTAssertFalse(NativeLifecycleLock.isHeld(path: lock)); XCTAssertEqual(replacements, 0)
        _ = try runner.run(executable: fixture, arguments: [lock, "0.01"])
        replacements += 1; XCTAssertEqual(replacements, 1, "Only a fresh explicit attempt may continue")
    }
    func testAmbiguousLegacyFailureDoesNotEnableAnotherUnregister() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = InstallerLifecycleCommand()
        XCTAssertThrowsError(try runner.run(executable: fixture, arguments: [folder.appendingPathComponent("native.lock").path, "legacy-error"]))
        XCTAssertTrue(runner.isBusy)
        XCTAssertThrowsError(try runner.run(executable: fixture, arguments: [folder.appendingPathComponent("native.lock").path, "0.01"]))
    }
    func testInstallerDeadlineAlsoRetainsChildAndExcludesRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lock = folder.appendingPathComponent("native.lock").path
        let runner = InstallerLifecycleCommand()
        XCTAssertThrowsError(try runner.run(executable: fixture, arguments: [lock, "0.8"], timeout: 0.1))
        XCTAssertTrue(runner.isBusy)
        XCTAssertThrowsError(try runner.run(executable: fixture, arguments: [lock, "0.01"]))
        waitForRelease(runner)
        XCTAssertFalse(NativeLifecycleLock.isHeld(path: lock))
    }
}
