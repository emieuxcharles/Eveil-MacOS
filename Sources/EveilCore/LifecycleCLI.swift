import Foundation
import Darwin

/// User-level exclusion for a live native lifecycle owner, including a timed-out CLI.
public final class NativeLifecycleLock {
    private var descriptor: Int32 = -1
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Éveil/native-lifecycle.lock").path
    }
    public init(path: String = NativeLifecycleLock.defaultPath) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SessionFailure("Impossible de vérifier l’opération macOS en cours.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SessionFailure("Une opération macOS est toujours en cours. Attendez sa confirmation avant de réessayer.") }
        descriptor = fd
    }
    public static func isHeld(path: String = NativeLifecycleLock.defaultPath) -> Bool {
        do { let probe = try NativeLifecycleLock(path: path); probe.release(); return false } catch { return true }
    }
    public func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}

/// A deadline reports uncertainty; only the real callback plus coordinator settling permits exit.
public final class LifecycleCLIResult {
    public static let pendingMarker = "EVEIL_NATIVE_PENDING"
    public static let settledMarker = "EVEIL_NATIVE_SETTLED"
    private let coordinator: ServiceLifecycleCoordinator
    private let expected: RegistrationState
    private let emit: (String) -> Void
    private let terminate: (Int32) -> Void
    private var timedOut = false
    public init(coordinator: ServiceLifecycleCoordinator, expected: RegistrationState, emit: @escaping (String) -> Void, terminate: @escaping (Int32) -> Void) {
        self.coordinator = coordinator; self.expected = expected; self.emit = emit; self.terminate = terminate
        coordinator.onStateChange = { [weak self] _ in
            guard let self, self.timedOut, !self.coordinator.isOperationInFlight else { return }
            self.emit(Self.settledMarker)
            // Never report success or continue a replacement after an already-reported deadline.
            self.terminate(3)
        }
    }
    public func complete(_ result: Result<RegistrationState, Error>) {
        switch result {
        case .success(let state): emit(Self.settledMarker); emit(state.rawValue); terminate(state == expected ? 0 : 2)
        case .failure(let error):
            emit(ServiceLifecycleCoordinator.diagnostic(error))
            if coordinator.isOperationInFlight { timedOut = true; emit(Self.pendingMarker) }
            else { emit(Self.settledMarker); terminate(1) }
        }
    }
}
