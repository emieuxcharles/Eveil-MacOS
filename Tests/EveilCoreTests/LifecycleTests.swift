import XCTest
@testable import EveilCore

final class LifecycleTests: XCTestCase {
    var now = 0.0
    var scheduled: [(Double, () -> Void)] = []
    var unregisterCompletion: ((Error?) -> Void)?
    var registrations = 0
    var registrationError: Error?
    var registrationStatus: RegistrationState = .notRegistered
    func makeCoordinator() -> ServiceLifecycleCoordinator {
        ServiceLifecycleCoordinator(unregister: { self.unregisterCompletion = $0 }, register: { completion in
            self.registrations += 1
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
    func testUnregisterTimeoutIgnoresLateCompletion() {
        let coordinator = makeCoordinator(); coordinator.restart { if case .success = $0 { XCTFail("Expected failure") } }
        advance(30); unregisterCompletion?(nil); advance(60)
        XCTAssertEqual(registrations, 0); XCTAssertEqual(coordinator.state, .failed)
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
