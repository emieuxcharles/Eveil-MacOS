import XCTest
import EveilIPC
import EveilCore
@testable import EveilApp

final class FakeSessionClient: SessionClientProtocol {
    var onDisconnect: ((Error) -> Void)?
    var onSessionUpdate: ((ServiceReply) -> Void)?
    var probeCompletion: ((Result<ServiceProof, Error>) -> Void)?
    var statusCompletion: ((Result<ServiceReply, Error>) -> Void)?
    var startCompletion: ((Result<ServiceReply, Error>) -> Void)?
    var stopCompletion: ((Result<ServiceReply, Error>) -> Void)?
    var startCount = 0
    var stopCount = 0
    var probeCount = 0
    var disconnected = false
    func probe(completion: @escaping (Result<ServiceProof, Error>) -> Void) { probeCount += 1; probeCompletion = completion }
    func status(completion: @escaping (Result<ServiceReply, Error>) -> Void) { statusCompletion = completion }
    func startSession(duration: Int, heartbeats: Bool, completion: @escaping (Result<ServiceReply, Error>) -> Void) { startCount += 1; startCompletion = completion }
    func stopSession(completion: @escaping (Result<ServiceReply, Error>) -> Void) { stopCount += 1; stopCompletion = completion }
    func disconnect() { disconnected = true }
}
final class AppModelTests: XCTestCase {
    private func reply(_ phase: SessionPhase = .idle, accepted: Bool = true, sleep: Bool = false, error: String? = nil) -> ServiceReply {
        ServiceReply(accepted: accepted, snapshot: ServiceSnapshot(phase: phase, sessionID: nil, startedAt: nil, deadline: nil, duration: phase == .active ? 3600 : nil, remainingSeconds: phase == .active ? 3599 : nil, ownerConnected: phase == .active, thermal: .nominal, stopCause: nil, settings: PowerSettings(lowPower: [.battery: 1, .ac: 0], sleepDisabled: sleep), error: error), error: error)
    }
    private func connected() -> (AppModel, FakeSessionClient) {
        let client = FakeSessionClient(); let model = AppModel(client: client, registrationStatus: { .enabled }, isInstalled: { true })
        model.connect(); client.probeCompletion?(.success(ServiceProof(pid: 22, euid: 0, nonce: "test")))
        client.statusCompletion?(.success(reply()))
        XCTAssertTrue(model.canStart)
        return (model, client)
    }
    func testReadyRequiresStatusAfterProbe() {
        let client = FakeSessionClient(); let model = AppModel(client: client, registrationStatus: { .enabled }, isInstalled: { true })
        model.connect(); XCTAssertFalse(model.canStart)
        client.probeCompletion?(.success(ServiceProof(pid: 22, euid: 0, nonce: "test")))
        XCTAssertFalse(model.canStart); XCTAssertFalse(model.connected)
        client.statusCompletion?(.success(reply()))
        XCTAssertTrue(model.connected); XCTAssertTrue(model.canStart)
    }
    func testOneControlAndNoOptimisticActivation() {
        let (model, client) = connected()
        model.start(); model.start(); model.stop()
        XCTAssertEqual(client.startCount, 1); XCTAssertEqual(client.stopCount, 0)
        XCTAssertFalse(model.isActive); XCTAssertEqual(model.pending, .start)
        client.startCompletion?(.success(reply(.active, sleep: true)))
        XCTAssertTrue(model.isActive); XCTAssertFalse(model.busy)
    }
    func testDisconnectInvalidatesLateStartReply() {
        let (model, client) = connected(); model.start()
        client.onDisconnect?(NSError(domain: "lost", code: 1))
        client.startCompletion?(.success(reply(.active, sleep: true)))
        XCTAssertFalse(model.connected); XCTAssertFalse(model.isActive); XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.countdown, "—")
        model.refresh(); XCTAssertEqual(client.probeCount, 1, "No automatic reconnect")
    }
    func testQuitWaitsForVerifiedRestoration() {
        let (model, client) = connected(); var terminated = false
        model.onQuitConfirmed = { terminated = true }; model.requestQuit()
        XCTAssertFalse(terminated)
        client.stopCompletion?(.success(reply(.recovering, accepted: false, error: "restore failed")))
        XCTAssertFalse(terminated); XCTAssertNotNil(model.errorMessage)
        model.requestQuit(); client.stopCompletion?(.success(reply()))
        XCTAssertTrue(terminated); XCTAssertTrue(client.disconnected)
    }
    func testDisconnectReconcilesRevokedApprovalAndPreservesUnknownSnapshot() {
        var registration: RegistrationState = .enabled
        let client = FakeSessionClient()
        let model = AppModel(client: client, registrationStatus: { registration }, isInstalled: { true })
        model.connect(); client.probeCompletion?(.success(ServiceProof(pid: 22, euid: 0, nonce: "test")))
        client.statusCompletion?(.success(reply(.active, sleep: true)))
        registration = .requiresApproval
        client.onDisconnect?(NSError(domain: "revoked", code: 1))
        XCTAssertEqual(model.setup, .approve)
        XCTAssertEqual(model.snapshot?.phase, .active, "Preserve the last known state, without claiming restoration")
        XCTAssertFalse(model.connected); XCTAssertFalse(model.isRestored)
        model.connect()
        XCTAssertEqual(client.probeCount, 1, "An explicit retry must route to approval, not retry unreachable XPC")
        XCTAssertEqual(model.page, .setup)
    }
    func testFailedProbeReconcilesUnregisteredService() {
        var registration: RegistrationState = .enabled
        let client = FakeSessionClient()
        let model = AppModel(client: client, registrationStatus: { registration }, isInstalled: { true })
        model.connect(); registration = .notRegistered
        client.probeCompletion?(.failure(NSError(domain: "removed", code: 1)))
        XCTAssertEqual(model.setup, .authorize)
        model.connect(); XCTAssertEqual(client.probeCount, 1)
        XCTAssertEqual(model.page, .setup)
    }
    func testFailedQuitRoutesToRecoveryInsteadOfReadySetup() {
        let (model, client) = connected()
        model.page = .settings
        var presentedPage: PanelPage?
        model.onNeedAttention = { presentedPage = model.page }
        model.requestQuit()
        client.stopCompletion?(.success(reply(.recovering, accepted: false, error: "restoration failed")))
        XCTAssertEqual(presentedPage, .session)
        XCTAssertEqual(model.page, .session)
        XCTAssertNotEqual(model.setup, .ready)
        XCTAssertFalse(model.canStart); XCTAssertFalse(model.isRestored)
        XCTAssertEqual(model.statusTitle, "Restauration à vérifier")
        model.stop(); XCTAssertEqual(client.stopCount, 2, "Recovery retains an explicit stop/verification action")
        client.stopCompletion?(.success(reply()))
        XCTAssertTrue(model.isRestored); XCTAssertTrue(model.canStart)
    }
    func testConnectionToRecoveringServiceDoesNotOfferSuccessfulSetup() {
        let client = FakeSessionClient()
        let model = AppModel(client: client, registrationStatus: { .enabled }, isInstalled: { true })
        var ready = false; model.onReady = { ready = true }
        model.connect(); client.probeCompletion?(.success(ServiceProof(pid: 22, euid: 0, nonce: "test")))
        client.statusCompletion?(.success(reply(.recovering, error: "pending restore")))
        XCTAssertFalse(ready); XCTAssertNotEqual(model.setup, .ready)
        XCTAssertEqual(model.page, .session); XCTAssertTrue(model.connected)
    }
    func testIdleSleepDisabledOffersRecoveryAndCanThenQuit() {
        let client = FakeSessionClient()
        let model = AppModel(client: client, registrationStatus: { .enabled }, isInstalled: { true })
        model.connect(); client.probeCompletion?(.success(ServiceProof(pid: 22, euid: 0, nonce: "test")))
        client.statusCompletion?(.success(reply(sleep: true)))
        XCTAssertEqual(model.statusTitle, "Restauration à vérifier")
        XCTAssertTrue(model.needsRestoration)
        XCTAssertFalse(model.canStart)
        var terminated = false; model.onQuitConfirmed = { terminated = true }
        model.requestQuit(); XCTAssertEqual(client.stopCount, 1); XCTAssertFalse(terminated)
        client.stopCompletion?(.success(reply()))
        XCTAssertTrue(terminated)
    }
    func testTooltipOnlyClaimsVerifiedRestoration() {
        XCTAssertEqual(AppModel.menuTooltip(snapshot: reply().snapshot, connected: true), "Éveil · veille autorisée")
        XCTAssertEqual(AppModel.menuTooltip(snapshot: reply(sleep: true).snapshot, connected: true), "Éveil · état à vérifier")
        XCTAssertEqual(AppModel.menuTooltip(snapshot: reply(.recovering, sleep: true).snapshot, connected: true), "Éveil · état à vérifier")
        XCTAssertEqual(AppModel.menuTooltip(snapshot: reply(error: "restore failed").snapshot, connected: true), "Éveil · état à vérifier")
    }
    func testIdleWithSleepDisabledIsNotConfirmedRestoration() {
        XCTAssertFalse(AppModel.confirmsRestoration(reply(sleep: true).snapshot))
        XCTAssertFalse(AppModel.confirmsRestoration(reply(error: "journal failure").snapshot))
        XCTAssertFalse(AppModel.confirmsRestoration(nil))
        XCTAssertTrue(AppModel.confirmsRestoration(reply().snapshot))
    }
    func testFixturesCannotControlService() {
        for fixture in UIFixture.allCases {
            let client = FakeSessionClient(); let model = AppModel(fixture: fixture, client: client)
            model.launch(); model.connect(); model.start(); model.stop(); model.register(); model.uninstall(); model.install(); model.requestQuit(); model.approve()
            XCTAssertEqual(client.probeCount, 0); XCTAssertEqual(client.startCount, 0); XCTAssertEqual(client.stopCount, 0)
        }
    }
    func testInstallerUnderstandsExistingCLIAndRejectsUnconfirmedOutput() throws {
        let encoded = try JSONEncoder().encode(reply())
        let output = Data("reply ".utf8) + encoded + Data("\n".utf8)
        let restored = try AppInstaller.decodeStopReply(output)
        XCTAssertTrue(AppModel.confirmsRestoration(restored.snapshot))
        XCTAssertThrowsError(try AppInstaller.decodeStopReply(Data("notRegistered".utf8)))
    }
    func testIncompatibleStatusCannotBecomeReady() {
        let client = FakeSessionClient(); let model = AppModel(client: client, registrationStatus: { .enabled }, isInstalled: { true })
        model.connect(); client.probeCompletion?(.success(ServiceProof(pid: 22, euid: 0, nonce: "test")))
        var snapshot = reply().snapshot; snapshot.protocolVersion = 999
        client.statusCompletion?(.success(ServiceReply(accepted: true, snapshot: snapshot)))
        XCTAssertFalse(model.connected); XCTAssertFalse(model.canStart)
    }
}

