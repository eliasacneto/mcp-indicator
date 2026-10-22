import AppKit
import Combine
import SwiftUI

/// Conteúdo do botão na barra de menus: glifo template + ponto de estado + contagem.
struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(PrefKey.showCountInMenuBar) private var showCount = true

    private var overall: HealthStatus? {
        if monitor.summary.degraded > 0 { return .degraded }
        if monitor.summary.running > 0 { return .running }
        return nil
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Theme.symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .opacity(overall == nil ? 0.55 : 1)
                // Recorta um anel no glifo à volta do ponto, para ler bem em qualquer cor de barra.
                .mask {
                    Rectangle()
                        .overlay(alignment: .bottomTrailing) {
                            if overall != nil {
                                Circle()
                                    .frame(width: 9, height: 9)
                                    .offset(x: 4, y: 3)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                }
                .overlay(alignment: .bottomTrailing) {
                    if let overall {
                        Circle()
                            .fill(overall.color)
                            .frame(width: 6, height: 6)
                            .offset(x: 2.5, y: 1.5)
                    }
                }
                .padding(.trailing, overall == nil ? 0 : 2)
            if showCount && monitor.summary.running > 0 {
                Text("\(monitor.summary.running)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .fixedSize()
    }
}

/// NSHostingView que deixa os cliques passarem para o NSStatusBarButton.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let monitor: Monitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var label: PassthroughHostingView<MenuBarLabel>!
    private var cancellables = Set<AnyCancellable>()
    private let openSettings: () -> Void

    init(monitor: Monitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.openSettings = openSettings
        super.init()

        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel("MCP Indicator")
        label = PassthroughHostingView(rootView: MenuBarLabel(monitor: monitor))
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        ])
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let content = MenuView(
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                openSettings()
            },
            quit: { NSApp.terminate(nil) }
        ).environmentObject(monitor)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // A largura do item acompanha o conteúdo (contagem aparece/some).
        monitor.$summary
            .combineLatest(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .map { _ in () }.prepend(()))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)
    }

    private func resize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let label = self.label else { return }
            label.invalidateIntrinsicContentSize()
            self.statusItem.length = ceil(label.fittingSize.width) + 4
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        monitor.refresh(manual: true)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Atualizar agora", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Preferências…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair do MCP Indicator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { monitor.refresh(manual: true) }

    @objc private func showSettings() { openSettings() }
}
