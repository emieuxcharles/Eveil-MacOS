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

final class Bootstrap: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let message = NSTextField(wrappingLabelWithString: "Vérifiez le service avant de poursuivre la reconstruction.")
    var client: ServiceClient?
    var waitingForNativeResult = false
    let retryButton = NSButton(title: "Réessayer l’activation", target: nil, action: nil)
    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycle.onStateChange = { [weak self] in self?.lifecycleStateChanged($0) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Éveil 2 — Vérification du service"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 18; stack.edgeInsets = NSEdgeInsets(top: 25, left: 25, bottom: 25, right: 25)
        let heading = NSTextField(labelWithString: "Connexion sécurisée au service"); heading.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(heading); stack.addArrangedSubview(message)
        for (title, action) in [("Autoriser le service", #selector(register)), ("Ouvrir les réglages macOS", #selector(settings)), ("Vérifier maintenant", #selector(probe))] {
            stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        retryButton.target = self; retryButton.action = #selector(retryRegistration); retryButton.isHidden = true
        stack.addArrangedSubview(retryButton)
        window.contentView = stack; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if service.status == .enabled { probe() }
    }
    @objc func register() {
        guard Bundle.main.bundlePath == ServiceIdentity.installedPath else { message.stringValue = "Ouvrez Éveil 2 depuis le dossier Applications."; return }
        message.stringValue = "Activation du service…"; retryButton.isHidden = true
        lifecycle.register(completion: showRegistration)
    }
    @objc func retryRegistration() { retryButton.isHidden = true; lifecycle.retryRegistration(completion: showRegistration) }
    func showRegistration(_ result: Result<RegistrationState, Error>) {
        switch result {
        case .success(.enabled): message.stringValue = "Service enregistré. Vérifiez la connexion."; probe()
        case .success(.requiresApproval): message.stringValue = "Autorisez Éveil 2 dans Réglages Système → Général → Ouverture et extensions, puis vérifiez la connexion."
        case .success: message.stringValue = "Le service n’est pas disponible. Vérifiez son état."
        case .failure(let error):
            retryButton.isHidden = lifecycle.state != .retryAvailable
            message.stringValue = lifecycle.state == .requiresApproval ? "Autorisez Éveil 2 dans les réglages macOS." : lifecycle.state == .retryAvailable ? "macOS n’a pas encore terminé la préparation du service. Réessayez l’activation." : error.localizedDescription
        }
    }
    func lifecycleStateChanged(_ state: ServiceLifecycleState) {
        if state == .waitingForCompletion { waitingForNativeResult = true; retryButton.isHidden = true; return }
        guard waitingForNativeResult else { return }
        switch state {
        case .enabled: waitingForNativeResult = false; probe()
        case .requiresApproval:
            waitingForNativeResult = false
            message.stringValue = "Autorisez Éveil 2 dans les réglages macOS."
        case .retryAvailable:
            waitingForNativeResult = false; retryButton.isHidden = false
            message.stringValue = "macOS a terminé sa tentative. Vous pouvez réessayer l’activation."
        case .failed, .unregistered:
            waitingForNativeResult = false
            message.stringValue = "L’opération macOS est terminée. Vérifiez l’état du service avant de poursuivre."
        default: break
        }
    }
    @objc func settings() { SMAppService.openSystemSettingsLoginItems() }
    @objc func probe() {
        message.stringValue = "Connexion en cours…"
        let client = ServiceClient(); self.client = client
        client.probe { [weak self] result in
            switch result {
            case .success(let proof): self?.message.stringValue = "Service opérationnel et authentifié. Processus \(proof.pid), privilèges administrateur."
            case .failure(let error): self?.message.stringValue = "Service indisponible : \(error.localizedDescription)"
            }
            self?.client = nil
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let bootstrap = Bootstrap()
app.delegate = bootstrap
app.setActivationPolicy(.regular)
app.run()
