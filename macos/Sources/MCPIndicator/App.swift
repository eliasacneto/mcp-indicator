import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let monitor: Monitor
    private var statusBar: StatusBarController?
    private var settingsWindow: NSWindow?

    override init() {
        Prefs.register()
        monitor = Monitor()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(monitor: monitor) { [weak self] in self?.showSettings() }
        monitor.start()

        if Monitor.notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
            if Prefs.enableNotifications { Monitor.requestNotificationPermission() }
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Preferências do MCP Indicator"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
enum MCPIndicatorApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            dump()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// `MCPIndicator --snapshot <pasta>`: renderiza popover e ícone (claro/escuro) para PNG, sem tocar no ecrã.
    @MainActor
    private static func snapshot(to dir: String) {
        Prefs.register()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let monitor = Monitor()
        monitor.start()
        let deadline = Date().addingTimeInterval(10)
        while monitor.lastUpdated == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        func render<V: View>(_ view: V, name: String, dark: Bool, background: NSColor) {
            let host = NSHostingView(rootView: view.environmentObject(monitor))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = host.appearance
            window.backgroundColor = background
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            rep.size = size
            // Pinta o fundo à mão: o cache não inclui o fundo da janela.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            host.appearance?.performAsCurrentDrawingAppearance {
                background.setFill()
                NSRect(origin: .zero, size: size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            render(
                MenuView(openSettings: {}, quit: {}),
                name: "popover",
                dark: dark,
                background: .windowBackgroundColor
            )
            render(
                MenuBarLabel(monitor: monitor).padding(.horizontal, 10).frame(height: 24),
                name: "menubar",
                dark: dark,
                background: dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            )
        }
    }

    /// `MCPIndicator --dump`: imprime a varredura no terminal (útil para depurar heurísticas).
    @MainActor
    private static func dump() {
        Prefs.register()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var snap = Detector.scan(extraPaths: Prefs.extraConfigPaths)
            let agents = Launchd.loadUserAgents()
            snap.servers = await Launchd.attach(snap.servers, agents: agents)
            snap.orphans = await Launchd.attach(snap.orphans, agents: agents)
            snap.servers = await HealthCheck.probe(snap.servers, probeRemote: Prefs.probeRemote)
            for server in snap.servers + snap.orphans {
                let health = HealthCheck.classify(server)
                let pids = server.pids.map(String.init).joined(separator: ",")
                print("[\(health.status.rawValue)] \(server.name)  \(server.sources.joined(separator: ", "))"
                    + "  · \(health.reason)  · \(Detector.commandPreview(server))"
                    + (server.agent.map { "  · launchd:\($0.label)" } ?? "")
                    + (pids.isEmpty ? "" : "  · pids \(pids)"))
            }
            for error in snap.errors { print("! \(error)") }
            done.signal()
        }
        done.wait()
    }
}
