import Foundation
import EveilIPC

final class ServiceClient {
    private var connection: NSXPCConnection?
    private var completed = false
    func probe(completion: @escaping (Result<ServiceProof, Error>) -> Void) {
        let nonce = UUID().uuidString
        let connection = NSXPCConnection(machServiceName: ServiceIdentity.daemon, options: .privileged)
        self.connection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: EveilServiceProtocol.self)
        connection.setCodeSigningRequirement(ServiceIdentity.requirement(for: ServiceIdentity.daemon))
        func finish(_ result: Result<ServiceProof, Error>) {
            DispatchQueue.main.async { [self] in
                guard !completed else { return }; completed = true
                connection.invalidate(); self.connection = nil
                completion(result)
            }
        }
        connection.invalidationHandler = { finish(.failure(NSError(domain: "Eveil2", code: 1, userInfo: [NSLocalizedDescriptionKey: "La connexion au service a été interrompue."]))) }
        connection.resume()
        let remote = connection.remoteObjectProxyWithErrorHandler { finish(.failure($0)) } as? EveilServiceProtocol
        remote?.ping(nonce) { data in
            do {
                let proof = try JSONDecoder().decode(ServiceProof.self, from: data)
                guard proof.validates(nonce: nonce) else { throw NSError(domain: "Eveil2", code: 2, userInfo: [NSLocalizedDescriptionKey: "La réponse du service n’est pas valide."]) }
                finish(.success(proof))
            } catch { finish(.failure(error)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            finish(.failure(NSError(domain: "Eveil2", code: 3, userInfo: [NSLocalizedDescriptionKey: "Le service n’a pas répondu sous 5 secondes."])))
        }
    }
}
