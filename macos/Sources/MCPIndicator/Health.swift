import Foundation
import Network

enum HealthStatus: String, Sendable {
    case running, degraded, remote, stopped, disabled

    var rank: Int {
        switch self {
        case .running: 0
        case .degraded: 1
        case .remote: 2
        case .stopped: 3
        case .disabled: 4
        }
    }
}

struct Health: Sendable, Equatable {
    let status: HealthStatus
    let reason: String
    let notify: Bool
}

private let clientSources: Set<String> = [
    "Cursor", "VS Code", "Claude", "Claude Desktop",
    "Cline", "Windsurf", "Copilot", "Gemini", "OpenCode", "LM Studio",
]

enum HealthCheck {
    static func isClientManagedStdio(_ server: McpServer) -> Bool {
        if server.orphan || server.agent != nil || server.isLocalHttp { return false }
        if server.transport != .stdio { return false }
        return server.sources.contains { clientSources.contains($0) }
    }

    static func classify(_ server: McpServer) -> Health {
        if server.disabled {
            return Health(status: .disabled, reason: "desligado na config", notify: false)
        }

        if server.orphan {
            let n = server.pids.count
            return Health(
                status: n > 0 ? .running : .stopped,
                reason: n > 0 ? "órfão · \(n) processo(s)" : "órfão parado",
                notify: false
            )
        }

        if server.transport == .http || server.transport == .sse {
            guard server.http?.local == true else {
                return Health(status: .remote, reason: "remoto · \(server.url ?? "")", notify: false)
            }
            let port = server.http.map { String($0.port) } ?? "?"
            if server.mcpUp { return Health(status: .running, reason: "MCP ok", notify: true) }
            if server.httpUp {
                return Health(status: .degraded, reason: "porta aberta, handshake MCP falhou", notify: true)
            }
            if server.agentRunning {
                return Health(status: .degraded, reason: "LaunchAgent activo, porta \(port) recusada", notify: true)
            }
            if !server.pids.isEmpty {
                return Health(status: .degraded, reason: "processo no ar, porta \(port) recusada", notify: true)
            }
            if server.agent != nil {
                return Health(status: .stopped, reason: "LaunchAgent inactivo", notify: true)
            }
            return Health(status: .stopped, reason: "HTTP parado", notify: true)
        }

        let n = server.pids.count
        if n > 0 {
            let reason = isClientManagedStdio(server)
                ? (n == 1 ? "stdio do cliente" : "stdio do cliente · \(n) processos")
                : (n == 1 ? "pid \(server.pids[0])" : "\(n) processos")
            return Health(status: .running, reason: reason, notify: false)
        }

        if isClientManagedStdio(server) {
            return Health(status: .stopped, reason: "sem processo (o cliente é quem sobe)", notify: false)
        }
        return Health(status: .stopped, reason: "parado", notify: false)
    }

    // MARK: - Sondas

    static func probeTCP(host: String, port: Int, timeout: TimeInterval = 1) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let target = (host == "localhost" || host == "0.0.0.0") ? "127.0.0.1" : host
        let connection = NWConnection(host: NWEndpoint.Host(target), port: nwPort, using: .tcp)
        let once = Once()

        return await withCheckedContinuation { cont in
            let finish: @Sendable (Bool) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                cont.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    static func waitForTCP(host: String, port: Int, timeoutMs: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await probeTCP(host: host, port: port) { return true }
            await Shell.delay(ms: 500)
        }
        return false
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// POST `initialize` JSON-RPC. HTTP 2xx–4xx (incluindo 406) conta como vivo, como no GNOME.
    static func mcpHandshake(url raw: String) async -> (ok: Bool, detail: String) {
        guard let url = URL(string: raw) else { return (false, "URL inválida") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "mcp-indicator-macos", "version": "1"],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            // `bytes` devolve assim que chegam os cabeçalhos: não fica preso num stream SSE aberto.
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return (false, "sem resposta HTTP") }
            let status = http.statusCode
            if let sessionId = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
                closeSession(url: url, sessionId: sessionId)
            }
            if (200..<500).contains(status) { return (true, "HTTP \(status)") }

            var first = ""
            for try await line in bytes.lines {
                first = line.replacingOccurrences(of: "^data:\\s*", with: "", options: .regularExpression)
                if !first.isEmpty { break }
            }
            if let data = first.data(using: .utf8),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               body["jsonrpc"] as? String == "2.0" || body["result"] != nil || body["error"] != nil {
                return (true, "HTTP \(status)")
            }
            return (false, "HTTP \(status)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Encerra a sessão aberta pelo `initialize` de sondagem, para não acumular sessões no servidor.
    private static func closeSession(url: URL, sessionId: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        session.dataTask(with: request).resume()
    }

    static func probe(_ servers: [McpServer], probeRemote: Bool) async -> [McpServer] {
        var out = servers
        await withTaskGroup(of: (Int, Bool, Bool, String?).self) { group in
            for i in out.indices where out[i].transport != .stdio {
                out[i].httpUp = false
                out[i].mcpUp = false
                guard let parsed = Detector.parseHttpURL(out[i].url), let url = out[i].url else { continue }
                out[i].http = parsed
                if !parsed.local && !probeRemote { continue }
                group.addTask {
                    let up = await probeTCP(host: parsed.host, port: parsed.port)
                    guard up else { return (i, false, false, nil) }
                    let hand = await mcpHandshake(url: url)
                    return (i, true, hand.ok, hand.detail)
                }
            }
            for await (i, up, mcp, detail) in group {
                out[i].httpUp = up
                out[i].mcpUp = mcp
                out[i].mcpDetail = detail
            }
        }
        return out
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
