import SwiftUI
import AppKit

private let sunAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 1, green: 0.73, blue: 0.28, alpha: 1) : NSColor(red: 0.65, green: 0.36, blue: 0.04, alpha: 1)
})

struct EveilRootView: View {
    @ObservedObject var model: AppModel
    var forceAccessible = false
    var settings: () -> Void = {}
    var back: () -> Void = {}
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sun.max.fill").font(.system(size: 19, weight: .medium)).foregroundStyle(sunAccent).accessibilityHidden(true)
                Text(model.page == .settings ? "Réglages" : "Éveil").font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.page == .session {
                    Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 15)) }.buttonStyle(.borderless).help("Réglages d’Éveil").accessibilityLabel("Ouvrir les réglages")
                } else if model.setup == .ready || model.page == .settings {
                    Button("Retour", action: back).buttonStyle(.borderless).keyboardShortcut(.escape, modifiers: [])
                }
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 17)
            Divider()
            Group {
                switch model.page {
                case .session: SessionView(model: model)
                case .setup: SetupView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            if model.isFixture {
                Text("APERÇU · AUCUNE ACTION SUR LE MAC").font(.system(size: 9, weight: .medium)).tracking(0.6).foregroundStyle(AdaptiveSecondaryStyle()).frame(maxWidth: .infinity).padding(.bottom, 10)
            }
        }
        .background { if reduceTransparency || contrast == .increased || (model.isFixture && forceAccessible) { Color(nsColor: .windowBackgroundColor) } else { Rectangle().fill(.regularMaterial) } }
        .overlay { if contrast == .increased || (model.isFixture && forceAccessible) { Rectangle().stroke(Color.primary.opacity(0.65), lineWidth: 1) } }
        .tint(sunAccent)
        .environment(\.eveilFixtureHighContrast, model.isFixture && forceAccessible)
    }
}

struct SessionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: model.connected ? (model.isActive ? "sun.max.fill" : "moon.zzz") : "exclamationmark.circle")
                        .foregroundStyle(model.isActive && model.connected ? sunAccent : .secondary)
                    Text(model.statusTitle).font(.system(size: 12, weight: .medium))
                }.frame(maxWidth: .infinity)
                Text(model.countdown).font(.system(size: model.countdown == "∞" ? 62 : 47, weight: .light, design: .rounded)).monospacedDigit().tracking(-1.5)
                    .frame(height: 65).contentTransition(.identity).accessibilityLabel(model.countdown == "∞" ? "Durée illimitée" : model.countdown)
                Text(model.countdownCaption).font(.system(size: 12)).foregroundStyle(AdaptiveSecondaryStyle())
            }.padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("Durée").font(.system(size: 12, weight: .medium)).foregroundStyle(AdaptiveSecondaryStyle())
                Picker("Durée de la session", selection: $model.duration) {
                    Text("1 h").tag(3600).accessibilityLabel("Une heure")
                    Text("2 h").tag(7200).accessibilityLabel("Deux heures")
                    Text("3 h").tag(10800).accessibilityLabel("Trois heures")
                    Text("∞").tag(0).accessibilityLabel("Durée illimitée")
                }.pickerStyle(.segmented).labelsHidden().disabled(model.isActive || model.busy)
                if model.isActive { Text("La durée sera modifiable après l’arrêt.").font(.system(size: 11)).foregroundStyle(AdaptiveSecondaryStyle()) }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.pending == .stop || model.pending == .quit ? "Restauration…" : "Maintenir éveillé").font(.system(size: 14, weight: .semibold))
                    Text(model.isActive && model.connected ? "Session en cours" : "Écran libre de s’éteindre").font(.system(size: 11)).foregroundStyle(AdaptiveSecondaryStyle())
                }
                Spacer()
                if model.pending == .start || model.pending == .stop || model.pending == .quit { ProgressView().controlSize(.small).accessibilityLabel(model.pending?.label ?? "Opération en cours") }
                Toggle("Maintenir le Mac éveillé", isOn: Binding(get: { model.isActive && model.connected }, set: { _ in model.toggle() }))
                    .toggleStyle(.switch).labelsHidden().disabled(!model.canToggle).accessibilityValue(model.connected ? (model.isActive ? "Activé" : "Désactivé") : "État inconnu")
            }.padding(13).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                ProtectionRow(symbol: "leaf", title: "Économie d’énergie", detail: model.lowPowerDescription)
                ProtectionRow(symbol: "thermometer.medium", title: "Surveillance thermique", detail: model.thermalDescription)
                ProtectionRow(symbol: "checkmark.shield", title: "Retour à la veille", detail: model.safetyDescription)
            }
            InlineFeedback(model: model)
            if !model.connected || model.needsRestoration {
                Button(model.connected ? "Vérifier la restauration" : "Rétablir la connexion") { if model.connected { model.stop() } else { model.connect() } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(model.busy)
            }
            VentilationNote()
            HStack {
                Text(model.connected ? "Service connecté" : "Service à vérifier").font(.system(size: 10)).foregroundStyle(AdaptiveSecondaryStyle())
                Spacer()
                Button("Quitter Éveil") { model.requestQuit() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.busy).keyboardShortcut("q")
            }
        }.padding(22)
    }
}

