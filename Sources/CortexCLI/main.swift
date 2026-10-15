import CortexKit
import Foundation

// Usage:
//   cortex mcp [vault]              → MCP server on stdio (Claude Code, Claude Desktop, Cursor, …)
//   cortex core [vault]             → core memory as Markdown (for a SessionStart hook)
//   cortex stats [vault]
//   cortex recall "query" [vault]
//   cortex graph [vault]            → graph JSON (nodes + links)
//   cortex mcpb <out.mcpb> [vault] [icon.png] → one-click Claude Desktop extension
//   cortex serve [vault] [port]     → Bridge: MCP over HTTP + OAuth on 127.0.0.1 (default port 7319), for a tunnel
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "stats"

func vaultURL(_ index: Int) -> URL {
    var requested = Vault.defaultURL
    if args.count > index { requested = URL(fileURLWithPath: (args[index] as NSString).expandingTildeInPath) }
    else if let env = ProcessInfo.processInfo.environment["CORTEX_VAULT"] { requested = URL(fileURLWithPath: (env as NSString).expandingTildeInPath) }
    // A connected AI app may still hold an old path after the vault was renamed or moved: follow the app's setting.
    if !FileManager.default.fileExists(atPath: requested.path),
       let current = UserDefaults(suiteName: "com.louishenrich.cortex")?.string(forKey: "vaultPath") {
        return URL(fileURLWithPath: current)
    }
    return requested
}

func loadIndex(_ vault: URL) async throws -> Index {
    let index = Index(notes: try Vault.load(vault), vault: vault)
    await index.buildEmbeddings()
    return index
}

switch command {
case "mcp":
    await MCPServer(vault: vaultURL(1)).run()

case "core":
    let vault = vaultURL(1)
    let index = try await loadIndex(vault)
    ActivityLog.append(ActivityEvent(client: "Session start", kind: .core,
                                     hits: index.notes.filter { $0.layer == .core && !$0.isPrivate }.map { Hit(id: $0.id, score: 1) }, vault: vault))
    print(index.coreBundle())

case "stats":
    let start = Date()
    let index = try await loadIndex(vaultURL(1))
    var layers: [Layer: Int] = [:]
    for n in index.notes { layers[n.layer, default: 0] += 1 }
    let health = index.health()
    print("notes      \(index.notes.count)")
    print("layers     " + Layer.allCases.map { "\($0.rawValue) \(layers[$0] ?? 0)" }.joined(separator: " · "))
    print("links      manual \(index.manualLinks.count) · auto \(index.autoLinks.count) · unresolved \(index.unresolvedLinks.count)")
    print("embeddings \(index.hasEmbeddings ? "on-device ✓" : "unavailable")")
    print("health     \(health.score)/100 · duplicates \(health.duplicates.count) · isolated \(health.isolated.count) · proposals \(health.proposals.count) · stale \(health.stale.count)")
    print(String(format: "time       %.2fs", Date().timeIntervalSince(start)))

case "recall":
    guard args.count > 1 else { print("usage: cortex recall \"query\" [vault]"); exit(1) }
    let index = try await loadIndex(vaultURL(2))
    for hit in index.recall(args[1]) {
        print(String(format: "%.2f  %@", hit.score, hit.id))
    }

case "graph":
    let index = try await loadIndex(vaultURL(1))
    print(String(data: try JSONEncoder().encode(index.graph()), encoding: .utf8)!)

case "serve":
    let vault = vaultURL(1)
    let port = args.count > 2 ? UInt16(args[2]) ?? 7319 : 7319
    let bridge = Bridge(vault: vault)
    let server = try HTTPServer(port: port) { request in await bridge.handle(request) }
    server.start()
    print("Cortex Bridge listening on http://127.0.0.1:\(port) for \(vault.path)")
    fflush(stdout)
    // Started by Cortex.app: shut down with it, even if the app was killed (orphans are re-parented to launchd).
    let parent = getppid()
    while true {
        try await Task.sleep(for: .seconds(2))
        if getppid() != parent { exit(0) }
    }

case "mcpb":
    guard args.count > 1 else { print("usage: cortex mcpb <out.mcpb> [vault] [icon.png]"); exit(1) }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let icon = args.count > 3 ? URL(fileURLWithPath: args[3]) : nil
    try Connections.buildMCPB(helper: me, vault: vaultURL(2), icon: icon, version: "0.3.0",
                              to: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath))
    print("Wrote \(args[1])")

default:
    print("usage: cortex mcp | core | stats | recall \"query\" | graph | mcpb <out>   [vault]")
    exit(1)
}
