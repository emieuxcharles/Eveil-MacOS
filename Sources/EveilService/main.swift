import Foundation
import EveilIPC
import EveilCore
import os.log
import Darwin
import IOKit.pwr_mgt

private let log = Logger(subsystem: ServiceIdentity.daemon, category: "lifecycle")
final class Coordinator {
    let queue = DispatchQueue(label: "fr.eveil2.session")
    let engine = SessionEngine(clock: SystemSessionClock(), power: PMSetPowerDriver(), journal: SecureSessionJournal())
    private var timer: DispatchSourceTimer?
    func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
    func startMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in guard let self else { return }; self.engine.thermal = self.thermalLevel(); self.engine.tick() }
        timer.resume(); self.timer = timer
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { guard let self else { return }; self.engine.thermal = self.thermalLevel(); self.engine.tick() }
        }
    }
    func perform(_ operation: @escaping (SessionEngine) throws -> Void, reply: @escaping (Data) -> Void) {
        queue.async { [self] in
            engine.thermal = thermalLevel()
            var error: String?
            do { try operation(engine) } catch let failure { error = failure.localizedDescription }
            let response = ServiceReply(accepted: error == nil, snapshot: engine.snapshot, error: error)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
final class Client: NSObject, EveilServiceProtocol {
    let id = UUID().uuidString
    let coordinator: Coordinator
    init(_ coordinator: Coordinator) { self.coordinator = coordinator }
    func ping(_ nonce: String, reply: @escaping (Data) -> Void) {
        guard nonce.utf8.count <= 128 else { reply(Data()); return }
        let proof = ServiceProof(pid: getpid(), euid: geteuid(), nonce: nonce)
        reply((try? JSONEncoder().encode(proof)) ?? Data())
    }
    func status(reply: @escaping (Data) -> Void) { coordinator.perform({ _ in }, reply: reply) }
    func start(_ duration: Int, reply: @escaping (Data) -> Void) { coordinator.perform({ [id] in try $0.start(duration: duration, owner: id) }, reply: reply) }
    func heartbeat(reply: @escaping (Data) -> Void) { coordinator.perform({ [id] in try $0.heartbeat(owner: id) }, reply: reply) }
    func stop(reply: @escaping (Data) -> Void) { coordinator.perform({ try $0.stop(cause: .user) }, reply: reply) }
    func disconnected() { coordinator.queue.async { [coordinator, id] in coordinator.engine.disconnected(owner: id) } }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let coordinator: Coordinator
    init(_ coordinator: Coordinator) { self.coordinator = coordinator }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement(ServiceIdentity.requirement(for: ServiceIdentity.app))
        connection.exportedInterface = NSXPCInterface(with: EveilServiceProtocol.self)
        let client = Client(coordinator); connection.exportedObject = client
        connection.invalidationHandler = { client.disconnected() }
        connection.interruptionHandler = { client.disconnected() }
        connection.resume()
        log.notice("Authenticated client connected: pid \(connection.processIdentifier)")
        return true
    }
}
final class WakeMonitor {
    var notifier: io_object_t = 0
    var port: IONotificationPortRef?
    var connection: io_connect_t = 0
    let coordinator: Coordinator
    init(_ coordinator: Coordinator) {
        self.coordinator = coordinator
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let monitor = Unmanaged<WakeMonitor>.fromOpaque(context).takeUnretainedValue()
            switch message {
            case 0xe0000300: // kIOMessageSystemHasPoweredOn (IOMessage.h)
                monitor.coordinator.queue.async { monitor.coordinator.engine.wake() }
            case 0xe0000280: // kIOMessageSystemWillSleep
                monitor.coordinator.queue.async {
                    monitor.coordinator.engine.wake()
                    IOAllowPowerChange(monitor.connection, Int(bitPattern: argument))
                }
            case 0xe0000270: // kIOMessageCanSystemSleep
                IOAllowPowerChange(monitor.connection, Int(bitPattern: argument))
            default: break
            }
        }, &notifier)
        if let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        else { log.fault("Power notifications unavailable; session start disabled") }
    }
}
guard geteuid() == 0 else { fputs("Ce service doit être lancé par macOS.\n", stderr); exit(1) }
let coordinator = Coordinator()
let wakeMonitor = WakeMonitor(coordinator)
guard wakeMonitor.connection != 0 else { exit(1) }
coordinator.startMonitoring()
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: coordinator.queue)
termination.setEventHandler { try? coordinator.engine.stop(cause: .daemonStopping); exit(0) }; termination.resume()
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: coordinator.queue)
interrupt.setEventHandler { try? coordinator.engine.stop(cause: .daemonStopping); exit(0) }; interrupt.resume()
let listener = NSXPCListener(machServiceName: ServiceIdentity.daemon)
let delegate = ListenerDelegate(coordinator)
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(ServiceIdentity.requirement(for: ServiceIdentity.app))
listener.resume()
log.notice("Daemon ready: pid \(getpid()), euid \(geteuid())")
withExtendedLifetime((listener, delegate, coordinator, wakeMonitor, termination, interrupt)) { RunLoop.current.run() }