struct ProtectionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(AdaptiveSecondaryStyle()).frame(width: 18, height: 19).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(AdaptiveSecondaryStyle()).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}
struct VentilationNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "wind").accessibilityHidden(true)
            Text("Gardez le Mac ventilé. Éveil ne garantit pas sa sécurité dans un sac fermé.").fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).foregroundStyle(AdaptiveSecondaryStyle()).lineSpacing(2)
    }
}
struct InlineFeedback: View {
    @ObservedObject var model: AppModel
    @State private var details = false
    var body: some View {
        if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label { Text(error).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle") }.font(.system(size: 12)).foregroundStyle(.primary)
                DisclosureGroup("Détails techniques", isExpanded: $details) {
                    ScrollView { Text(model.technicalDetail).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100).padding(.top, 4)
                }.font(.system(size: 11)).foregroundStyle(AdaptiveSecondaryStyle())
            }.padding(11).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        } else if let notice = model.notice {
            Label { Text(notice).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "checkmark.circle") }.font(.system(size: 12)).foregroundStyle(AdaptiveSecondaryStyle())
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    private var heading: String {
        switch model.setup {
        case .install: return "Installer Éveil."
        case .authorize: return "Activer le service."
        case .approve: return "Autoriser Éveil."
        case .connect: return "Vérifier la connexion."
        case .ready: return "Éveil est prêt."
        }
    }
    private var explanation: String {
        switch model.setup {
        case .install: return "Installez Éveil dans Applications pour pouvoir maintenir votre Mac éveillé et restaurer ses réglages à l’arrêt."
        case .authorize: return "Éveil utilise un service en arrière-plan pour gérer la veille et restaurer vos réglages, même si l’application se ferme."
        case .approve: return "Dans Réglages Système → Général → Ouverture et extensions, autorisez Éveil en arrière-plan. Revenez ensuite vérifier la connexion."
        case .connect: return "L’autorisation macOS et la connexion sont deux étapes distinctes. Vérifions que le service répond bien."
        case .ready: return "Le service répond et l’état du Mac a été vérifié. Vous pouvez maintenant choisir la durée de votre session."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: model.setup == .ready ? "checkmark.circle" : model.setup == .install ? "arrow.down.app" : model.setup == .approve ? "hand.raised" : "sun.max")
                .font(.system(size: 35, weight: .light)).foregroundStyle(sunAccent).padding(.top, 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(heading).font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                Text(explanation).font(.system(size: 13)).foregroundStyle(AdaptiveSecondaryStyle()).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if model.setup == .install {
                Text("Une version déjà installée sera arrêtée proprement et conservée dans vos sauvegardes.").font(.system(size: 11)).foregroundStyle(AdaptiveSecondaryStyle()).fixedSize(horizontal: false, vertical: true)
            }
            if model.busy {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text(model.pending?.label ?? "macOS termine l’opération…").font(.system(size: 12)) }
            }
            InlineFeedback(model: model)
            VStack(alignment: .leading, spacing: 10) {
                switch model.setup {
                case .install: Button("Installer dans Applications") { model.install() }.buttonStyle(.borderedProminent)
                case .authorize: Button("Activer le service") { model.register() }.buttonStyle(.borderedProminent)
                case .approve:
                    Button("Ouvrir les réglages macOS") { model.approve() }.buttonStyle(.borderedProminent)
                    Button("Vérifier l’autorisation") { model.verifySetup() }.buttonStyle(.borderless)
                case .connect: Button("Vérifier la connexion") { model.connect() }.buttonStyle(.borderedProminent)
                case .ready: Button("Commencer") { model.page = .session; model.onReady?() }.buttonStyle(.borderedProminent)
                }
            }.controlSize(.large).disabled(model.busy)
            Divider()
            VentilationNote()
            HStack {
                Button("Exporter le diagnostic") { model.exportDiagnostics() }.buttonStyle(.borderless).font(.system(size: 11))
                Spacer()
                Button("Quitter") { model.requestQuit() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.busy)
            }
        }.padding(24)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Réglages et protections").font(.system(size: 19, weight: .semibold))
                Text("Vos réglages d’énergie sont restaurés à l’arrêt.").font(.system(size: 12)).foregroundStyle(AdaptiveSecondaryStyle())
            }
            VStack(alignment: .leading, spacing: 15) {
                ProtectionRow(symbol: "leaf", title: "Énergie maîtrisée", detail: "L’économie d’énergie est activée pendant la session. Vos réglages batterie et secteur sont conservés séparément, puis restaurés.")
                ProtectionRow(symbol: "thermometer.medium", title: "Chaleur surveillée", detail: "Si macOS signale une température élevée, Éveil arrête la session et demande la mise en veille.")
                ProtectionRow(symbol: "arrow.counterclockwise", title: "Arrêt sans reprise automatique", detail: "Quitter Éveil, perdre la connexion ou mettre le Mac en veille termine la session. Éveil ne la relance pas au réveil.")
            }
            VentilationNote()
            Divider()
            VStack(spacing: 7) {
                versionRow("Application", value: "Éveil \(model.appVersion)")
                versionRow("Service", value: model.serviceVersion)
                versionRow("Connexion", value: model.connected ? "Vérifiée" : "À vérifier")
            }
            Button("Exporter le diagnostic…") { model.exportDiagnostics() }.controlSize(.regular)
            InlineFeedback(model: model)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Désinstallation").font(.system(size: 12, weight: .semibold))
                Text("Le retrait du service restaure d’abord vos réglages. L’application et ses anciennes versions restent dans vos fichiers.").font(.system(size: 11)).foregroundStyle(AdaptiveSecondaryStyle()).fixedSize(horizontal: false, vertical: true)
                if confirmRemoval {
                    Text("Retirer le service et arrêter la session en cours ?").font(.system(size: 12, weight: .medium))
                    HStack {
                        Button("Annuler") { confirmRemoval = false }
                        Button("Retirer le service", role: .destructive) { confirmRemoval = false; model.uninstall() }.disabled(model.busy)
                    }
                } else {
                    Button("Retirer le service…") { confirmRemoval = true }.disabled(model.busy || model.setup == .install || model.setup == .authorize)
                }
                if model.pending == .uninstall || model.nativeOperationPending { HStack { ProgressView().controlSize(.small); Text("macOS termine le retrait…").font(.system(size: 11)) } }
            }
            HStack {
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "/Applications/Eveil.app")]) }.buttonStyle(.borderless).font(.system(size: 11))
                Spacer()
                Button("Quitter Éveil") { model.requestQuit() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.busy)
            }
        }.padding(24)
    }
    private func versionRow(_ name: String, value: String) -> some View {
        HStack { Text(name).foregroundStyle(AdaptiveSecondaryStyle()); Spacer(); Text(value).textSelection(.enabled) }.font(.system(size: 12))
    }
}


/// Native scrolling preserves access to recovery and Quit on shorter displays.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 620
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
struct BoundedPanel<Content: View>: View {
    var width: CGFloat
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 620
    var body: some View {
        ScrollView(.vertical) {
            content().frame(width: width)
                .background(GeometryReader { proxy in Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: min(contentHeight, maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct FixtureHighContrastKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var eveilFixtureHighContrast: Bool {
        get { self[FixtureHighContrastKey.self] }
        set { self[FixtureHighContrastKey.self] = newValue }
    }
}
private struct AdaptiveSecondaryStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorSchemeContrast == .increased || environment.eveilFixtureHighContrast ? .primary : .secondary
    }
}
