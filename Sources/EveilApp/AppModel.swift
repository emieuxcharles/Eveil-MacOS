import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers
import EveilIPC
import EveilCore

protocol SessionClientProtocol: AnyObject {
    var onDisconnect: ((Error) -> Void)? { get set }
    var onSessionUpdate: ((ServiceReply) -> Void)? { get set }
    func probe(completion: @escaping (Result<ServiceProof, Error>) -> Void)
    func status(completion: @escaping (Result<ServiceReply, Error>) -> Void)
    func startSession(duration: Int, heartbeats: Bool, completion: @escaping (Result<ServiceReply, Error>) -> Void)
    func stopSession(completion: @escaping (Result<ServiceReply, Error>) -> Void)
    func disconnect()
}
extension ServiceClient: SessionClientProtocol {}

enum SetupStep { case install, authorize, approve, connect, ready }
enum PanelPage { case session, settings, setup }
enum PendingAction: String { case connect, start, stop, register, uninstall, quit, install
    var label: String {
        switch self {
        case .connect: return "Connexion au service…"
        case .start: return "Activation en cours…"
        case .stop: return "Restauration en cours…"
        case .register: return "Préparation du service…"
        case .uninstall: return "Retrait du service…"
        case .quit: return "Restauration avant fermeture…"
        case .install: return "Installation dans Applications…"
        }
    }
}

