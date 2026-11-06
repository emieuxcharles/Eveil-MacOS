import AppKit
import ServiceManagement
import EveilIPC

let service = SMAppService.daemon(plistName: ServiceIdentity.plist)
func statusText() -> String {
    switch service.status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notRegistered: return "notRegistered"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
}
let arguments = CommandLine.arguments
if arguments.contains("--status") { print(statusText()); exit(0) }
if arguments.contains("--register") {
    do { try service.register(); print(statusText()); exit(0) }
    catch { fputs("\(error.localizedDescription); status=\(statusText())\n", stderr); exit(1) }
}
if arguments.contains("--unregister") {
    do { try service.unregister(); print(statusText()); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Éveil 2 — Vérification du service"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 18; stack.edgeInsets = NSEdgeInsets(top: 25, left: 25, bottom: 25, right: 25)
        let heading = NSTextField(labelWithString: "Connexion sécurisée au service"); heading.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(heading); stack.addArrangedSubview(message)
        for (title, action) in [("Autoriser le service", #selector(register)), ("Ouvrir les réglages macOS", #selector(settings)), ("Vérifier maintenant", #selector(probe))] {
            stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        window.contentView = stack; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if service.status == .enabled { probe() }
    }
    @objc func register() {
        guard Bundle.main.bundlePath == ServiceIdentity.installedPath else { message.stringValue = "Ouvrez Éveil 2 depuis le dossier Applications."; return }
        do { try service.register(); message.stringValue = "Service enregistré. Vérifiez la connexion."; probe() }
        catch { message.stringValue = service.status == .requiresApproval ? "Autorisez Éveil 2 dans Réglages Système → Général → Ouverture et extensions, puis vérifiez la connexion." : error.localizedDescription }
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
