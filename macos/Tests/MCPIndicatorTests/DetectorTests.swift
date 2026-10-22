import Foundation
import Testing
@testable import MCPIndicator

struct DetectorTests {
    @Test func parsesJsonWithCommentsAndTrailingCommas() throws {
        let text = """
        {
          // comentário
          "mcpServers": {
            "fs": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], },
          },
        }
        """
        let json = try #require(Detector.parseJSONLoose(Data(text.utf8)))
        let servers = Detector.extractServers(json, source: "Cursor")
        #expect(servers.count == 1)
        #expect(servers[0].transport == .stdio)
        #expect(servers[0].command == "npx")
    }

    @Test func readsAllBucketsAndCommandArrays() {
        let json: [String: Any] = [
            "servers": ["web": ["type": "http", "url": "http://localhost:8080/mcp"]],
            "mcp": ["oc": ["command": ["bunx", "oc-mcp", "--flag"]]],
        ]
        let servers = Detector.extractServers(json, source: "OpenCode")
        let web = servers.first { $0.name == "web" }
        let oc = servers.first { $0.name == "oc" }
        #expect(web?.transport == .http)
        #expect(web?.http?.local == true)
        #expect(web?.http?.port == 8080)
        #expect(oc?.command == "bunx")
        #expect(oc?.args == ["oc-mcp", "--flag"])
    }

    @Test func parsesHttpUrls() {
        #expect(Detector.parseHttpURL("https://api.example.com/mcp")?.port == 443)
        #expect(Detector.parseHttpURL("https://api.example.com/mcp")?.local == false)
        #expect(Detector.parseHttpURL("http://[::1]:9000/")?.local == true)
        #expect(Detector.parseHttpURL("http://0.0.0.0:7000")?.path == "/")
        #expect(Detector.parseHttpURL("ftp://x") == nil)
    }

    @Test func mergesSameServerFromSeveralClients() {
        let cursor = Detector.extractServers(
            ["mcpServers": ["mem": ["url": "http://localhost:4000/mcp"]]], source: "Cursor")
        let claude = Detector.extractServers(
            ["mcpServers": ["memory": ["url": "http://127.0.0.1:4000/mcp", "disabled": true]]], source: "Claude")
        let merged = Detector.merge(cursor + claude)
        #expect(merged.count == 1)
        #expect(merged[0].sources == ["Cursor", "Claude"])
        #expect(merged[0].disabled == false)
    }

    @Test func matchesStdioByDistinctiveArgs() {
        let server = Detector.extractServers(
            ["mcpServers": ["fs": ["command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem"]]]],
            source: "Claude"
        )[0]
        let hit = ProcInfo(pid: 10, argv: ["node", "/x/npx", "-y", "@modelcontextprotocol/server-filesystem"], comm: "node")
        let miss = ProcInfo(pid: 11, argv: ["node", "/x/npx", "-y", "cowsay"], comm: "node")
        #expect(Detector.processMatchesStdio(hit, server))
        #expect(!Detector.processMatchesStdio(miss, server))
    }

    @Test func genericCommandWithoutArgsNeverMatches() {
        let server = McpServer(name: "x", sources: ["Cursor"], command: "node", args: [], url: nil,
                               transport: .stdio, disabled: false)
        #expect(!Detector.processMatchesStdio(ProcInfo(pid: 5, argv: ["node"], comm: "node"), server))
    }

    @Test func httpBridgeIsNotTheServer() {
        let server = Detector.extractServers(
            ["mcpServers": ["mem": ["url": "http://127.0.0.1:49374/mcp"]]], source: "Cursor")[0]
        let daemon = ProcInfo(pid: 20, argv: ["mem-server", "--port", "49374"], comm: "mem-server")
        let bridge = ProcInfo(pid: 21, argv: ["x", "mcp-bridge", "--server-url", "http://127.0.0.1:49374/mcp"], comm: "x")
        #expect(Detector.processMatchesHttp(daemon, server))
        #expect(!Detector.processMatchesHttp(bridge, server))
    }

    @Test func orphanHeuristics() {
        let renderer = ProcInfo(pid: 1, argv: ["Claude Helper", "--type=renderer", "mcp-server"], comm: "Claude Helper")
        let script = ProcInfo(pid: 2, argv: ["node", "/home/u/octor-ticket-mcp.mjs"], comm: "node")
        let wrapper = ProcInfo(pid: 3, argv: ["npm", "exec", "chrome-devtools-mcp@latest"], comm: "npm")
        let child = ProcInfo(pid: 4, argv: ["chrome-devtools-mcp"], comm: "chrome-devtools-mcp")
        #expect(!Detector.looksLikeMcpProcess(renderer))
        #expect(Detector.looksLikeMcpProcess(script))
        #expect(!Detector.looksLikeMcpProcess(wrapper))
        #expect(Detector.looksLikeMcpProcess(child))
        #expect(Detector.groupOrphans([script, script]).first?.pids.count == 2)
    }

    @Test func classifiesLocalHttp() {
        var server = Detector.extractServers(
            ["mcpServers": ["mem": ["url": "http://localhost:4000/mcp"]]], source: "Cursor")[0]
        #expect(HealthCheck.classify(server).status == .stopped)
        server.httpUp = true
        #expect(HealthCheck.classify(server).status == .degraded)
        server.mcpUp = true
        #expect(HealthCheck.classify(server).status == .running)
    }

    @Test func clientManagedStdioIsNotStartable() {
        let server = Detector.extractServers(
            ["mcpServers": ["fs": ["command": "uvx", "args": ["mcp-server-fetch"]]]], source: "Claude")[0]
        #expect(HealthCheck.isClientManagedStdio(server))
        #expect(!Control.canDaemonStart(server))
        #expect(HealthCheck.classify(server).reason.contains("cliente"))
    }

    @Test func matchesLaunchAgentByLabelSuffix() {
        let agent = LaunchAgent(label: "com.github.someone.ai-memory", plistPath: "/x.plist",
                                argv: ["/bin/ai-memory", "serve"], stdoutPath: nil, stderrPath: nil)
        let other = LaunchAgent(label: "com.google.keystone.agent", plistPath: "/y.plist",
                                argv: ["/bin/ks"], stdoutPath: nil, stderrPath: nil)
        let server = McpServer(name: "ai-memory", sources: ["Claude"], command: "/opt/ai-memory", args: [],
                               url: nil, transport: .stdio, disabled: false)
        #expect(Launchd.agent(for: server, in: [other, agent]) == agent)
    }

    @Test func readsOwnArgv() {
        let argv = ProcessTable.arguments(of: getpid())
        #expect(argv?.isEmpty == false)
    }
}
