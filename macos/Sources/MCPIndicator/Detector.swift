import Foundation

struct ConfigSpec: Sendable, Hashable {
    let rel: String
    let source: String
}

/// Caminhos de config no macOS (equivalentes aos de ~/.config no Linux).
let defaultConfigs: [ConfigSpec] = [
    ConfigSpec(rel: ".cursor/mcp.json", source: "Cursor"),
    ConfigSpec(rel: "Library/Application Support/Code/User/mcp.json", source: "VS Code"),
    ConfigSpec(rel: "Library/Application Support/Code - Insiders/User/mcp.json", source: "VS Code"),
    ConfigSpec(rel: ".vscode/mcp.json", source: "VS Code"),
    ConfigSpec(rel: ".claude.json", source: "Claude"),
    ConfigSpec(rel: "Library/Application Support/Claude/claude_desktop_config.json", source: "Claude Desktop"),
    ConfigSpec(rel: ".config/opencode/opencode.json", source: "OpenCode"),
    ConfigSpec(rel: ".gemini/settings.json", source: "Gemini"),
    ConfigSpec(rel: ".gemini/config/mcp_config.json", source: "Gemini"),
    ConfigSpec(rel: ".copilot/mcp-config.json", source: "Copilot"),
    ConfigSpec(rel: ".lmstudio/mcp.json", source: "LM Studio"),
    ConfigSpec(rel: ".codeium/windsurf/mcp_config.json", source: "Windsurf"),
    ConfigSpec(
        rel: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
        source: "Cline"
    ),
    ConfigSpec(
        rel: "Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
        source: "Cline"
    ),
]

private let genericCommands: Set<String> = [
    "npx", "npm", "pnpm", "yarn", "bun", "deno",
    "uvx", "uv", "python", "python3", "node", "nodejs",
    "docker", "podman", "sh", "bash", "zsh", "env",
]

private let genericArgs: Set<String> = [
    "-y", "--yes", "-yq", "--quiet", "-q", "-i", "--rm",
    "run", "npx", "uvx", "uv", "python", "python3",
    "node", "nodejs", "bun", "deno", "docker", "podman",
    "--registry",
]

enum Transport: String, Sendable {
    case stdio, http, sse
}

struct ParsedURL: Sendable, Equatable {
    let scheme: String
    let host: String
    let port: Int
    let path: String
    let local: Bool
}

struct McpServer: Identifiable, Sendable {
    var id: String = ""
    var name: String
    var sources: [String]
    var configPaths: [String] = []
    var command: String?
    var args: [String]
    var url: String?
    var transport: Transport
    var disabled: Bool
    var http: ParsedURL?
    var orphan = false
    var pids: [Int32] = []

    var agent: LaunchAgent?
    var agentLoaded = false
    var agentRunning = false

    var httpUp = false
    var mcpUp = false
    var mcpDetail: String?

    var isLocalHttp: Bool {
        (transport == .http || transport == .sse) && (http?.local ?? false)
    }
}

struct Snapshot: Sendable {
    var servers: [McpServer] = []
    var orphans: [McpServer] = []
    var errors: [String] = []
}

enum Detector {
    static var home: String { NSHomeDirectory() }

