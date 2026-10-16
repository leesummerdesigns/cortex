import Foundation
import Testing
@testable import CortexKit

private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func json(_ url: URL) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
}

private let helper = URL(fileURLWithPath: "/Users/x/Library/Application Support/Cortex/bin/cortex")
private let vault = URL(fileURLWithPath: "/Users/x/vault")

@Test func cursorConnectKeepsOtherServers() throws {
    let home = try tempHome()
    let c = Connections(home: home)
    try FileManager.default.createDirectory(at: c.cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"mcpServers":{"github":{"command":"gh-mcp"}},"other":1}"#.write(to: c.cursorConfig, atomically: true, encoding: .utf8)

    try c.connectCursor(helper: helper, vault: vault)
    #expect(c.cursorConnected)
    let servers = json(c.cursorConfig)["mcpServers"] as? [String: Any]
    #expect(servers?["github"] != nil)
    #expect((servers?["cortex"] as? [String: Any])?["args"] as? [String] == ["mcp", "/Users/x/vault"])
    #expect(json(c.cursorConfig)["other"] as? Int == 1)
    #expect(FileManager.default.fileExists(atPath: c.cursorConfig.path + ".cortex-backup"))

    try c.disconnectCursor()
    #expect(!c.cursorConnected)
    #expect((json(c.cursorConfig)["mcpServers"] as? [String: Any])?["github"] != nil)
}

@Test func sessionHookIsAddedOnceAndRemovedCleanly() throws {
    let home = try tempHome()
    let c = Connections(home: home)
    try FileManager.default.createDirectory(at: c.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = #"{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}],"Stop":[]}}"#
    try original.write(to: c.claudeSettings, atomically: true, encoding: .utf8)

    try c.installSessionHook(helper: helper, vault: vault)
    try c.installSessionHook(helper: helper, vault: vault) // idempotent
    #expect(c.sessionHookInstalled)
    let groups = (json(c.claudeSettings)["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
    #expect(groups?.count == 2)
    #expect(json(c.claudeSettings)["theme"] as? String == "dark")

    try c.removeSessionHook()
    #expect(!c.sessionHookInstalled)
    let after = json(c.claudeSettings)["hooks"] as? [String: Any]
    #expect((after?["SessionStart"] as? [[String: Any]])?.count == 1) // the user's own hook survives
    #expect(after?["Stop"] != nil)
}

@Test func sessionHookOnEmptySettings() throws {
    let c = Connections(home: try tempHome())
    try c.installSessionHook(helper: helper, vault: vault)
    #expect(c.sessionHookInstalled)
    try c.removeSessionHook()
    #expect(json(c.claudeSettings)["hooks"] == nil)
}

@Test func mcpbBundleContainsManifestAndServer() throws {
    let home = try tempHome()
    let fakeHelper = home.appendingPathComponent("cortex")
    try "#!/bin/sh\n".write(to: fakeHelper, atomically: true, encoding: .utf8)
    let out = home.appendingPathComponent("Cortex.mcpb")
    try Connections.buildMCPB(helper: fakeHelper, vault: vault, icon: nil, version: "0.3.0", to: out)

    let unzipped = home.appendingPathComponent("unzipped")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-x", "-k", out.path, unzipped.path]
    try p.run(); p.waitUntilExit()

    let manifest = json(unzipped.appendingPathComponent("manifest.json"))
    #expect(manifest["manifest_version"] as? String == "0.3")
    #expect((manifest["server"] as? [String: Any])?["entry_point"] as? String == "server/cortex")
    let config = (manifest["server"] as? [String: Any])?["mcp_config"] as? [String: Any]
    #expect(config?["args"] as? [String] == ["mcp", "${user_config.vault}"])
    #expect(FileManager.default.fileExists(atPath: unzipped.appendingPathComponent("server/cortex").path))
}

@Test func helperInstallIsStable() throws {
    let home = try tempHome()
    let source = home.appendingPathComponent("bundled-cortex")
    try "v1".write(to: source, atomically: true, encoding: .utf8)
    let c = Connections(home: home)
    let target = try c.installHelper(from: source)
    #expect(target.path.hasSuffix("Library/Application Support/Cortex/bin/cortex"))
    try "v2".write(to: source, atomically: true, encoding: .utf8)
    try c.installHelper(from: source)
    #expect(try String(contentsOf: target, encoding: .utf8) == "v2")
}

@Test(.enabled(if: Connections().codexCLI != nil, "needs the codex CLI"))
func codexConnectKeepsOtherSettings() throws {
    let home = try tempHome()
    let c = Connections(home: home)
    try FileManager.default.createDirectory(at: c.codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "model = \"gpt-5\"\n\n[mcp_servers.github]\ncommand = \"gh-mcp\"\n".write(to: c.codexConfig, atomically: true, encoding: .utf8)

    try c.connectCodex(helper: helper, vault: vault)
    try c.connectCodex(helper: helper, vault: vault) // reconnect replaces, never duplicates
    #expect(c.codexConnected)
    let text = try String(contentsOf: c.codexConfig, encoding: .utf8)
    #expect(text.components(separatedBy: "[mcp_servers.cortex]").count == 2)
    #expect(text.contains("Application Support/Cortex/bin/cortex"))
    #expect(text.contains("[mcp_servers.github]") && text.contains("model = \"gpt-5\""))

    try c.disconnectCodex()
    #expect(!c.codexConnected)
    #expect(try String(contentsOf: c.codexConfig, encoding: .utf8).contains("[mcp_servers.github]"))
}
