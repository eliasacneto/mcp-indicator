import AppKit
import Combine
import Foundation
import UserNotifications

struct Row: Identifiable, Equatable {
    let server: McpServer
    let health: Health

    var id: String { server.id }

    static func == (lhs: Row, rhs: Row) -> Bool {
        lhs.id == rhs.id && lhs.health == rhs.health && lhs.server.sources == rhs.server.sources
            && lhs.server.pids == rhs.server.pids
    }
}

struct Summary: Equatable {
    var running = 0
    var degraded = 0
    var stopped = 0
    var remote = 0

    var total: Int { running + degraded + stopped + remote }
}

struct LogState: Equatable {
    var loading = true
    var lines: [String] = []
    var text = ""
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var rows: [Row] = []
    @Published private(set) var summary = Summary()
    @Published private(set) var errors: [String] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var logs: [String: LogState] = [:]
    @Published private(set) var flash: String?

    private var snapshot = Snapshot()
    private var savedArgv: [String: [String]] = [:]
    private var healthById: [String: HealthStatus] = [:]
    private var timer: Timer?
    private var flashTask: Task<Void, Never>?
    private var defaultsObserver: AnyCancellable?
    private var lastInterval = 0
    private var lastSignature: Prefs.Signature? = Prefs.signature
    private var actionInFlight = false

