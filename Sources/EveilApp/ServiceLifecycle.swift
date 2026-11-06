import Foundation
import ServiceManagement
import EveilCore

func makeServiceLifecycle(_ service: SMAppService) -> ServiceLifecycleCoordinator {
    ServiceLifecycleCoordinator(unregister: { completion in
        service.unregister { error in DispatchQueue.main.async { completion(error) } }
    }, register: { completion in
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
    }, schedule: { delay, operation in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation) })
}
