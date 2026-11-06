import Foundation
import EveilIPC
import os.log
import Darwin

private let log = Logger(subsystem: ServiceIdentity.daemon, category: "lifecycle")
final class Client: NSObject, EveilServiceProtocol {
    func ping(_ nonce: String, reply: @escaping (Data) -> Void) {
        guard nonce.utf8.count <= 128 else { reply(Data()); return }
        let proof = ServiceProof(pid: getpid(), euid: geteuid(), nonce: nonce)
        reply((try? JSONEncoder().encode(proof)) ?? Data())
    }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement(ServiceIdentity.requirement(for: ServiceIdentity.app))
        connection.exportedInterface = NSXPCInterface(with: EveilServiceProtocol.self)
        connection.exportedObject = Client()
        connection.resume()
        log.notice("Authenticated client connected: pid \(connection.processIdentifier)")
        return true
    }
}
guard geteuid() == 0 else {
    fputs("Ce service doit être lancé par macOS.\n", stderr); exit(1)
}
let listener = NSXPCListener(machServiceName: ServiceIdentity.daemon)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(ServiceIdentity.requirement(for: ServiceIdentity.app))
listener.resume()
log.notice("Daemon ready: pid \(getpid()), euid \(geteuid())")
withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