    init() {
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.preferencesChanged() }
    }

    func start() {
        refresh(manual: true)
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        lastInterval = Prefs.refreshInterval
        let timer = Timer(timeInterval: TimeInterval(lastInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(manual: false) }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func preferencesChanged() {
        // UserDefaults também muda por coisas do sistema (posição do status item); só reage às nossas chaves.
        let signature = Prefs.signature
        guard signature != lastSignature else { return }
        let needsScan = lastSignature.map { $0.scan != signature.scan } ?? true
        lastSignature = signature
        if Prefs.refreshInterval != lastInterval { scheduleTimer() }
        render()
        if needsScan { refresh(manual: true) }
    }

    // MARK: - Varredura

    func refresh(manual: Bool) {
        if refreshing { return }
        if actionInFlight && !manual { return }
        refreshing = true

        let extra = Prefs.extraConfigPaths
        let probeRemote = Prefs.probeRemote
        Task {
            var snap = await Task.detached(priority: .utility) { Detector.scan(extraPaths: extra) }.value
            let agents = Launchd.loadUserAgents()
            snap.servers = await Launchd.attach(snap.servers, agents: agents)
            snap.orphans = await Launchd.attach(snap.orphans, agents: agents)
            snap.servers = await HealthCheck.probe(snap.servers, probeRemote: probeRemote)

            self.snapshot = snap
            self.rememberArgv(snap)
            self.trackHealth(snap)
            self.lastUpdated = Date()
            self.render()
            self.refreshing = false
        }
    }

    private func render() {
        var items: [Row] = []
        for server in snapshot.servers {
            let health = HealthCheck.classify(server)
            if health.status == .disabled { continue }
            if health.status == .stopped && !Prefs.showStopped { continue }
            items.append(Row(server: server, health: health))
        }
        if Prefs.showOrphans {
            items += snapshot.orphans.map { Row(server: $0, health: HealthCheck.classify($0)) }
        }
        items.sort {
            if $0.health.status.rank != $1.health.status.rank { return $0.health.status.rank < $1.health.status.rank }
            return $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
        }

        var summary = Summary()
        for row in items {
            switch row.health.status {
            case .running: summary.running += 1
            case .degraded: summary.degraded += 1
            case .stopped: summary.stopped += 1
            case .remote: summary.remote += 1
            case .disabled: break
            }
        }

        if rows != items { rows = items }
        if self.summary != summary { self.summary = summary }
        if errors != snapshot.errors { errors = snapshot.errors }
        // Logs de linhas que desapareceram já não interessam.
        let ids = Set(items.map(\.id))
        if logs.keys.contains(where: { !ids.contains($0) }) { logs = logs.filter { ids.contains($0.key) } }
    }

    private func rememberArgv(_ snap: Snapshot) {
        for server in snap.servers + snap.orphans {
            if let argv = Control.liveArgv(server) { savedArgv[server.id] = argv }
        }
    }

    private func argv(for server: McpServer) -> [String]? {
        savedArgv[server.id] ?? Control.configArgv(server) ?? Control.liveArgv(server)
    }

    // MARK: - Notificações

    private func trackHealth(_ snap: Snapshot) {
        for server in snap.servers + snap.orphans {
            let health = HealthCheck.classify(server)
            let prev = healthById[server.id]
            healthById[server.id] = health.status
            guard let prev, health.notify, Prefs.enableNotifications else { continue }
            if prev == .running && (health.status == .stopped || health.status == .degraded) {
                notifyDown(server, health)
            }
        }
    }

    static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyDown(_ server: McpServer, _ health: Health) {
        guard Self.notificationsAvailable else { return }
        let name = Detector.displayName(server.name)
        let content = UNMutableNotificationContent()
        content.title = health.status == .degraded ? "\(name) degradado" : "\(name) caiu"
        content.body = health.reason
        content.sound = health.status == .stopped ? .default : nil
        if #available(macOS 12.0, *) {
            content.interruptionLevel = health.status == .stopped ? .timeSensitive : .active
        }
        let request = UNNotificationRequest(identifier: "mcp-down-\(server.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Ações

    func showFlash(_ text: String, seconds: Double = 3) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    func stop(_ server: McpServer) {
        perform(server, verb: "A parar", kind: .stop) { await Control.stop(server) }
    }

    func start(_ server: McpServer) {
        guard Control.canDaemonStart(server) else {
            showFlash("stdio: o cliente é quem inicia \(Detector.displayName(server.name))")
            return
        }
        let argv = argv(for: server)
        perform(server, verb: "A iniciar", kind: .start) { await Control.start(server, argv: argv) }
    }

    func restart(_ server: McpServer) {
        let argv = argv(for: server)
        perform(server, verb: "A reiniciar", kind: .restart) { await Control.restart(server, argv: argv) }
    }

    private enum ActionKind { case start, stop, restart }

    private func perform(
        _ server: McpServer,
        verb: String,
        kind: ActionKind,
        _ action: @escaping @Sendable () async -> ActionResult
    ) {
        guard !actionInFlight else { return }
        actionInFlight = true
        busy.insert(server.id)
        let name = Detector.displayName(server.name)
        flash = "\(verb) \(name)…"

        Task {
            let result = await action()
            if let error = result.error {
                showFlash("\(name): \(error)", seconds: 6)
            } else if kind != .stop, server.isLocalHttp, let http = server.http {
                flash = "À espera do HTTP de \(name)…"
                let up = await HealthCheck.waitForTCP(host: http.host, port: http.port, timeoutMs: 15_000)
                showFlash(up ? "\(name) no ar" : "\(name): pedido feito, HTTP ainda não respondeu", seconds: 4)
            } else {
                showFlash(kind == .stop ? "\(name) parado" : "\(name): feito")
            }
            busy.remove(server.id)
            actionInFlight = false
            refresh(manual: true)
        }
    }

    func copyURL(_ server: McpServer) {
        guard let url = server.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showFlash("URL copiada")
    }

    func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showFlash(message)
    }

    func toggleLogs(_ server: McpServer) {
        if logs[server.id] != nil {
            logs[server.id] = nil
            return
        }
        guard let agent = server.agent else { return }
        logs[server.id] = LogState()
        Task {
            let result = await Task.detached(priority: .utility) { Launchd.logs(agent) }.value
            guard self.logs[server.id] != nil else { return }
            self.logs[server.id] = LogState(loading: false, lines: result.lines, text: result.text)
        }
    }

    func revealConfig(_ server: McpServer) {
        let urls = server.configPaths.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}
