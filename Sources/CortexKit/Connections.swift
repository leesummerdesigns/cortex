import Foundation

/// Wires Cortex into the AI apps on this Mac. Every change is reversible (disconnect) and
/// JSON configs are merged, never overwritten: other servers and settings are left untouched.
public struct Connections: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    // MARK: Stable helper location

    /// Copies the bundled `cortex` helper to ~/Library/Application Support/Cortex/bin so AI apps keep
    /// working when Cortex.app is moved or updated. Returns the stable path.
    @discardableResult
    public func installHelper(from bundled: URL) throws -> URL {
        let target = home.appendingPathComponent("Library/Application Support/Cortex/bin/cortex")
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let same = (try? Data(contentsOf: bundled)) == (try? Data(contentsOf: target))
        if !same {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: bundled, to: target)
        }
        return target
    }

    // MARK: Claude Code

    public var claudeCodeConfig: URL { home.appendingPathComponent(".claude.json") }
    public var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }

    /// The `claude` CLI, if installed in one of the usual places.
    public var claudeCLI: URL? {
        ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { URL(fileURLWithPath: $0.replacingOccurrences(of: "~", with: home.path)) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var claudeCodeConnected: Bool {
        (Self.readJSON(claudeCodeConfig)["mcpServers"] as? [String: Any])?["cortex"] != nil
    }

    /// Registers Cortex for all projects via the official CLI (it owns ~/.claude.json).
    public func connectClaudeCode(helper: URL, vault: URL) throws {
        guard let cli = claudeCLI else { throw ConnectionError.claudeCodeMissing }
        if claudeCodeConnected { try run(cli, ["mcp", "remove", "cortex", "--scope", "user"]) }
        try run(cli, ["mcp", "add", "cortex", "--scope", "user", "--", helper.path, "mcp", vault.path])
    }

    public func disconnectClaudeCode() throws {
        guard let cli = claudeCLI else { throw ConnectionError.claudeCodeMissing }
        try run(cli, ["mcp", "remove", "cortex", "--scope", "user"])
    }

    /// The SessionStart hook prints the core at the start of every Claude Code session.
    public var sessionHookInstalled: Bool {
        sessionStartGroups(Self.readJSON(claudeSettings)).contains(where: Self.isCortexHook)
    }

    public func installSessionHook(helper: URL, vault: URL) throws {
        var settings = Self.readJSON(claudeSettings)
        var groups = sessionStartGroups(settings).filter { !Self.isCortexHook($0) }
        groups.append(["hooks": [["type": "command", "command": "\"\(helper.path)\" core \"\(vault.path)\""]]])
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = groups
        settings["hooks"] = hooks
        try Self.writeJSON(settings, to: claudeSettings, backup: true)
    }

    public func removeSessionHook() throws {
        var settings = Self.readJSON(claudeSettings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = sessionStartGroups(settings).filter { !Self.isCortexHook($0) }
        if groups.isEmpty { hooks.removeValue(forKey: "SessionStart") } else { hooks["SessionStart"] = groups }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try Self.writeJSON(settings, to: claudeSettings, backup: true)
    }

    private func sessionStartGroups(_ settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
    }

    private static func isCortexHook(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains("/Cortex/bin/cortex\" core") == true
            || ($0["command"] as? String)?.contains("Helpers/cortex\" core") == true }
    }

    // MARK: Codex (OpenAI's coding agent: CLI, IDE extension and Codex app share ~/.codex/config.toml)

    public var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    /// The `codex` CLI, if installed in one of the usual places.
    public var codexCLI: URL? {
        ["/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
            .map { URL(fileURLWithPath: $0.replacingOccurrences(of: "~", with: home.path)) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var codexConnected: Bool {
        let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.cortex]" }
    }

    /// Registers Cortex via the official CLI (it owns config.toml).
    public func connectCodex(helper: URL, vault: URL) throws {
        guard let cli = codexCLI else { throw ConnectionError.codexMissing }
        if codexConnected { try run(cli, ["mcp", "remove", "cortex"]) }
        try run(cli, ["mcp", "add", "cortex", "--", helper.path, "mcp", vault.path])
    }

    public func disconnectCodex() throws {
        guard let cli = codexCLI else { throw ConnectionError.codexMissing }
        try run(cli, ["mcp", "remove", "cortex"])
    }

    // MARK: Cursor (and other apps using the mcpServers JSON format)

    public var cursorConfig: URL { home.appendingPathComponent(".cursor/mcp.json") }

    public var cursorConnected: Bool {
        (Self.readJSON(cursorConfig)["mcpServers"] as? [String: Any])?["cortex"] != nil
    }

    public func connectCursor(helper: URL, vault: URL) throws {
        var config = Self.readJSON(cursorConfig)
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["cortex"] = ["command": helper.path, "args": ["mcp", vault.path]]
        config["mcpServers"] = servers
        try Self.writeJSON(config, to: cursorConfig, backup: true)
    }

    public func disconnectCursor() throws {
        var config = Self.readJSON(cursorConfig)
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: "cortex")
        config["mcpServers"] = servers
        try Self.writeJSON(config, to: cursorConfig, backup: true)
    }

    // MARK: Claude Desktop

    private var claudeDesktopSupport: URL { home.appendingPathComponent("Library/Application Support/Claude") }

    /// Installed as an extension (from our .mcpb) or configured manually in claude_desktop_config.json.
    public var claudeDesktopConnected: Bool {
        let extensions = (try? FileManager.default.contentsOfDirectory(atPath: claudeDesktopSupport.appendingPathComponent("Claude Extensions").path)) ?? []
        if extensions.contains(where: { $0.lowercased().contains("cortex") }) { return true }
        let config = Self.readJSON(claudeDesktopSupport.appendingPathComponent("claude_desktop_config.json"))
        return (config["mcpServers"] as? [String: Any])?["cortex"] != nil
    }

    /// Builds the one-click Claude Desktop extension (MCP Bundle): manifest + helper binary + icon, zipped.
    public static func buildMCPB(helper: URL, vault: URL, icon: URL?, version: String, to destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("cortex-mcpb-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("server"), withIntermediateDirectories: true)
        try fm.copyItem(at: helper, to: staging.appendingPathComponent("server/cortex"))
        if let icon, fm.fileExists(atPath: icon.path) { try fm.copyItem(at: icon, to: staging.appendingPathComponent("icon.png")) }

        let manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": "cortex",
            "display_name": "Cortex",
            "version": version,
            "description": "Your personal memory from Cortex: identity, writing style, active persona, projects and knowledge — searchable by Claude. Runs locally; private notes never leave your Mac.",
            "author": ["name": "Cortex"],
            "icon": "icon.png",
            "server": [
                "type": "binary",
                "entry_point": "server/cortex",
                "mcp_config": ["command": "${__dirname}/server/cortex", "args": ["mcp", "${user_config.vault}"]],
            ],
            "user_config": [
                "vault": [
                    "type": "directory", "title": "Memory vault",
                    "description": "The Markdown folder Cortex uses as your memory.",
                    "required": true, "default": vault.path,
                ],
            ],
            "compatibility": ["platforms": ["darwin"]],
            "tools": [
                ["name": "get_core", "description": "Load your identity, style, preferences and active persona"],
                ["name": "recall", "description": "Search your memory"],
                ["name": "read_note", "description": "Read one memory in full"],
                ["name": "remember", "description": "Propose a new memory for your review"],
                ["name": "switch_persona", "description": "Change the AI persona"],
            ],
            "prompts_generated": true,
        ]
        var data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: staging.appendingPathComponent("manifest.json"))

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", staging.path, destination.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ConnectionError.commandFailed("ditto") }
    }

    // MARK: Helpers

    static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Writes JSON, keeping a one-time backup of the user's original file (`<name>.cortex-backup`).
    static func writeJSON(_ object: [String: Any], to url: URL, backup: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backupURL = url.appendingPathExtension("cortex-backup")
        if backup, fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backupURL.path) {
            try fm.copyItem(at: url, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func run(_ tool: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConnectionError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public enum ConnectionError: LocalizedError {
    case claudeCodeMissing
    case codexMissing
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .claudeCodeMissing: "Claude Code isn't installed (no `claude` command found)."
        case .codexMissing: "Codex isn't installed (no `codex` command found)."
        case .commandFailed(let message): message.isEmpty ? "The command failed." : message
        }
    }
}
