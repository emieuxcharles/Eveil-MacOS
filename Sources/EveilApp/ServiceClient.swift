import Foundation
import EveilIPC

/// Main-queue client. Ownership is never re-acquired on reconnect.
final class ServiceClient {
    #if DEBUG
    private var remoteForTesting: EveilServiceProtocol?
    init(remoteForTesting: EveilServiceProtocol? = nil) { self.remoteForTesting = remoteForTesting }
    #endif
    private var connection: NSXPCConnection?
    private var pending: [UUID: (Result<Data, Error>) -> Void] = [:]
    private var heartbeatTimer: Timer?
    private var ownershipRevision: UInt64 = 0
    private(set) var ownsSession = false
    var onDisconnect: ((Error) -> Void)?
    var onSessionUpdate: ((ServiceReply) -> Void)?
    private func failure(_ message: String) -> NSError { NSError(domain: "Eveil2", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let next = NSXPCConnection(machServiceName: ServiceIdentity.daemon, options: .privileged)
        next.remoteObjectInterface = NSXPCInterface(with: EveilServiceProtocol.self)
        next.setCodeSigningRequirement(ServiceIdentity.requirement(for: ServiceIdentity.daemon))
        let lost = { [weak self, weak next] in DispatchQueue.main.async {
            guard let self, let next, self.connection === next else { return }
            self.ownershipRevision &+= 1
            self.connection = nil; self.heartbeatTimer?.invalidate(); self.heartbeatTimer = nil; self.ownsSession = false
            let error = self.failure("La connexion au service a été interrompue.")
            let callbacks = Array(self.pending.values); self.pending.removeAll(); callbacks.forEach { $0(.failure(error)) }
            self.onDisconnect?(error)
        } }
        next.invalidationHandler = lost; next.interruptionHandler = lost
        connection = next; next.resume(); return next
    }
    private func request<T: Decodable>(_ type: T.Type, invoke: @escaping (EveilServiceProtocol, @escaping (Data) -> Void) -> Void, completion: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.main.async { [self] in
            let id = UUID()
            pending[id] = { result in completion(result.flatMap { data in Result { try JSONDecoder().decode(T.self, from: data) } }) }
            func finish(_ result: Result<Data, Error>) { DispatchQueue.main.async { [weak self] in self?.pending.removeValue(forKey: id)?(result) } }
            #if DEBUG
            if let remoteForTesting { invoke(remoteForTesting) { finish(.success($0)) }; return }
            #endif
            let connection = connect()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) }) as? EveilServiceProtocol else { finish(.failure(failure("Service indisponible."))); return }
            invoke(remote) { finish(.success($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.pending[id] != nil else { return }
                self.pending.removeValue(forKey: id)?(.failure(self.failure("Le service n’a pas répondu sous 10 secondes.")))
                // Unknown start outcome must close ownership so the daemon restores.
                self.disconnect()
            }
        }
    }
    func probe(completion: @escaping (Result<ServiceProof, Error>) -> Void) {
        let nonce = UUID().uuidString
        request(ServiceProof.self, invoke: { $0.ping(nonce, reply: $1) }) { [self] result in
            completion(result.flatMap { proof in proof.validates(nonce: nonce) ? .success(proof) : .failure(failure("La réponse du service n’est pas valide.")) })
        }
    }
    func status(completion: @escaping (Result<ServiceReply, Error>) -> Void) { request(ServiceReply.self, invoke: { $0.status(reply: $1) }, completion: completion) }
    func startSession(duration: Int, heartbeats: Bool = true, completion: @escaping (Result<ServiceReply, Error>) -> Void) {
        ownershipRevision &+= 1
        let revision = ownershipRevision
        request(ServiceReply.self, invoke: { $0.start(duration, reply: $1) }) { [weak self] result in
            if self?.ownershipRevision == revision, case .success(let reply) = result, reply.accepted, reply.snapshot.phase == .active {
                self?.ownsSession = true
                if heartbeats { self?.beginHeartbeats() }
            }
            completion(result)
        }
    }
    private func beginHeartbeats() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.heartbeat { _ in } }
    }
    func heartbeat(completion: @escaping (Result<ServiceReply, Error>) -> Void) {
        let revision = ownershipRevision
        request(ServiceReply.self, invoke: { $0.heartbeat(reply: $1) }) { [weak self] result in
            if self?.ownershipRevision == revision, case .success(let reply) = result {
                if !reply.accepted || reply.snapshot.phase != .active { self?.heartbeatTimer?.invalidate(); self?.heartbeatTimer = nil; self?.ownsSession = false }
                self?.onSessionUpdate?(reply)
            }
            completion(result)
        }
    }
    func stopSession(completion: @escaping (Result<ServiceReply, Error>) -> Void) {
        ownershipRevision &+= 1
        heartbeatTimer?.invalidate(); heartbeatTimer = nil; ownsSession = false
        request(ServiceReply.self, invoke: { $0.stop(reply: $1) }, completion: completion)
    }
    func disconnect() {
        ownershipRevision &+= 1
        heartbeatTimer?.invalidate(); heartbeatTimer = nil; ownsSession = false
        let current = connection; connection = nil; current?.invalidate()
        let callbacks = Array(pending.values); pending.removeAll()
        callbacks.forEach { $0(.failure(failure("Connexion fermée."))) }
    }
    deinit { heartbeatTimer?.invalidate(); connection?.invalidate() }
}
