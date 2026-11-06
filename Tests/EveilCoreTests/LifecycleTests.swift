import XCTest
@testable import EveilCore

final class LifecycleTests: XCTestCase {
    var now = 0.0
    var scheduled: [(Double, () -> Void)] = []
    var unregisterCompletion: ((Error?) -> Void)?
    var unregistrations = 0
    var deferredRegistration = false
    var registrationCompletion: ((Error?) -> Void)?
    var registrations = 0
    var registrationError: Error?
    var registrationStatus: RegistrationState = .notRegistered
    func makeCoordinator() -> ServiceLifecycleCoordinator {
        ServiceLifecycleCoordinator(unregister: { self.unregistrations += 1; self.unregisterCompletion = $0 }, register: { completion in
            self.registrations += 1
            if self.deferredRegistration { self.registrationCompletion = completion; return }
            if let error = self.registrationError { completion(error); return }
            self.registrationStatus = .enabled; completion(nil)
        }, status: { self.registrationStatus }, schedule: { delay, operation in self.scheduled.append((self.now + delay, operation)) })
    }
    func advance(_ seconds: Double) {
        now += seconds
        while let index = scheduled.indices.filter({ scheduled[$0].0 <= now }).min(by: { scheduled[$0].0 < scheduled[$1].0 }) {
            let operation = scheduled.remove(at: index).1; operation()
        }
    }
    func testRestartWaitsTwoSecondsAfterCompletionAndRegistersOnce() {
        let coordinator = makeCoordinator(); var completed = false
        coordinator.restart { result in if case .failure(let error) = result { XCTFail("\(error)") }; completed = true }
        XCTAssertEqual(registrations, 0); advance(1); unregisterCompletion?(nil)
        advance(1.9); XCTAssertFalse(completed); XCTAssertEqual(registrations, 0)
        advance(0.1); XCTAssertTrue(completed); XCTAssertEqual(registrations, 1)
        advance(60); XCTAssertEqual(registrations, 1)
    }
    func testUnregisterErrorDoesNotRegister() {
        let coordinator = makeCoordinator(); coordinator.restart { if case .success = $0 { XCTFail("Expected failure") } }
        unregisterCompletion?(NSError(domain: NSCocoaErrorDomain, code: 1)); advance(60)
        XCTAssertEqual(registrations, 0)
    }
    func testUnregisterTimeoutRetainsLockUntilLateCompletionAndSettling() {
        let coordinator = makeCoordinator(); var replies = 0
        coordinator.restart { result in if case .success = result { XCTFail("Expected timeout") }; replies += 1 }
        advance(30); XCTAssertEqual(replies, 1)
        coordinator.register { if case .success = $0 { XCTFail("Overlapping register accepted") } }
        coordinator.unregister { if case .success = $0 { XCTFail("Overlapping unregister accepted") } }
        XCTAssertEqual(registrations, 0); XCTAssertEqual(unregistrations, 1)
        unregisterCompletion?(nil); advance(1)
        coordinator.register { if case .success = $0 { XCTFail("Register before settling accepted") } }
        XCTAssertEqual(registrations, 0); advance(1)
        XCTAssertEqual(replies, 1); XCTAssertEqual(coordinator.state, .unregistered)
        XCTAssertEqual(registrations, 0) // A late restart result must not auto-register.
        coordinator.register { if case .failure(let error) = $0 { XCTFail("\(error)") } }
        XCTAssertEqual(registrations, 1)
    }
    func testRegistrationTimeoutRetainsLockAndReconcilesLateSuccessOnce() {
        deferredRegistration = true
        let coordinator = makeCoordinator(); var replies = 0
        coordinator.register { result in if case .success = result { XCTFail("Expected timeout") }; replies += 1 }
        advance(10); XCTAssertEqual(replies, 1)
        coordinator.register { if case .success = $0 { XCTFail("Overlapping register accepted") } }
        coordinator.unregister { if case .success = $0 { XCTFail("Overlapping unregister accepted") } }
        XCTAssertEqual(registrations, 1); XCTAssertEqual(unregistrations, 0)
        registrationStatus = .enabled; registrationCompletion?(nil)
        XCTAssertEqual(coordinator.state, .enabled); XCTAssertEqual(replies, 1)
        registrationCompletion?(nil); advance(60); XCTAssertEqual(replies, 1)
        coordinator.unregister { _ in }; XCTAssertEqual(unregistrations, 1)
    }
    func testRegistrationTimeoutReconcilesLateFailureForExplicitRetry() {
        deferredRegistration = true
        let coordinator = makeCoordinator(); var replies = 0
        coordinator.register { _ in replies += 1 }; advance(10)
        registrationCompletion?(NSError(domain: NSPOSIXErrorDomain, code: 1))
        XCTAssertEqual(coordinator.state, .retryAvailable); XCTAssertEqual(replies, 1)
        deferredRegistration = false
        coordinator.retryRegistration { if case .failure(let error) = $0 { XCTFail("\(error)") } }
        XCTAssertEqual(registrations, 2)
    }
    func testSuccessfulUnregisterAt29SecondsGetsFullSettlingInterval() {
        let coordinator = makeCoordinator(); var replies = 0
        coordinator.restart { result in if case .failure(let error) = result { XCTFail("\(error)") }; replies += 1 }
        advance(29); unregisterCompletion?(nil); advance(1)
        XCTAssertEqual(replies, 0); XCTAssertEqual(registrations, 0); XCTAssertEqual(coordinator.state, .settling)
        advance(1); XCTAssertEqual(replies, 1); XCTAssertEqual(registrations, 1)
    }
    func testNilErrorRegistrationWithoutEnabledStateIsFailure() {
        deferredRegistration = true
        let coordinator = makeCoordinator(); var failed = false
        coordinator.register { if case .failure = $0 { failed = true } }
        registrationCompletion?(nil)
        XCTAssertTrue(failed); XCTAssertEqual(coordinator.state, .failed)
    }
    func testUnregisterStillEnabledAfterSettlingIsFailure() {
        registrationStatus = .enabled
        let coordinator = makeCoordinator(); var failed = false
        coordinator.unregister { if case .failure = $0 { failed = true } }
        unregisterCompletion?(nil); advance(2)
        XCTAssertTrue(failed); XCTAssertEqual(coordinator.state, .failed)
    }
    func testPermissionErrorOffersExplicitRetryWithoutLoop() {
        let coordinator = makeCoordinator(); registrationError = NSError(domain: NSPOSIXErrorDomain, code: 1)
        coordinator.register { if case .success = $0 { XCTFail("Expected failure") } }
        XCTAssertEqual(coordinator.state, .retryAvailable); advance(60); XCTAssertEqual(registrations, 1)
        registrationError = nil; coordinator.retryRegistration { if case .failure(let error) = $0 { XCTFail("\(error)") } }
        XCTAssertEqual(registrations, 2); XCTAssertEqual(coordinator.state, .enabled)
    }
    func testRequiresApprovalNeverOffersPermissionRetry() {
        let coordinator = makeCoordinator(); registrationStatus = .requiresApproval
        registrationError = NSError(domain: NSPOSIXErrorDomain, code: 1)
        coordinator.register { if case .success = $0 { XCTFail("Expected failure") } }
        XCTAssertEqual(coordinator.state, .requiresApproval); advance(60); XCTAssertEqual(registrations, 1)
    }
}
