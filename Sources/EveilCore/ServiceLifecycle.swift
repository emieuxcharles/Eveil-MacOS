import Foundation
import Darwin

public enum RegistrationState: String { case enabled, requiresApproval, notRegistered, notFound, unknown }
public enum ServiceLifecycleState: String { case idle, unregistering, settling, unregistered, registering, waitingForCompletion, enabled, requiresApproval, retryAvailable, failed }

/// Main-queue coordinator. Native adapters must deliver callbacks on that same queue.
/// Apple DTS: https://developer.apple.com/forums/thread/783539 (May 2025).
public final class ServiceLifecycleCoordinator {
    public private(set) var state: ServiceLifecycleState = .idle { didSet { onStateChange?(state) } }
    public var onStateChange: ((ServiceLifecycleState) -> Void)?
    public var isOperationInFlight: Bool { pending != nil }
    private let unregisterOperation: (@escaping (Error?) -> Void) -> Void
    private let registerOperation: (@escaping (Error?) -> Void) -> Void
    private let operationFinished: () -> Void
    private let status: () -> RegistrationState
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    // A result deadline cannot cancel ServiceManagement. Keep exclusion until the real callback.
    private final class Operation {
        var callbackReceived = false
        var completion: ((Result<RegistrationState, Error>) -> Void)?
        init(_ completion: @escaping (Result<RegistrationState, Error>) -> Void) { self.completion = completion }
        func report(_ result: Result<RegistrationState, Error>) {
            let callback = completion; completion = nil; callback?(result)
        }
    }
    private var pending: Operation?
    public init(unregister: @escaping (@escaping (Error?) -> Void) -> Void, register: @escaping (@escaping (Error?) -> Void) -> Void, status: @escaping () -> RegistrationState, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void, operationFinished: @escaping () -> Void = {}) {
        unregisterOperation = unregister; registerOperation = register; self.status = status; self.schedule = schedule; self.operationFinished = operationFinished
    }
    private func begin(_ next: ServiceLifecycleState, completion: @escaping (Result<RegistrationState, Error>) -> Void) -> Operation? {
        guard pending == nil else { completion(.failure(SessionFailure("Une opération macOS est toujours en cours. Attendez sa confirmation avant de réessayer."))); return nil }
        let operation = Operation(completion); pending = operation; state = next; return operation
    }
    private func finish(_ operation: Operation, state next: ServiceLifecycleState, result: Result<RegistrationState, Error>) {
        guard pending === operation else { return }
        pending = nil; operationFinished(); state = next; operation.report(result)
    }
    public func unregister(completion: @escaping (Result<RegistrationState, Error>) -> Void) {
        guard let operation = begin(.unregistering, completion: completion) else { return }
        schedule(30) { [weak self] in
            guard let self, self.pending === operation, !operation.callbackReceived else { return }
            self.state = .waitingForCompletion
            operation.report(.failure(SessionFailure("Le retrait n’a pas été confirmé sous 30 secondes. macOS poursuit l’opération ; aucun remplacement ni nouvel essai autorisé avant sa fin.")))
        }
        unregisterOperation { [weak self] error in
            guard let self, self.pending === operation, !operation.callbackReceived else { return }
            operation.callbackReceived = true // Disarms the callback deadline, including during settling.
            if let error {
                self.finish(operation, state: self.status() == .requiresApproval ? .requiresApproval : .failed, result: .failure(error)); return
            }
            self.state = .settling
            // Empirical two-second workaround from Apple DTS discussion, not an OS guarantee.
            self.schedule(2) { [weak self] in
                guard let self, self.pending === operation else { return }
                let current = self.status()
                guard current == .notRegistered else {
                    self.finish(operation, state: .failed, result: .failure(SessionFailure("Retrait non confirmé : état \(current.rawValue)."))); return
                }
                // If the result already timed out, reconcile only; never auto-register on a late restart.
                self.finish(operation, state: .unregistered, result: .success(current))
            }
        }
    }
    public func register(completion: @escaping (Result<RegistrationState, Error>) -> Void) {
        guard let operation = begin(.registering, completion: completion) else { return }
        schedule(10) { [weak self] in
            guard let self, self.pending === operation, !operation.callbackReceived else { return }
            self.state = .waitingForCompletion
            operation.report(.failure(SessionFailure("L’activation n’a pas été confirmée sous 10 secondes. macOS poursuit l’opération ; attendez sa fin avant de réessayer.")))
        }
        registerOperation { [weak self] error in
            guard let self, self.pending === operation, !operation.callbackReceived else { return }
            operation.callbackReceived = true
            let current = self.status()
            if let error {
                let next: ServiceLifecycleState
                if current == .enabled { next = .enabled }
                else if current == .requiresApproval { next = .requiresApproval }
                else if current == .notRegistered && Self.isPermissionError(error as NSError) { next = .retryAvailable }
                else { next = .failed }
                self.finish(operation, state: next, result: .failure(error)); return
            }
            switch current {
            case .enabled: self.finish(operation, state: .enabled, result: .success(current))
            case .requiresApproval: self.finish(operation, state: .requiresApproval, result: .success(current))
            default: self.finish(operation, state: .failed, result: .failure(SessionFailure("Activation non confirmée : état \(current.rawValue).")))
            }
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
        guard !isOperationInFlight, state == .retryAvailable, status() == .notRegistered else { completion(.failure(SessionFailure("Vérifiez l’état du service avant de réessayer."))); return }
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