/// Owns one authenticated connection for the lifetime of the menu application.
/// View fixtures never instantiate a client, register a service or mutate power settings.
final class AppModel: ObservableObject {
    @Published var page: PanelPage = .session
    @Published var duration = 3600
    @Published private(set) var snapshot: ServiceSnapshot?
    @Published private(set) var connected = false
    @Published private(set) var pending: PendingAction?
    @Published private(set) var setup: SetupStep = .connect
    @Published private(set) var errorMessage: String?
    @Published private(set) var technicalDetail = ""
    @Published private(set) var notice: String?
    @Published private(set) var now = Date()
    @Published private(set) var serviceVersion = "Non connecté"
    @Published private(set) var nativeOperationPending = false
    let isFixture: Bool
    var onReady: (() -> Void)?
    var onQuitConfirmed: (() -> Void)?
    var onNeedAttention: (() -> Void)?
    private var client: SessionClientProtocol?
    private var clock: Timer?
    private var installerWait: Timer?
    private var refreshCount = 0
    @Published private var refreshInFlight = false
    private var generation = UUID()
    private var receivedAt = Date()
    private var receivedUptime = ProcessInfo.processInfo.systemUptime
    private var pendingLateNativeResult = false
    private var removedService = false
    private let registrationStatus: () -> RegistrationState
    private let isInstalled: () -> Bool
    private let service = SMAppService.daemon(plistName: ServiceIdentity.plist)
    private lazy var lifecycle: ServiceLifecycleCoordinator = {
        let value = makeServiceLifecycle(service)
        value.onStateChange = { [weak self] state in self?.nativeStateChanged(state) }
        return value
    }()
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0" }
    var busy: Bool { pending != nil || nativeOperationPending || refreshInFlight }
    var isActive: Bool { snapshot?.phase == .active }
    var canStart: Bool { connected && setup == .ready && Self.confirmsRestoration(snapshot) && !busy }
    var canToggle: Bool { connected && !busy && (isActive || canStart) }
    var needsRestoration: Bool { connected && !isActive && !isRestored }
    static func menuTooltip(snapshot: ServiceSnapshot?, connected: Bool) -> String {
        guard connected else { return "Éveil · état à vérifier" }
        if snapshot?.phase == .active { return "Éveil · session en cours" }
        return confirmsRestoration(snapshot) ? "Éveil · veille autorisée" : "Éveil · état à vérifier"
    }
    var isRestored: Bool { connected && Self.confirmsRestoration(snapshot) }
    var preferredPage: PanelPage {
        if setup == .install || setup == .authorize || setup == .approve { return .setup }
        return snapshot != nil || setup == .ready ? .session : .setup
    }
    static func confirmsRestoration(_ snapshot: ServiceSnapshot?) -> Bool {
        snapshot?.protocolVersion == 2 && snapshot?.phase == .idle && snapshot?.settings?.sleepDisabled == false && snapshot?.error == nil
    }
    var statusTitle: String {
        if let pending { return pending.label }
        if !connected { return "État à vérifier" }
        if needsRestoration { return "Restauration à vérifier" }
        return isActive ? "Votre Mac reste éveillé" : "Prêt pour votre prochaine session"
    }
    var countdown: String {
        guard connected else { return "—" }
        guard isActive else { return duration == 0 ? "∞" : "\(duration / 3600):00:00" }
        guard let remaining = snapshot?.remainingSeconds else { return "∞" }
        // Continuous time since a verified response; local display is never proof of expiry.
        let seconds = max(0, remaining - Int(max(0, ProcessInfo.processInfo.systemUptime - receivedUptime)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
    var countdownCaption: String {
        if !connected { return "Vérifiez la connexion pour continuer" }
        if isActive { return snapshot?.duration == 0 ? "Jusqu’à votre arrêt" : "Temps restant" }
        return duration == 0 ? "Durée illimitée" : "Durée de la prochaine session"
    }
    var lowPowerDescription: String {
        guard connected, let settings = snapshot?.settings else { return "État non vérifié" }
        let names: [(PowerSource, String)] = [(.battery, "Batterie"), (.ac, "Secteur"), (.ups, "Onduleur")]
        return names.compactMap { source, name in settings.lowPower[source].map { "\(name) : \($0 == 1 ? "activée" : "désactivée")" } }.joined(separator: " · ")
    }
    var thermalDescription: String {
        guard connected, let thermal = snapshot?.thermal else { return "Surveillance non vérifiée" }
        switch thermal {
        case .nominal: return "Température normale"
        case .fair: return "Température légèrement élevée"
        case .serious, .critical: return "Température élevée · arrêt demandé"
        }
    }
    var safetyDescription: String {
        guard connected else { return "Connexion à rétablir" }
        if snapshot?.phase == .recovering { return "Restauration en cours de vérification" }
        return isActive ? "Arrêt automatique si vous quittez l’app" : isRestored ? "Veille autorisée · réglages restaurés" : "Restauration à vérifier"
    }
    private static func currentRegistrationStatus() -> RegistrationState {
        switch SMAppService.daemon(plistName: ServiceIdentity.plist).status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    init(fixture: UIFixture? = nil, client: SessionClientProtocol? = nil,
         registrationStatus: @escaping () -> RegistrationState = { AppModel.currentRegistrationStatus() },
         isInstalled: @escaping () -> Bool = { Bundle.main.bundleURL.standardizedFileURL.path == ServiceIdentity.installedPath }) {
        self.registrationStatus = registrationStatus; self.isInstalled = isInstalled
        isFixture = fixture != nil; self.client = client
        if let fixture { applyFixture(fixture); return }
        if let client { bind(client) }
    }
    private func getClient() -> SessionClientProtocol {
        if let client { return client }
        let next = ServiceClient(); client = next; bind(next); return next
    }
    private func bind(_ client: SessionClientProtocol) {
        client.onDisconnect = { [weak self] error in
            guard let self else { return }
            self.generation = UUID(); self.pending = nil; self.refreshInFlight = false; self.reconcileDisconnectedState()
            self.fail("La connexion a été interrompue. Vérifiez l’état avant de continuer.", error)
        }
        client.onSessionUpdate = { [weak self] reply in
            guard let self, self.connected, self.pending == nil else { return }
            self.accept(reply)
        }
    }
    func launch() {
        guard !isFixture else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date(); self.refreshCount += 1
            if self.refreshCount % 5 == 0, self.connected, !self.busy { self.refresh() }
        }
        refreshSetup()
        if setup == .connect { connect() }
        else if setup != .ready { page = .setup; onNeedAttention?() }
    }
    func refreshSetup() {
        guard !isFixture else { return }
        if !isInstalled() { setup = .install; return }
        switch registrationStatus() {
        case .requiresApproval: setup = .approve
        case .notRegistered, .notFound: setup = .authorize
        case .enabled: setup = connected && (isActive || isRestored) && snapshot?.error == nil && errorMessage == nil ? .ready : .connect
        case .unknown: setup = .connect
        }
    }
    private func reconcileDisconnectedState() {
        connected = false; refreshSetup(); page = preferredPage
    }
    private func requestAttention() {
        page = preferredPage; onNeedAttention?()
    }
    private func begin(_ action: PendingAction) -> UUID? {
        guard !isFixture, !busy else { return nil }
        generation = UUID(); pending = action; errorMessage = nil; technicalDetail = ""; notice = nil
        return generation
    }
    private func current(_ id: UUID) -> Bool { generation == id }
    private func fail(_ message: String, _ error: Error? = nil) {
        errorMessage = message
        technicalDetail = error.map(ServiceLifecycleCoordinator.diagnostic) ?? message
    }
    @discardableResult private func accept(_ reply: ServiceReply) -> Bool {
        guard reply.snapshot.protocolVersion == 2 else {
            connected = false; setup = .connect; fail("Cette version du service n’est pas compatible. Réinstallez Éveil."); return false
        }
        snapshot = reply.snapshot; receivedAt = Date(); receivedUptime = ProcessInfo.processInfo.systemUptime; now = receivedAt
        if let detail = reply.error ?? reply.snapshot.error ?? (!reply.accepted ? "Le service a refusé la demande." : nil) {
            fail("Le service n’a pas confirmé l’opération. Vérifiez la restauration.", SessionFailure(detail))
        }
        if reply.accepted && reply.error == nil && reply.snapshot.error == nil { errorMessage = nil; technicalDetail = "" }
        refreshSetup()
        return reply.accepted
    }
    func connect() {
        guard !isFixture, !busy else { return }
        refreshSetup()
        guard setup == .connect || setup == .ready else { requestAttention(); return }
        guard let id = begin(.connect) else { return }
        let client = getClient()
        client.probe { [weak self] result in
            guard let self, self.current(id) else { return }
            switch result {
            case .failure(let error): self.pending = nil; self.reconcileDisconnectedState(); self.fail("Le service ne répond pas. Vérifiez l’action proposée ci-dessous.", error); self.requestAttention()
            case .success(let proof):
                self.serviceVersion = proof.build
                client.status { [weak self] result in
                    guard let self, self.current(id) else { return }
                    self.pending = nil
                    switch result {
                    case .success(let reply):
                        self.connected = true
                        let accepted = self.accept(reply)
                        if accepted, self.connected, self.setup == .ready { self.removedService = false; self.onReady?() }
                        else { self.requestAttention() }
                    case .failure(let error): self.reconcileDisconnectedState(); self.fail("L’état du Mac n’a pas pu être vérifié.", error); self.requestAttention()
                    }
                }
            }
        }
    }
    func refresh() {
        // Read-only polling never reconnects or renews ownership after a connection loss.
        guard connected, !busy, !isFixture else { return }
        let id = generation; refreshInFlight = true
        getClient().status { [weak self] result in
            guard let self, self.current(id) else { return }
            self.refreshInFlight = false
            switch result {
            case .success(let reply): self.accept(reply)
            case .failure(let error): self.reconcileDisconnectedState(); self.fail("Impossible de vérifier l’état. Vérifiez la connexion du service.", error)
            }
        }
    }
    func toggle() {
        guard canToggle else { return }
        if isActive { stop() } else { start() }
    }
    func start() {
        guard canStart, [0, 3600, 7200, 10800].contains(duration), let id = begin(.start) else { return }
        getClient().startSession(duration: duration, heartbeats: true) { [weak self] result in
            guard let self, self.current(id) else { return }; self.pending = nil
            switch result {
            case .success(let reply): self.accept(reply)
            case .failure(let error): self.reconcileDisconnectedState(); self.fail("L’activation n’est pas confirmée. Vérifiez l’état du service.", error)
            }
        }
    }
    func stop() { restore(for: .stop) { _ in } }
    private func restore(for action: PendingAction, completion: @escaping (Bool) -> Void) {
        guard let id = begin(action) else { completion(false); return }
        getClient().stopSession { [weak self] result in
            guard let self, self.current(id) else { completion(false); return }
            self.pending = nil
            switch result {
            case .success(let reply):
                self.connected = true
                let accepted = self.accept(reply)
                let restored = accepted && self.isRestored
                if restored { self.setup = .ready; self.notice = "Veille autorisée. Réglages d’énergie restaurés." }
                else { self.setup = .connect; self.page = .session; self.fail("La restauration n’est pas confirmée. Éveil reste ouvert pour vous permettre de vérifier.", SessionFailure(reply.error ?? reply.snapshot.error ?? "État reçu : \(reply.snapshot.phase.rawValue)")) }
                completion(restored)
            case .failure(let error): self.reconcileDisconnectedState(); self.fail("La restauration n’est pas confirmée. Vérifiez le service avant de quitter.", error); completion(false)
            }
        }
    }
    func requestQuit() {
        guard !busy, !isFixture else { return }
        // No service was ever reachable, or removal was explicitly confirmed: nothing was started here.
        if removedService || (snapshot == nil && setup == .install) || (snapshot == nil && registrationStatus() != .enabled && setup != .connect) { onQuitConfirmed?(); return }
        restore(for: .quit) { [weak self] confirmed in
            if confirmed { self?.client?.disconnect(); self?.onQuitConfirmed?() }
            else { self?.requestAttention() }
        }
    }
    func register() {
        guard let id = begin(.register) else { return }
        lifecycle.register { [weak self] result in
            guard let self, self.current(id) else { return }
            self.pending = nil; self.nativeOperationPending = self.lifecycle.isOperationInFlight
            self.refreshSetup()
            switch result {
            case .success(.enabled): self.connect()
            case .success(.requiresApproval): self.setup = .approve
            case .success: self.fail("L’activation n’est pas confirmée. Vérifiez l’état du service.")
            case .failure(let error): self.pendingLateNativeResult = self.lifecycle.isOperationInFlight; self.fail("macOS n’a pas confirmé l’activation du service.", error)
            }
        }
    }
    private func nativeStateChanged(_ state: ServiceLifecycleState) {
        nativeOperationPending = lifecycle.isOperationInFlight
        guard pendingLateNativeResult, !nativeOperationPending else { return }
        pendingLateNativeResult = false; refreshSetup()
        if state == .enabled { connect() }
        else if state == .unregistered { completeUninstall() }
    }
    func approve() { guard !isFixture else { return }; SMAppService.openSystemSettingsLoginItems() }
    func verifySetup() { refreshSetup(); if setup == .connect || setup == .ready { connect() } }
    func uninstall() {
        guard !isFixture else { return }
        restore(for: .uninstall) { [weak self] confirmed in
            guard let self, confirmed, let id = self.begin(.uninstall) else { return }
            self.client?.disconnect(); self.connected = false
            self.lifecycle.unregister { [weak self] result in
                guard let self, self.current(id) else { return }; self.pending = nil
                self.nativeOperationPending = self.lifecycle.isOperationInFlight
                switch result {
                case .success(.notRegistered): self.completeUninstall()
                case .success: self.fail("Le retrait du service n’est pas confirmé.")
                case .failure(let error): self.pendingLateNativeResult = self.lifecycle.isOperationInFlight; self.fail("macOS n’a pas confirmé le retrait. L’application reste installée.", error)
                }
            }
        }
    }
    private func completeUninstall() {
        removedService = true; connected = false; snapshot = nil; setup = .authorize
        errorMessage = nil; notice = "Service retiré. Vous pouvez quitter Éveil, puis déplacer l’application dans la Corbeille depuis Applications. Vos anciennes versions sont conservées."
    }
    func install() {
        guard let id = begin(.install) else { return }
        AppInstaller.install { [weak self] result in
            guard let self, self.current(id) else { return }; self.pending = nil
            switch result {
            case .success: self.removedService = true; self.onQuitConfirmed?()
            case .failure(let error):
                self.fail("L’installation n’est pas terminée. L’ancienne version a été conservée.", error)
                if error is UnresolvedNativeOperation || AppInstaller.isUnresolved {
                    self.nativeOperationPending = true
                    self.installerWait?.invalidate()
                    self.installerWait = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                        guard let self else { timer.invalidate(); return }
                        guard !AppInstaller.isUnresolved else { return }
                        timer.invalidate(); self.installerWait = nil; self.nativeOperationPending = false
                        self.errorMessage = "L’opération macOS est terminée. Vous pouvez relancer l’installation."
                    }
                }
            }
        }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Eveil-diagnostic.txt"
        panel.title = "Exporter le diagnostic"; panel.message = "État d’Éveil et derniers détails techniques. Aucun mot de passe n’est inclus."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let encoded = self.snapshot.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "aucun"
            let text = "Éveil \(self.appVersion)\nDate : \(Date().ISO8601Format())\nmacOS : \(ProcessInfo.processInfo.operatingSystemVersionString)\nService : \(self.serviceVersion)\nConnexion vérifiée : \(self.connected)\nOpération macOS en cours : \(self.nativeOperationPending)\nFixture : \(self.isFixture)\nÉtat : \(encoded)\nDétails : \(self.technicalDetail)\n"
            do { try text.write(to: url, atomically: true, encoding: .utf8); self.notice = "Diagnostic enregistré." }
            catch { self.fail("Le diagnostic n’a pas pu être enregistré.", error) }
        }
    }
    deinit { clock?.invalidate(); installerWait?.invalidate() }
}

extension AppModel {
    private func applyFixture(_ fixture: UIFixture) {
        connected = true; setup = .ready; serviceVersion = "2.0.0"
        snapshot = ServiceSnapshot(phase: .idle, sessionID: nil, startedAt: nil, deadline: nil, duration: nil, remainingSeconds: nil, ownerConnected: false, thermal: .nominal, stopCause: nil, settings: PowerSettings(lowPower: [.battery: 1, .ac: 0], sleepDisabled: false), error: nil)
        switch fixture {
        case .idle: break
        case .active, .unlimited:
            duration = fixture == .unlimited ? 0 : 7200
            snapshot?.phase = .active; snapshot?.duration = duration; snapshot?.remainingSeconds = fixture == .unlimited ? nil : 4932
            snapshot?.ownerConnected = true; snapshot?.settings = PowerSettings(lowPower: [.battery: 1, .ac: 1], sleepDisabled: true)
        case .connecting: connected = false; setup = .connect; pending = .connect
        case .approval: connected = false; setup = .approve; page = .setup
        case .error: connected = false; setup = .connect; errorMessage = "La connexion a été interrompue. Vérifiez l’état avant de continuer."; technicalDetail = "Eveil2 : délai de réponse dépassé (10 secondes). Aucune restauration confirmée."
        case .recovery:
            setup = .connect; snapshot?.phase = .recovering; snapshot?.error = "Restauration à confirmer"
            errorMessage = "La restauration n’est pas confirmée. Éveil reste ouvert pour vous permettre de vérifier."
            technicalDetail = "La remise en veille a été demandée ; le service vérifie encore la restauration des réglages."
        case .setup: connected = false; setup = .install; page = .setup
        case .settings: page = .settings
        case .ready: page = .setup
        }
    }
}