    static func expandUser(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func basename(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return (path as NSString).lastPathComponent
    }

    static func displayName(_ name: String) -> String {
        if let i = name.lastIndex(of: "/") { return String(name[name.index(after: i)...]) }
        return name
    }

    static func distinctiveArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if genericArgs.contains(a) {
                if a == "--registry" { i += 1 }
                i += 1
                continue
            }
            if a.hasPrefix("--registry=") { i += 1; continue }
            if a.count > 1 { out.append(a) }
            i += 1
        }
        return out
    }

    /// JSON tolerante: comentários e vírgulas finais (configs do VS Code / Cursor).
    static func parseJSONLoose(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        return try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
    }

    static func parseHttpURL(_ raw: String?) -> ParsedURL? {
        guard let raw, let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let port = comps.port ?? (scheme == "https" ? 443 : 80)
        let path = comps.path.isEmpty ? "/" : comps.path
        let local = ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
        return ParsedURL(scheme: scheme, host: host, port: port, path: path, local: local)
    }

    static func normalizeServer(name: String, cfg: Any, source: String, path: String) -> McpServer? {
        guard let cfg = cfg as? [String: Any] else { return nil }

        let disabled = (cfg["disabled"] as? Bool) == true || (cfg["enabled"] as? Bool) == false
        var command: String?
        var args = (cfg["args"] as? [Any])?.map { "\($0)" } ?? []

        if let list = cfg["command"] as? [Any] {
            args = list.dropFirst().map { "\($0)" }
            command = list.first.map { "\($0)" }
        } else if let c = cfg["command"] {
            command = "\(c)"
        }

        let url = (cfg["url"] ?? cfg["serverUrl"] ?? cfg["httpUrl"]).map { "\($0)" }
        let type = ((cfg["type"] as? String) ?? "").lowercased()
        let isHttp = url != nil || ["http", "sse", "remote", "streamable-http"].contains(type)

        if command == nil && url == nil { return nil }

        return McpServer(
            name: name,
            sources: [source],
            configPaths: [path],
            command: command,
            args: args,
            url: url,
            transport: isHttp ? (type == "sse" ? .sse : .http) : .stdio,
            disabled: disabled,
            http: parseHttpURL(url)
        )
    }

    static func extractServers(_ data: [String: Any], source: String, path: String = "") -> [McpServer] {
        var out: [McpServer] = []
        for key in ["mcpServers", "servers", "mcp"] {
            guard let bucket = data[key] as? [String: Any] else { continue }
            for name in bucket.keys.sorted() {
                if let server = normalizeServer(name: name, cfg: bucket[name]!, source: source, path: path) {
                    out.append(server)
                }
            }
        }
        return out
    }

    static func identity(_ server: McpServer) -> String {
        if let url = server.url {
            if let p = parseHttpURL(url) {
                let host = p.local ? "127.0.0.1" : p.host
                return "http:\(host):\(p.port)\(p.path)"
            }
            return "http:\(url)"
        }
        let base = basename(server.command ?? server.name)
        let dist = distinctiveArgs(server.args).joined(separator: " ")
        return "stdio:\(base):\(dist)"
    }

    static func merge(_ list: [McpServer]) -> [McpServer] {
        var order: [String] = []
        var map: [String: McpServer] = [:]
        for server in list {
            let id = identity(server)
            guard var prev = map[id] else {
                var s = server
                s.id = id
                map[id] = s
                order.append(id)
                continue
            }
            for source in server.sources where !prev.sources.contains(source) { prev.sources.append(source) }
            for path in server.configPaths where !prev.configPaths.contains(path) { prev.configPaths.append(path) }
            prev.disabled = prev.disabled && server.disabled
            if prev.command == nil, server.command != nil {
                prev.command = server.command
                prev.args = server.args
            }
            if prev.url == nil, server.url != nil {
                prev.url = server.url
                prev.http = server.http
                prev.transport = server.transport
            }
            map[id] = prev
        }
        return order.compactMap { map[$0] }
    }

    static func loadConfiguredServers(extraPaths: [String] = []) -> (servers: [McpServer], errors: [String]) {
        var specs = defaultConfigs.map { (path: (home as NSString).appendingPathComponent($0.rel), source: $0.source) }
        for raw in extraPaths {
            let path = expandUser(raw.trimmingCharacters(in: .whitespaces))
            if !path.isEmpty { specs.append((path: path, source: "Extra")) }
        }

        var found: [McpServer] = []
        var errors: [String] = []
        var seen = Set<String>()
        for spec in specs where seen.insert(spec.path).inserted {
            guard let data = FileManager.default.contents(atPath: spec.path) else { continue }
            guard let json = parseJSONLoose(data) else {
                errors.append("\(spec.source): JSON inválido em \(spec.path)")
                continue
            }
            found.append(contentsOf: extractServers(json, source: spec.source, path: spec.path))
        }
        return (merge(found), errors)
    }

    // MARK: - Processos

    static func hasToken(_ cmdline: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return cmdline.matches("(?:^|[\\s/])\(escaped)(?:\\s|$)")
    }

    static func processMatchesStdio(_ proc: ProcInfo, _ server: McpServer) -> Bool {
        guard let command = server.command, !command.isEmpty else { return false }
        let cmd = proc.cmdline
        let base = basename(command)
        guard cmd.contains(command) || hasToken(cmd, base) else { return false }

        let distinctive = distinctiveArgs(server.args)
        if genericCommands.contains(base) && distinctive.isEmpty { return false }
        if distinctive.isEmpty { return true }
        return distinctive.allSatisfy { cmd.contains($0) }
    }

    static func processMatchesHttp(_ proc: ProcInfo, _ server: McpServer) -> Bool {
        let cmd = proc.cmdline
        if let port = server.http?.port, cmd.matches("(?:--port[= ]|:)\(port)\\b") {
            // Pontes stdio→HTTP (ex.: `mcp-bridge --server-url http://…:PORT`) são clientes, não o servidor.
            if !cmd.matches("--server-url[= ]") { return true }
        }
        let name = server.name
        let serves = cmd.matches("\\bserve\\b") && !cmd.matches("\\bstatus\\b")
        if proc.comm == name && serves { return true }
        if !name.isEmpty && cmd.contains(name) && serves && !cmd.matches("\\bextract\\b") { return true }
        return false
    }

    static func looksLikeMcpProcess(_ proc: ProcInfo) -> Bool {
        let cmd = proc.cmdline
        let comm = proc.comm
        if cmd.matches("(?:^|\\s)--type=(renderer|gpu-process|utility|zygote)(?:\\s|$)") { return false }
        if cmd.matches("^(docker|podman)\\s+run\\b") { return false }
        if cmd.matches("cursor-memory-mcp/web\\.py") { return false }
        if comm == "ai-memory" && cmd.matches("\\bstatus\\b") && !cmd.matches("\\bserve\\b") { return false }
        // Wrappers `npm exec foo-mcp` aparecem junto do processo real; fica só o filho.
        if cmd.matches("^npm exec\\b") { return false }

        if cmd.contains("modelcontextprotocol") { return true }
        if cmd.matches("-mcp\\.(mjs|js|cjs|ts|py)\\b") || cmd.contains("mcp-server") { return true }
        if comm == "gk" && cmd.matches("\\bmcp\\b") { return true }
        if comm == "ai-memory" && cmd.matches("\\b(serve|mcp-bridge)\\b") { return true }
        if cmd.matches("cursor-memory-mcp/server\\.py") { return true }
        if cmd.matches("/mcp[\\w.-]*\\.(mjs|js|cjs|ts|py)\\b") { return true }
        // Binários `foo-mcp` / `mcp-foo`, ou Node com `process.title` reescrito para esse nome.
        for name in [comm, basename(proc.argv.first)] where name.matches("(?i)^([\\w.-]*-mcp|mcp-[\\w.-]+)$") {
            return true
        }
        return false
    }

    static func orphanName(_ proc: ProcInfo) -> String {
        if let m = proc.cmdline.firstMatch("([\\w.-]*mcp[\\w.-]*)") { return m }
        return proc.comm.isEmpty ? "mcp" : proc.comm
    }

    static func orphanKey(_ proc: ProcInfo) -> String {
        if let m = proc.cmdline.firstMatch("(\\S*mcp\\S*)") { return m }
        return "\(proc.comm):\(proc.cmdline.prefix(80))"
    }

    static func groupOrphans(_ processes: [ProcInfo]) -> [McpServer] {
        var order: [String] = []
        var map: [String: McpServer] = [:]
        for proc in processes {
            let key = orphanKey(proc)
            if map[key] == nil {
                var s = McpServer(
                    name: orphanName(proc),
                    sources: ["processo"],
                    command: proc.cmdline,
                    args: [],
                    url: nil,
                    transport: .stdio,
                    disabled: false
                )
                s.id = "orphan:\(key)"
                s.orphan = true
                map[key] = s
                order.append(key)
            }
            map[key]!.pids.append(proc.pid)
        }
        return order.compactMap { map[$0] }
    }

    static func scan(extraPaths: [String] = []) -> Snapshot {
        var (servers, errors) = loadConfiguredServers(extraPaths: extraPaths)
        let processes = ProcessTable.listUserProcesses()
        var used = Set<Int32>()

        for i in servers.indices {
            servers[i].pids = []
            for proc in processes {
                let match = servers[i].transport == .stdio
                    ? processMatchesStdio(proc, servers[i])
                    : processMatchesHttp(proc, servers[i])
                if match {
                    servers[i].pids.append(proc.pid)
                    used.insert(proc.pid)
                }
            }
        }

        let leftover = processes.filter { !used.contains($0.pid) && looksLikeMcpProcess($0) }
        errors = Array(Set(errors)).sorted()
        return Snapshot(servers: servers, orphans: groupOrphans(leftover), errors: errors)
    }

    static func commandPreview(_ server: McpServer) -> String {
        if let url = server.url { return url }
        if server.orphan { return String((server.command ?? server.name).prefix(160)) }
        var parts: [String] = []
        if let command = server.command { parts.append(basename(command)) }
        parts.append(contentsOf: distinctiveArgs(server.args).map { basename($0) })
        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? server.name : text
    }
}
