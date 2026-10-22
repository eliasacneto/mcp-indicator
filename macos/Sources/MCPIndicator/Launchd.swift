import Foundation

/// LaunchAgent do utilizador (~/Library/LaunchAgents): o equivalente macOS da unit `systemctl --user`.
struct LaunchAgent: Sendable, Equatable {
    let label: String
    let plistPath: String
    let argv: [String]
    let stdoutPath: String?
    let stderrPath: String?

    var execLine: String { argv.joined(separator: " ") }
}

enum Launchd {
    static let launchctl = "/bin/launchctl"

    static var domain: String { "gui/\(getuid())" }

    static func target(_ agent: LaunchAgent) -> String { "\(domain)/\(agent.label)" }

    static func loadUserAgents() -> [LaunchAgent] {
        let dir = (Detector.home as NSString).appendingPathComponent("Library/LaunchAgents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var agents: [LaunchAgent] = []
        for name in names.sorted() where name.hasSuffix(".plist") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            var argv = (plist["ProgramArguments"] as? [String]) ?? []
            if let program = plist["Program"] as? String {
                if argv.isEmpty { argv = [program] } else { argv[0] = program }
            }
            agents.append(LaunchAgent(
                label: label,
                plistPath: path,
                argv: argv,
                stdoutPath: (plist["StandardOutPath"] as? String).map(Detector.expandUser),
                stderrPath: (plist["StandardErrorPath"] as? String).map(Detector.expandUser)
            ))
        }
        return agents
    }

    static func agent(for server: McpServer, in agents: [LaunchAgent]) -> LaunchAgent? {
        let name = server.name.lowercased()
        let short = Detector.displayName(server.name).lowercased()
        for agent in agents {
            let label = agent.label.lowercased()
            let last = label.split(separator: ".").last.map(String.init) ?? label
            if label == name || label == short || last == short || label.hasSuffix(".\(short)") {
                return agent
            }
        }

        let genericCmd: Set<String> = ["python", "python3", "node", "nodejs", "npx", "bash", "sh", "zsh"]
        if let command = server.command, !command.isEmpty, !genericCmd.contains(Detector.basename(command)) {
            let hits = agents.filter { $0.execLine.contains(command) }
            if hits.count == 1 { return hits[0] }
        }

        let distinctive = server.args.filter { $0.contains("/") || $0.range(of: "mcp", options: .caseInsensitive) != nil }
        if !distinctive.isEmpty {
            let hits = agents.filter { agent in distinctive.allSatisfy { agent.execLine.contains($0) } }
            if hits.count == 1 { return hits[0] }
        }

        if let port = server.http?.port {
            let hits = agents.filter {
                let exec = $0.execLine
                return exec.contains(":\(port)") || exec.contains("--port \(port)") || exec.contains("--port=\(port)")
            }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    struct Status: Sendable {
        var loaded = false
        var running = false
        var pid: Int32?
    }

    static func status(_ agent: LaunchAgent) async -> Status {
        let result = await Shell.run([launchctl, "print", target(agent)])
        guard result.ok else { return Status() }
        var status = Status(loaded: true)
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "state = running" { status.running = true }
            if trimmed.hasPrefix("pid = "), let pid = Int32(trimmed.dropFirst(6)) { status.pid = pid }
        }
        return status
    }

    /// Associa LaunchAgents e o respetivo estado a cada servidor (em paralelo).
    static func attach(_ servers: [McpServer], agents: [LaunchAgent]) async -> [McpServer] {
        var out = servers
        await withTaskGroup(of: (Int, Status?).self) { group in
            for i in out.indices {
                out[i].agent = agent(for: out[i], in: agents)
                out[i].agentLoaded = false
                out[i].agentRunning = false
                guard let agent = out[i].agent else { continue }
                group.addTask { (i, await status(agent)) }
            }
            for await (i, status) in group {
                guard let status else { continue }
                out[i].agentLoaded = status.loaded
                out[i].agentRunning = status.running
            }
        }
        return out
    }

    static func start(_ agent: LaunchAgent) async -> ActionResult {
        let state = await status(agent)
        if !state.loaded {
            return finish(await Shell.run([launchctl, "bootstrap", domain, agent.plistPath]), "bootstrap")
        }
        return finish(await Shell.run([launchctl, "kickstart", target(agent)]), "kickstart")
    }

    static func restart(_ agent: LaunchAgent) async -> ActionResult {
        let state = await status(agent)
        if !state.loaded {
            return finish(await Shell.run([launchctl, "bootstrap", domain, agent.plistPath]), "bootstrap")
        }
        return finish(await Shell.run([launchctl, "kickstart", "-k", target(agent)]), "kickstart -k")
    }

    /// `bootout` em vez de kill: com KeepAlive o launchd voltaria a subir o processo.
    static func stop(_ agent: LaunchAgent) async -> ActionResult {
        let state = await status(agent)
        guard state.loaded else { return .ok }
        return finish(await Shell.run([launchctl, "bootout", target(agent)]), "bootout")
    }

    private static func finish(_ result: ShellResult, _ verb: String) -> ActionResult {
        if result.ok { return .ok }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(text.isEmpty ? "launchctl \(verb) falhou" : text)
    }

    /// Últimas linhas de StandardErrorPath / StandardOutPath do plist.
    static func logs(_ agent: LaunchAgent, lines: Int = 40) -> LogResult {
        let paths = [agent.stderrPath, agent.stdoutPath].compactMap { $0 }
        guard !paths.isEmpty else {
            return LogResult(lines: [], text: "o plist não define StandardOutPath/StandardErrorPath")
        }
        var collected: [String] = []
        for path in Array(Set(paths)).sorted() {
            collected.append(contentsOf: tail(path: path, lines: lines))
        }
        let clean = collected
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(lines)
        let text = clean.joined(separator: "\n")
        return LogResult(lines: Array(clean), text: text.isEmpty ? "sem linhas em \(paths.joined(separator: ", "))" : text)
    }

    private static func tail(path: String, lines: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .map(String.init)
    }
}

struct LogResult: Sendable {
    let lines: [String]
    let text: String
}

enum ActionResult: Sendable, Equatable {
    case ok
    case failed(String)

    var error: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
