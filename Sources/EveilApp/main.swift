import AppKit
import ServiceManagement
import EveilIPC
import EveilCore

let service = SMAppService.daemon(plistName: ServiceIdentity.plist)
let lifecycle = makeServiceLifecycle(service)
func statusText() -> String {
    switch service.status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notRegistered: return "notRegistered"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
}
if runSessionCLI() { exit(0) }
let arguments = CommandLine.arguments
if arguments.contains("--status") { print(statusText()); exit(0) }
if arguments.contains("--register") || arguments.contains("--unregister") || arguments.contains("--restart-service") {
    let completion: (Result<RegistrationState, Error>) -> Void = { result in
        switch result {
        case .success(let state):
            let expected: RegistrationState = arguments.contains("--unregister") ? .notRegistered : .enabled
            print(state.rawValue); exit(state == expected ? 0 : 2)
        case .failure(let error):
            fputs("\(ServiceLifecycleCoordinator.diagnostic(error)); status=\(statusText()); lifecycle=\(lifecycle.state.rawValue)\n", stderr)
            if lifecycle.state == .retryAvailable { fputs("Le service n’est pas encore prêt. Réessayez explicitement l’activation dans quelques secondes.\n", stderr) }
            exit(1)
        }
    }
    if arguments.contains("--restart-service") { lifecycle.restart(completion: completion) }
    else if arguments.contains("--unregister") { lifecycle.unregister(completion: completion) }
    else { lifecycle.register(completion: completion) }
    RunLoop.main.run(); exit(1)
}
if arguments.contains("--probe") {
    let client = ServiceClient()
    client.probe { result in
        switch result {
        case .success(let proof): print(String(data: try! JSONEncoder().encode(proof), encoding: .utf8)!); exit(0)
        case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }
    withExtendedLifetime(client) { RunLoop.main.run() }
    exit(1)
}

let app = NSApplication.shared
if arguments.contains("--ui-state") {
    app.setActivationPolicy(.prohibited)
    UIDiagnostics.request { result in
        switch result {
        case .success(let data): print(String(decoding: data, as: UTF8.self)); exit(0)
        case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }
    RunLoop.main.run(); exit(1)
}
if arguments.contains("--install-app") {
    app.setActivationPolicy(.accessory)
    AppInstaller.install { result in
        switch result {
        case .success: print("installed"); exit(0)
        case .failure(let error): fputs("\(ServiceLifecycleCoordinator.diagnostic(error))\n", stderr); exit(1)
        }
    }
    RunLoop.main.run(); exit(1)
}
if let index = arguments.firstIndex(of: "--render-snapshots"), arguments.indices.contains(index + 1) {
    app.setActivationPolicy(.prohibited)
    do { try ViewSnapshots.render(directory: arguments[index + 1]); exit(0) }
    catch { fputs("Snapshots: \(error)\n", stderr); exit(1) }
}
let delegate = EveilAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
