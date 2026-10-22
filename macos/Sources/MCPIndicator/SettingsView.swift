import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.refreshInterval) private var refreshInterval = 5
    @AppStorage(PrefKey.showStopped) private var showStopped = true
    @AppStorage(PrefKey.showOrphans) private var showOrphans = true
    @AppStorage(PrefKey.probeRemote) private var probeRemote = false
    @AppStorage(PrefKey.enableNotifications) private var enableNotifications = true
    @AppStorage(PrefKey.showCountInMenuBar) private var showCount = true

    @ViewState private var extraPaths: [String] = Prefs.extraConfigPaths
    @ViewState private var newPath = ""
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginError: String?

    var body: some View {
        Form {
            Section {
                Stepper(value: $refreshInterval, in: 3...60) {
                    LabeledContent("Intervalo de atualização", value: "\(refreshInterval) s")
                }
                Toggle("Mostrar contagem na barra de menus", isOn: $showCount)
                Toggle("Abrir ao iniciar sessão", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin($0) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Geral")
            }

            Section {
                Toggle(isOn: $showStopped) {
                    Text("Mostrar MCP parados")
                    Text("Listar também os que estão na config e não estão em execução")
                }
                Toggle(isOn: $showOrphans) {
                    Text("Mostrar processos órfãos")
                    Text("Processos que parecem MCP mas não estão nos arquivos de config")
                }
                Toggle(isOn: $probeRemote) {
                    Text("Sondar HTTP remoto")
                    Text("Testar também URLs fora de localhost")
                }
                Toggle(isOn: $enableNotifications) {
                    Text("Notificar queda de MCP local")
                    Text("Quando um MCP HTTP/LaunchAgent passa de ok para degradado ou parado")
                }
                .onChange(of: enableNotifications) { if $0 { Monitor.requestNotificationPermission() } }
            } header: {
                Text("Lista e avisos")
            }

            Section {
                ForEach(defaultConfigs, id: \.self) { spec in
                    let path = (Detector.home as NSString).appendingPathComponent(spec.rel)
                    let exists = FileManager.default.fileExists(atPath: path)
                    HStack(spacing: 8) {
                        Image(systemName: exists ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(exists ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.source).font(.system(size: 12, weight: .medium))
                            Text("~/\(spec.rel)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            } header: {
                Text("Arquivos lidos automaticamente")
            }

            Section {
                ForEach(extraPaths, id: \.self) { path in
                    HStack {
                        Text(path)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            extraPaths.removeAll { $0 == path }
                            Prefs.extraConfigPaths = extraPaths
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remover")
                    }
                }
                HStack {
                    TextField("~/caminho/para/mcp.json", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTypedPath)
                    Button("Adicionar", action: addTypedPath)
                        .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Escolher…", action: choosePath)
                }
            } header: {
                Text("Arquivos de configuração extra")
            } footer: {
                Text("JSON com mcpServers, servers ou mcp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private func add(_ raw: String) {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !extraPaths.contains(path) else { return }
        extraPaths.append(path)
        Prefs.extraConfigPaths = extraPaths
    }

    private func addTypedPath() {
        add(newPath)
        newPath = ""
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: Detector.home)
        guard panel.runModal() == .OK else { return }
        let home = Detector.home
        for url in panel.urls {
            let path = url.path
            add(path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Não foi possível alterar: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