final class DelayedHeartbeatService: NSObject, EveilServiceProtocol {
    var delayedHeartbeat: ((Data) -> Void)?
    func encoded(_ active: Bool) -> Data {
        try! JSONEncoder().encode(ServiceReply(accepted: true, snapshot: ServiceSnapshot(phase: active ? .active : .idle, sessionID: nil, startedAt: nil, deadline: nil, duration: active ? 3600 : nil, remainingSeconds: nil, ownerConnected: active, thermal: .nominal, stopCause: nil, settings: PowerSettings(lowPower: [.ac: active ? 1 : 0], sleepDisabled: active), error: nil)))
    }
    func ping(_ nonce: String, reply: @escaping (Data) -> Void) { reply(try! JSONEncoder().encode(ServiceProof(pid: 22, euid: 0, nonce: nonce))) }
    func status(reply: @escaping (Data) -> Void) { reply(encoded(false)) }
    func start(_ duration: Int, reply: @escaping (Data) -> Void) { reply(encoded(true)) }
    func heartbeat(reply: @escaping (Data) -> Void) { delayedHeartbeat = reply }
    func stop(reply: @escaping (Data) -> Void) { reply(encoded(false)) }
}
final class ClientOrderingTests: XCTestCase {
    func testLateActiveHeartbeatCannotReappearAfterStop() {
        let service = DelayedHeartbeatService(); let client = ServiceClient(remoteForTesting: service)
        var updates = 0; client.onSessionUpdate = { _ in updates += 1 }
        let started = expectation(description: "started")
        client.startSession(duration: 3600, heartbeats: false) { _ in started.fulfill() }
        wait(for: [started], timeout: 2)
        let heartbeat = expectation(description: "heartbeat completed")
        client.heartbeat { _ in heartbeat.fulfill() }
        let stopped = expectation(description: "stopped")
        client.stopSession { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        service.delayedHeartbeat?(service.encoded(true))
        wait(for: [heartbeat], timeout: 2)
        XCTAssertFalse(client.ownsSession); XCTAssertEqual(updates, 0)
    }
    func testOldIdleHeartbeatCannotEndNewOwnership() {
        let service = DelayedHeartbeatService(); let client = ServiceClient(remoteForTesting: service)
        let first = expectation(description: "first")
        client.startSession(duration: 3600, heartbeats: false) { _ in first.fulfill() }
        wait(for: [first], timeout: 2)
        let heartbeat = expectation(description: "old heartbeat")
        client.heartbeat { _ in heartbeat.fulfill() }
        let stopped = expectation(description: "stop")
        client.stopSession { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        let second = expectation(description: "second")
        client.startSession(duration: 3600, heartbeats: false) { _ in second.fulfill() }
        wait(for: [second], timeout: 2)
        service.delayedHeartbeat?(service.encoded(false))
        wait(for: [heartbeat], timeout: 2)
        XCTAssertTrue(client.ownsSession)
        client.disconnect()
    }
}
