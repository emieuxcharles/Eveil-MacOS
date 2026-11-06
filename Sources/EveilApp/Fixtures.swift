import AppKit
import SwiftUI

enum UIFixture: String, CaseIterable { case idle, active, unlimited, connecting, approval, error, setup, settings, ready }

/// Developer-only renderer: no ServiceClient, launch hook, lifecycle calls or live timers.
enum ViewSnapshots {
    static func render(directory: String) throws {
        let folder = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            for fixture in UIFixture.allCases {
                try render(fixture, dark: dark, accessible: false, folder: folder)
            }
        }
        try render(.active, dark: false, accessible: true, folder: folder)
        try render(.settings, dark: true, accessible: true, folder: folder)
    }
    private static func render(_ fixture: UIFixture, dark: Bool, accessible: Bool, folder: URL) throws {
        let model = AppModel(fixture: fixture)
        let width: CGFloat = fixture == .settings ? 460 : fixture == .setup || fixture == .approval || fixture == .ready ? 410 : 370
        let view = EveilRootView(model: model, forceAccessible: accessible)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: accessible ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance; window.contentView = host; window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "Snapshot", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Snapshot", code: 2) }
        try data.write(to: folder.appendingPathComponent("\(fixture.rawValue)-\(dark ? "dark" : "light")\(accessible ? "-accessible" : "").png"))
        window.orderOut(nil)
    }
}
