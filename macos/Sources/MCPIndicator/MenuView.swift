import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var monitor: Monitor
    let openSettings: () -> Void
    let quit: () -> Void

    // Até N linhas a lista cresce com o conteúdo; acima disso (ou com logs abertos) rola.
    private let maxPlainRows = 8
    private let maxListHeight: CGFloat = 430

    private var rowList: some View {
        VStack(spacing: 2) {
            ForEach(monitor.rows) { row in
                ServerRowView(row: row)
            }
        }
        .padding(6)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            SummaryBar(summary: monitor.summary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider().opacity(0.6)

            if monitor.rows.isEmpty {
                EmptyStateView(loading: monitor.lastUpdated == nil)
            } else if monitor.rows.count <= maxPlainRows && monitor.logs.isEmpty {
                rowList
            } else {
                ScrollView(.vertical) { rowList }
                    .frame(height: maxListHeight)
            }

            if let error = monitor.errors.first {
                ErrorBanner(text: error, more: monitor.errors.count - 1)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            Divider().opacity(0.6)

            FooterView(openSettings: openSettings, quit: quit)
        }
        .frame(width: 400)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: monitor.rows.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: monitor.logs.keys.sorted())
    }
}

// MARK: - Cabeçalho

private struct HeaderView: View {
    @EnvironmentObject private var monitor: Monitor
    @ViewState private var spin = false

    private var subtitle: String {
        if let flash = monitor.flash { return flash }
        guard let date = monitor.lastUpdated else { return "A procurar servidores MCP…" }
        return "atualizado às \(date.formatted(date: .omitted, time: .standard))"
    }

    private var title: String {
        let n = monitor.summary.running
        if monitor.lastUpdated == nil { return "MCP Indicator" }
        return n == 1 ? "1 MCP em execução" : "\(n) MCP em execução"
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent)
                    .shadow(color: Color.purple.opacity(0.35), radius: 6, y: 2)
                Image(systemName: Theme.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(monitor.flash == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
                    .id(subtitle)
            }
            .animation(.easeInOut(duration: 0.2), value: subtitle)

            Spacer(minLength: 8)

            Button {
                monitor.refresh(manual: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Atualizar agora (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            .onChange(of: monitor.refreshing) { refreshing in
                if refreshing {
                    withAnimation(.linear(duration: 0.8)) { spin.toggle() }
                }
            }
        }
    }
}

private struct SummaryBar: View {
    let summary: Summary

    var body: some View {
        HStack(spacing: 6) {
            chip(.running, summary.running, "ativos")
            chip(.degraded, summary.degraded, "degradados")
            chip(.stopped, summary.stopped, "parados")
            chip(.remote, summary.remote, "remotos")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func chip(_ status: HealthStatus, _ count: Int, _ label: String) -> some View {
        if count > 0 || status == .running {
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(status.color.opacity(0.11)))
            .overlay(Capsule().strokeBorder(status.color.opacity(0.22), lineWidth: 0.5))
        }
    }
}

// MARK: - Linha de servidor

private struct ServerRowView: View {
    @EnvironmentObject private var monitor: Monitor
    let row: Row
    @ViewState private var hovering = false

    private var server: McpServer { row.server }

    private var transportBadge: (String, Color) {
        if server.agent != nil { return ("LAUNCHD", .purple) }
        switch server.transport {
        case .stdio: return ("STDIO", .secondary)
        case .http: return ("HTTP", .blue)
        case .sse: return ("SSE", .teal)
        }
    }

    private var subtitle: String {
        if server.orphan {
            let n = server.pids.count
            return "fora das configs · \(n == 1 ? "1 processo" : "\(n) processos")"
        }
        let sources = server.sources.joined(separator: ", ")
        return "\(sources.isEmpty ? server.transport.rawValue : sources) · \(row.health.reason)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(status: row.health.status)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Detector.displayName(server.name))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Badge(text: transportBadge.0, tint: transportBadge.1)
                        if server.orphan { Badge(text: "ÓRFÃO", tint: .orange) }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                if monitor.busy.contains(server.id) {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                } else {
                    ActionButtons(server: server, status: row.health.status)
                        .opacity(hovering ? 1 : 0.55)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            if let log = monitor.logs[server.id] {
                LogPanel(name: Detector.displayName(server.name), state: log)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.065 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(Detector.commandPreview(server))
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copiar nome") { monitor.copy(server.name, message: "Nome copiado") }
        Button("Copiar comando") { monitor.copy(Detector.commandPreview(server), message: "Comando copiado") }
        if server.url != nil { Button("Copiar URL") { monitor.copyURL(server) } }
        if !server.pids.isEmpty {
            Button("Copiar PIDs") {
                monitor.copy(server.pids.map(String.init).joined(separator: " "), message: "PIDs copiados")
            }
        }
        if !server.configPaths.isEmpty {
            Divider()
            Button("Mostrar config no Finder") { monitor.revealConfig(server) }
        }
        if let agent = server.agent {
            Button("Mostrar LaunchAgent no Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.plistPath)])
            }
        }
    }
}

private struct ActionButtons: View {
    @EnvironmentObject private var monitor: Monitor
    let server: McpServer
    let status: HealthStatus

    var body: some View {
        HStack(spacing: 3) {
            if status == .running || status == .degraded {
                if Control.canDaemonStart(server) {
                    IconButton(symbol: "arrow.triangle.2.circlepath", help: "Reiniciar") { monitor.restart(server) }
                }
                IconButton(symbol: "stop.fill", help: "Parar", tint: .red) { monitor.stop(server) }
            } else if status == .stopped && Control.canDaemonStart(server) {
                IconButton(symbol: "play.fill", help: "Iniciar", tint: .green) { monitor.start(server) }
            }
            if server.agent != nil {
                IconButton(
                    symbol: "text.alignleft",
                    help: "Logs",
                    active: monitor.logs[server.id] != nil
                ) { monitor.toggleLogs(server) }
            }
            if server.url != nil {
                IconButton(symbol: "link", help: "Copiar URL") { monitor.copyURL(server) }
            }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    var active = false
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? tint : Color.primary.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        active ? Color.accentColor.opacity(0.22)
                            : (hovering ? tint.opacity(0.16) : Color.primary.opacity(0.06))
                    )
                )
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct LogPanel: View {
    @EnvironmentObject private var monitor: Monitor
    let name: String
    let state: LogState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Logs · \(name)", systemImage: "doc.plaintext")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.loading && !state.text.isEmpty {
                    Button("Copiar") { monitor.copy(state.text, message: "Logs de \(name) copiados") }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                }
            }
            if state.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    Text(state.lines.isEmpty ? state.text : state.lines.suffix(30).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Estados vazios, erros, rodapé

private struct EmptyStateView: View {
    let loading: Bool

    var body: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.regular)
                Text("A procurar servidores MCP…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Nenhum MCP encontrado")
                    .font(.system(size: 13, weight: .semibold))
                Text("Configure MCP no Cursor, Claude, VS Code ou OpenCode.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}

private struct ErrorBanner: View {
    let text: String
    let more: Int

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            Text(more > 0 ? "\(text) (+\(more))" : text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.yellow.opacity(0.1)))
        .padding(.top, 6)
    }
}

private struct FooterView: View {
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Preferências", symbol: "gearshape", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            FooterButton(title: "Sair", symbol: "power", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
