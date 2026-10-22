import Foundation

/// Iniciar/parar/reiniciar. LaunchAgent quando existe; senão sinais só aos PIDs já associados.
enum Control {
    static func canDaemonStart(_ server: McpServer) -> Bool {
        server.agent != nil || server.isLocalHttp
    }

    static func configArgv(_ server: McpServer) -> [String]? {
        guard let command = server.command, !command.contains(" ") else { return nil }
        return [command] + server.args
    }

    static func liveArgv(_ server: McpServer) -> [String]? {
        for pid in server.pids {
            if let argv = ProcessTable.arguments(of: pid), !argv.isEmpty { return argv }
        }
        return configArgv(server) ?? server.agent?.argv
    }

    static func pidsStillOurs(_ pids: [Int32], _ server: McpServer) -> [Int32] {
        pids.filter { pid in
            guard ProcessTable.isAlive(pid), let argv = ProcessTable.arguments(of: pid) else { return false }
            let cmd = argv.joined(separator: " ")
            let command = server.command ?? ""
            let base = Detector.basename(command)
            if !command.isEmpty && (cmd.contains(command) || (!base.isEmpty && cmd.contains(base))) { return true }
            if let port = server.http?.port, cmd.contains(String(port)) { return true }
            if !server.name.isEmpty && cmd.lowercased().contains(server.name.lowercased()) { return true }
            return server.orphan
        }
    }

    static func stop(_ server: McpServer) async -> ActionResult {
        if let agent = server.agent { return await Launchd.stop(agent) }
        let first = pidsStillOurs(server.pids, server)
        guard !first.isEmpty else { return .ok }
        ProcessTable.signal(first, SIGTERM)
        await Shell.delay(ms: 700)
        let leftover = pidsStillOurs(first, server)
        if !leftover.isEmpty { ProcessTable.signal(leftover, SIGKILL) }
        return .ok
    }

    static func start(_ server: McpServer, argv: [String]?) async -> ActionResult {
        if let agent = server.agent { return await Launchd.start(agent) }
        if server.isLocalHttp { return spawn(argv) }
        return .failed("stdio: o cliente (Cursor/Claude/VS Code) é quem inicia")
    }

    static func restart(_ server: McpServer, argv: [String]?) async -> ActionResult {
        if let agent = server.agent { return await Launchd.restart(agent) }
        if server.isLocalHttp {
            let stopped = await stop(server)
            if stopped != .ok { return stopped }
            await Shell.delay(ms: 250)
            return spawn(argv)
        }
        return await stop(server)
    }

    // MARK: - Spawn de daemons HTTP locais

    static func extraBinDirs() -> [String] {
        let home = Detector.home
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                dirs.append("\(nvm)/\(version)/bin")
            }
        }
        dirs.append("\(home)/.bun/bin")
        dirs.append("\(home)/.cargo/bin")
        return dirs
    }

    /// Apps lançadas pelo Finder herdam um PATH mínimo; junta-se o do Homebrew, nvm, etc.
    static func userPath() -> String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (extraBinDirs() + [base]).joined(separator: ":")
    }

    static func resolveCommand(_ command: String) -> String {
        if command.contains("/") { return command }
        for dir in userPath().split(separator: ":") {
            let path = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return command
    }

    static func prepareArgv(_ argv: [String]) -> [String] {
        var out = argv
        out[0] = resolveCommand(out[0])
        if Detector.basename(out[0]) == "npx" && !out.contains("-y") && !out.contains("--yes") {
            out.insert("-y", at: 1)
        }
        return out
    }

    static func spawn(_ argv: [String]?) -> ActionResult {
        guard let argv, !argv.isEmpty else { return .failed("sem comando") }
        let base = Detector.basename(argv[0])
        if base == "docker" || base == "podman" {
            return .failed("não inicio docker direto; use um LaunchAgent")
        }
        let resolved = prepareArgv(argv)
        guard resolved[0].hasPrefix("/") else { return .failed("comando não encontrado: \(resolved[0])") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved[0])
        process.arguments = Array(resolved.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPath()
        env["HOME"] = env["HOME"] ?? Detector.home
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: Detector.home)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return .ok
        } catch {
            NSLog("[MCP Indicator] spawn failed: %@", error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }
}
