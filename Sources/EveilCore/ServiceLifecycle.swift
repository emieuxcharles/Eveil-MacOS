import Foundation
import Darwin

public enum RegistrationState: String { case enabled, requiresApproval, notRegistered, notFound, unknown }
public enum ServiceLifecycleState: String { case idle, unregistering, settling, unregistered, registering, enabled, requiresApproval, retryAvailable, failed }

/// Main-queue coordinator. Native adapters must deliver callbacks on that same queue.
/// Apple DTS: https://developer.apple.com/forums/thread/783539 (May 2025).
public final class ServiceLifecycleCoordinator {
    public private(set) var state: ServiceLifecycleState = .idle
    private let unregisterOperation: (@escaping (Error?) -> Void) -> Void
    private let registerOperation: (@escaping (Error?) -> Void) -> Void
    private let status: () -> RegistrationState
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0
    public init(unregister: @escaping (@escaping (Error?) -> Void) -> Void, register: @escaping (@escaping (Error?) -> Void) -> Void, status: @escaping () -> RegistrationState, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        unregisterOperation = unregister; registerOperation = register; self.status = status; self.schedule = schedule
    }
    private var busy: Bool { state == .unregistering || state == .settling || state == .registering }
    public func unregister(completion: @escaping (Result<RegistrationState, Error>) -> Void) {
        guard !busy else { completion(.failure(SessionFailure("Une opération sur le service est déjà en cours."))); return }
        generation += 1; let operation = generation; state = .unregistering
        schedule(30) { [weak self] in
            guard let self, self.generation == operation else { return }
            self.generation += 1; self.state = .failed
            completion(.failure(SessionFailure("Le retrait du service n’a pas été confirmé sous 30 secondes. Aucun remplacement autorisé.")))
        }
        unregisterOperation { [weak self] error in
            guard let self, self.generation == operation else { return }
            if let error { self.generation += 1; self.state = .failed; completion(.failure(error)); return }
            self.state = .settling
            // Empirical two-second workaround from Apple DTS discussion, not an OS guarantee.
            self.schedule(2) { [weak self] in
                guard let self, self.generation == operation else { return }
                self.generation += 1; self.state = .unregistered; completion(.success(self.status()))
            }
        }
    }
    public func register(completion: @escaping (Result<RegistrationState, Error>) -> Void) {
        guard !busy else { completion(.failure(SessionFailure("Une opération sur le service est déjà en cours."))); return }
        generation += 1; let operation = generation; state = .registering
        schedule(10) { [weak self] in
            guard let self, self.generation == operation else { return }
            self.generation += 1; self.state = .failed
            completion(.failure(SessionFailure("L’activation du service n’a pas été confirmée sous 10 secondes. Vérifiez son état avant de réessayer.")))
        }
        registerOperation { [weak self] error in
            guard let self, self.generation == operation else { return }
            self.generation += 1
            let current = self.status()
            if let error {
                if current == .requiresApproval { self.state = .requiresApproval }
                else if current == .notRegistered && Self.isPermissionError(error as NSError) { self.state = .retryAvailable }
                else { self.state = .failed }
                completion(.failure(error)); return
            }
            switch current {
            case .enabled: self.state = .enabled
            case .requiresApproval: self.state = .requiresApproval
            default: self.state = .failed
            }
            completion(.success(current))
        }
    }
    public func restart(completion: @escaping (Result<RegistrationState, Error>) -> Void) {
        unregister { [weak self] result in
            switch result {
            case .success: self?.register(completion: completion)
            case .failure: completion(result)
            }
        }
    }
    public func retryRegistration(completion: @escaping (Result<RegistrationState, Error>) -> Void) {
        guard state == .retryAvailable, status() == .notRegistered else { completion(.failure(SessionFailure("Vérifiez l’état du service avant de réessayer."))); return }
        register(completion: completion) // One explicit user action, never an automatic loop.
    }
    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.code == Int(EPERM) && (error.domain == NSPOSIXErrorDomain || error.domain == "SMAppServiceErrorDomain") { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }
    public static func diagnostic(_ error: Error) -> String {
        let error = error as NSError
        return "domain=\(error.domain) code=\(error.code) description=\(error.localizedDescription) userInfo=\(error.userInfo)"
    }
}
