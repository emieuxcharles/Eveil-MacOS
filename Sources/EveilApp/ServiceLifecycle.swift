import Foundation
import ServiceManagement
import EveilCore

func makeServiceLifecycle(_ service: SMAppService, externallyLocked: Bool = false) -> ServiceLifecycleCoordinator {
    var operationLock: NativeLifecycleLock?
    func acquire() throws { if !externallyLocked { operationLock = try NativeLifecycleLock() } }
    return ServiceLifecycleCoordinator(unregister: { completion in
        do { try acquire() } catch { completion(error); return }
        service.unregister { error in DispatchQueue.main.async { completion(error) } }
    }, register: { completion in
        do { try acquire() } catch { completion(error); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let error: Error?
            do { try service.register(); error = nil } catch let failure { error = failure }
            DispatchQueue.main.async { completion(error) }
        }
    }, status: {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }, schedule: { delay, operation in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation) }, operationFinished: { operationLock?.release(); operationLock = nil })
}
