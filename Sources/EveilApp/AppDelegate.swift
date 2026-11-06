import AppKit
import SwiftUI
import EveilIPC

final class EveilAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var mayTerminate = false
    private var subscriptions: Set<AnyCancellable> = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second GUI must not create a second controlling connection.
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: ServiceIdentity.app).first { $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
        if let other { other.activate(options: [.activateAllWindows]); mayTerminate = true; NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Éveil : ouvrir les commandes")
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "Éveil · veille autorisée"
        popover.behavior = .transient; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.onNeedAttention = { [weak self] in self?.showSetup() }
        model.onReady = { [weak self] in
            guard let self else { return }
            if self.model.page == .setup { self.window?.makeKeyAndOrderFront(nil) }
            else if self.model.page == .session {
                self.window?.orderOut(nil)
                if !self.popover.isShown { self.togglePopover() }
            }
        }
        model.onQuitConfirmed = { [weak self] in self?.mayTerminate = true; NSApp.terminate(nil) }
        model.$snapshot.combineLatest(model.$connected).sink { [weak self] snapshot, connected in
            self?.item?.button?.image = NSImage(systemSymbolName: connected && snapshot?.phase == .active ? "sun.max.fill" : "sun.max", accessibilityDescription: "Éveil : ouvrir les commandes")
            self?.item?.button?.toolTip = connected ? (snapshot?.phase == .active ? "Éveil · session en cours" : "Éveil · veille autorisée") : "Éveil · état à vérifier"
        }.store(in: &subscriptions)
        model.launch()
        if model.setup == .install || model.setup == .authorize || model.setup == .approve { showSetup() }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        model.page = model.setup == .ready || model.snapshot != nil ? .session : .setup
        let view = BoundedPanel(width: 370, maxHeight: max(300, (item.button?.window?.screen?.visibleFrame.height ?? 800) - 50)) {
            EveilRootView(model: self.model, settings: { [weak self] in self?.showSettings() }, back: { [weak self] in self?.returnToSession() })
        }
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func showWindow(page: PanelPage, width: CGFloat) {
        popover.performClose(nil); model.page = page
        let view = BoundedPanel(width: width, maxHeight: max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 100)) {
            EveilRootView(model: self.model, settings: { [weak self] in self?.showSettings() }, back: { [weak self] in self?.returnToSession() })
        }
        let host = FittingHostingView(rootView: view)
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window?.title = "Éveil"; window?.titleVisibility = .hidden; window?.titlebarAppearsTransparent = true; window?.isReleasedWhenClosed = false
        }
        window?.contentView = host
        window?.setContentSize(host.fittingSize)
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showSetup() { showWindow(page: .setup, width: 410) }
    private func showSettings() { showWindow(page: .settings, width: 460) }
    private func returnToSession() { window?.orderOut(nil); model.page = .session; togglePopover() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        model.requestQuit(); return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !popover.isShown { togglePopover() }; return false }
}

import Combine

/// Keeps native setup/settings windows fitted when inline errors or confirmation rows appear.
private final class FittingHostingView<Content: View>: NSHostingView<Content> {
    private var resizeScheduled = false
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !resizeScheduled else { return }; resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.resizeScheduled = false
            guard let window = self.window else { return }
            let desired = self.fittingSize
            if abs(window.contentLayoutRect.height - desired.height) > 1 { window.setContentSize(desired) }
        }
    }
}
