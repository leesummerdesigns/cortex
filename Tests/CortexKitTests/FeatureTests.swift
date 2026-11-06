import Foundation
import Testing
@testable import CortexKit

private func tempVault() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-feature-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func note(_ id: String, body: String = "", frontmatter: [String: FrontmatterValue] = [:], layer: Layer = .memory,
                  created: Date = .distantPast, modified: Date = .distantPast, url: URL = URL(fileURLWithPath: "/dev/null")) -> Note {
    Note(id: id, title: id, url: url, folder: "", frontmatter: frontmatter, body: body, links: Parser.wikilinks(body),
         layer: layer, created: created, modified: modified)
}

private let days: TimeInterval = 86_400

// MARK: Agent chat

@Test func claudeStreamBecomesEvents() {
    var parser = AgentStreamParser(agent: .claude)
    let lines = [
        #"{"type":"system","subtype":"hook_started"}"#,
        #"{"type":"system","subtype":"init","session_id":"abc"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hal"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hallo"},{"type":"tool_use","name":"mcp__cortex__recall","input":{"query":"Falke"}}]}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Fertig"}}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Fertig"}"#,
        "not json",
    ]
    #expect(lines.flatMap { parser.parse($0) } == [
        .session("abc"), .text("Hal"), .text("lo"), .tool(name: "recall", detail: "Falke"), .text("\n\n"), .text("Fertig"),
    ])
}

@Test func claudeSignInFailureSaysWhatToDo() {
    var parser = AgentStreamParser(agent: .claude)
    let events = parser.parse(#"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#)
    #expect(events == [.failed("Claude Code isn't signed in. Run “claude auth login” in Terminal, then try again.")])
}

@Test func codexStreamBecomesEvents() {
    // Captured from codex-cli 0.165.
    var parser = AgentStreamParser(agent: .codex)
    let lines = [
        #"{"type":"thread.started","thread_id":"t1"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Ich suche.\n"}}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"cortex","tool":"recall","arguments":{"query":"Falke"},"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"cortex","tool":"recall","arguments":{"query":"Falke"},"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"ZITRONE-42"}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":1}}"#,
    ]
    #expect(lines.flatMap { parser.parse($0) } == [
        .session("t1"), .text("Ich suche."), .tool(name: "recall", detail: "Falke"), .text("\n\nZITRONE-42"),
    ])
}

@Test func codexApiErrorIsUnwrapped() {
    var parser = AgentStreamParser(agent: .codex)
    let raw = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Model not supported.\"}}"}}"#
    #expect(parser.parse(raw) == [.failed("Model not supported.")])
}

@Test func agentsOnlyGetTheCortexTools() {
    let claude = AgentChat.arguments(agent: .claude, helper: "/h/cortex", vault: "/v", session: nil)
    #expect(claude[claude.firstIndex(of: "--tools")! + 1] == "")
    #expect(claude.contains("--strict-mcp-config"))
    #expect(!claude.contains("--resume"))
    #expect(AgentChat.arguments(agent: .claude, helper: "/h", vault: "/v", session: "s").suffix(2) == ["--resume", "s"])

    let codex = AgentChat.arguments(agent: .codex, helper: "/a \"b\"/cortex", vault: "/v", session: nil)
    #expect(codex.contains("--ignore-user-config"))
    #expect(codex.contains("shell_tool"))
    #expect(codex.contains("mcp_servers.cortex.command=\"/a \\\"b\\\"/cortex\""))
    #expect(codex.last == "-")
    #expect(Array(AgentChat.arguments(agent: .codex, helper: "/h", vault: "/v", session: "t").prefix(2)) == ["exec", "resume"])
    #expect(Array(AgentChat.arguments(agent: .codex, helper: "/h", vault: "/v", session: "t").suffix(2)) == ["t", "-"])
}

@Test func instructionsGoWithTheFirstMessageOnly() {
    #expect(AgentChat.prompt("Hallo", isFirst: true, openNote: nil).contains("get_core"))
    #expect(AgentChat.prompt("Hallo", isFirst: false, openNote: nil) == "Hallo")
    #expect(AgentChat.prompt("Hallo", isFirst: false, openNote: "X").contains("[[X]]"))
}

@Test func signInStatusIsRead() {
    #expect(!AgentChat.isSignedIn(.claude, output: #"{"loggedIn": false}"#, exitCode: 1))
    #expect(AgentChat.isSignedIn(.claude, output: #"{"loggedIn": true}"#, exitCode: 0))
    #expect(AgentChat.isSignedIn(.codex, output: "Logged in using ChatGPT", exitCode: 0))
    #expect(!AgentChat.isSignedIn(.codex, output: "Not logged in", exitCode: 1))
}

@Test func chatsPersistPerVault() throws {
    let store = ChatStore(directory: try tempVault())
    var a = ChatThread(agent: .codex, vault: "/a")
    a.messages = [ChatMessage(role: .user, text: "Erste Frage\nzweite Zeile")]
    a.session = "s1"
    try store.save(a)
    try store.save(ChatThread(agent: .claude, vault: "/b"))
    let loaded = store.threads(vault: "/a")
    #expect(loaded.count == 1)
    #expect(loaded[0].title == "Erste Frage")
    #expect(loaded[0].session == "s1")
    store.delete(a.id)
    #expect(store.threads(vault: "/a").isEmpty)
}

// MARK: Capture and decisions

@Test func captureMakesANormalNote() throws {
    let vault = try tempVault()
    let url = try Capture.save("# Idee: neue App?\nmit Details", vault: vault)
    #expect(url.path.contains("01 Inbox"))
    let (fm, body) = Parser.frontmatter(try String(contentsOf: url, encoding: .utf8))
    #expect(fm["source"]?.string == "quick capture")
    #expect(fm["status"] == nil)
    #expect(body.contains("# Idee: neue App?"))
    #expect(body.contains("mit Details"))
    #expect(url.lastPathComponent == "Idee  neue App.md")

    let second = try Capture.save("Idee: neue App?", folder: "04 Ressourcen/AI", vault: vault)
    #expect(second.path.contains("04 Ressourcen/AI"))
}

@Test func aLongFirstLineLosesNothing() throws {
    let long = String(repeating: "wort ", count: 40).trimmingCharacters(in: .whitespaces)
    let url = try Capture.save(long, vault: try tempVault())
    #expect(try String(contentsOf: url, encoding: .utf8).contains(long))
}

@Test func linksStayInTheBodyNotTheTitle() throws {
    let url = try Capture.save("Neue Idee zum Markt [[Kaffeemarkt Schweiz|Markt]]", vault: try tempVault())
    #expect(url.lastPathComponent == "Neue Idee zum Markt Markt.md")
    let (_, body) = Parser.frontmatter(try String(contentsOf: url, encoding: .utf8))
    #expect(body.contains("# Neue Idee zum Markt Markt\n"))
    #expect(Parser.wikilinks(body) == ["kaffeemarkt schweiz"])
}

@Test func decisionKeepsReasoningAndRevisitDate() throws {
    let vault = try tempVault()
    let when = try #require(Parser.date("2027-01-15"))
    let url = try Capture.save("Wir nehmen Postgres", decision: Capture.Decision(why: "Team kennt es", alternatives: "MySQL", revisit: when), vault: vault)
    let notes = try Vault.load(vault)
    let n = try #require(notes.first { $0.url.lastPathComponent == url.lastPathComponent })
    #expect(n.isDecision)
    #expect(n.revisit == when)
    #expect(n.body.contains("## Why\n\nTeam kennt es"))
    #expect(n.body.contains("## Alternatives considered\n\nMySQL"))
    #expect(n.body.contains("## Outcome"))
}

@Test func aiCanProposeADecision() throws {
    let vault = try tempVault()
    let url = try Proposals.propose(title: "Stack", content: "Swift", decision: Capture.Decision(why: "Nativ"), source: "test", vault: vault)
    let n = try #require(try Vault.load(vault).first { $0.url.lastPathComponent == url.lastPathComponent })
    #expect(n.isProposal)
    #expect(n.isDecision)
    #expect(n.body.contains("## Why\n\nNativ"))
}

// MARK: Today

@Test func revisitDueComesFirstAndIgnoresHiding() throws {
    let now = Date()
    let due = note("due", frontmatter: ["revisit": .string(Capture.day(now.addingTimeInterval(-2 * days)))])
    let later = note("later", frontmatter: ["revisit": .string(Capture.day(now.addingTimeInterval(5 * days)))])
    var state = ReviewState()
    state.hiddenUntil["due"] = now.addingTimeInterval(9 * days)
    let items = Resurface.today(index: Index(notes: [later, due]), state: state, now: now)
    #expect(items.first?.id == "due")
    #expect(!items.contains { $0.id == "later" })
}

@Test func forgottenNotesCloseToCurrentWorkComeBack() {
    let now = Date()
    let old = now.addingTimeInterval(-100 * days)
    let active = note("aktiv", body: "[[alt]]", modified: now)
    let linked = note("alt", modified: old)
    let unrelated = note("fremd", modified: old)
    let recent = note("frisch", modified: now)
    let items = Resurface.today(index: Index(notes: [active, linked, unrelated, recent]), state: ReviewState(), now: now)
    #expect(items.map(\.id) == ["alt"])
    #expect(items.first?.reason == .related(to: "aktiv"))
}

@Test func hiddenAndCoreNotesStayAway() {
    let now = Date()
    let old = now.addingTimeInterval(-100 * days)
    let active = note("aktiv", body: "[[alt]] [[kern]]", modified: now)
    let linked = note("alt", modified: old)
    let core = note("kern", layer: .core, modified: old)
    var state = ReviewState()
    state.hiddenUntil["alt"] = now.addingTimeInterval(days)
    #expect(Resurface.today(index: Index(notes: [active, linked, core]), state: state, now: now).isEmpty)
    state.hiddenUntil["alt"] = now.addingTimeInterval(-days)
    #expect(Resurface.today(index: Index(notes: [active, linked, core]), state: state, now: now).map(\.id) == ["alt"])
}

@Test func anOldVaultStillGetsSomethingBack() {
    let now = Date()
    let items = Resurface.today(index: Index(notes: [note("a", modified: now.addingTimeInterval(-300 * days)),
                                                     note("b", modified: now.addingTimeInterval(-200 * days))]),
                                state: ReviewState(), now: now)
    #expect(items.map(\.id) == ["a", "b"])
    #expect(items.first?.reason == .oldest)
}

@Test func roundAnniversariesOnly() throws {
    let cal = Calendar(identifier: .gregorian)
    let now = try #require(Parser.date("2026-11-06"))
    #expect(Resurface.anniversary(of: try #require(Parser.date("2026-10-06")), now: now, calendar: cal) == 1)
    #expect(Resurface.anniversary(of: try #require(Parser.date("2026-05-06")), now: now, calendar: cal) == 6)
    #expect(Resurface.anniversary(of: try #require(Parser.date("2024-11-06")), now: now, calendar: cal) == 24)
    #expect(Resurface.anniversary(of: try #require(Parser.date("2026-09-06")), now: now, calendar: cal) == nil)
    #expect(Resurface.anniversary(of: try #require(Parser.date("2026-10-07")), now: now, calendar: cal) == nil)
    #expect(Resurface.anniversary(of: .distantPast, now: now, calendar: cal) == nil)
}

@Test func reviewStateRoundTripsAndDoesNotTouchTheIndex() throws {
    let vault = try tempVault()
    try "# X".write(to: vault.appendingPathComponent("X.md"), atomically: true, encoding: .utf8)
    let before = Vault.signature(vault)
    var state = ReviewState()
    state.hiddenUntil["X"] = Date(timeIntervalSince1970: 1_000_000)
    try state.save(vault: vault)
    #expect(ReviewState.load(vault: vault) == state)
    #expect(Vault.signature(vault) == before)
}

// MARK: Tasks

@Test func openTasksAreCollectedAcrossNotes() {
    let body = """
    - [ ] Erstens
      * [ ] Eingerückt 📅 2026-12-01
    - [x] Erledigt
    - [ ]
    ```
    - [ ] Im Code
    ```
    Normaler Text
    """
    let tasks = Tasks.open(in: [note("Plan", body: body),
                                note("Fertig", body: "- [ ] Alt", frontmatter: ["status": .string("abgeschlossen")]),
                                note("Vorschlag", body: "- [ ] Neu", frontmatter: ["status": .string("proposal")])])
    #expect(tasks.map(\.text) == ["Eingerückt", "Erstens"])
    #expect(tasks.first?.due == Parser.date("2026-12-01"))
}

@Test func tickingATaskChangesOnlyThatLine() throws {
    let vault = try tempVault()
    let url = vault.appendingPathComponent("Plan.md")
    let text = "---\nstatus: aktiv\n---\n# Plan\n\n- [ ] Eins\n- [ ] Zwei [ ] drin\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
    let (fm, body) = Parser.frontmatter(text)
    let n = note("Plan", body: body, frontmatter: fm, url: url)
    let tasks = Tasks.open(in: [n])
    try Tasks.complete(tasks[1], in: n)
    #expect(try String(contentsOf: url, encoding: .utf8) == "---\nstatus: aktiv\n---\n# Plan\n\n- [ ] Eins\n- [x] Zwei [ ] drin\n")
    #expect(throws: Tasks.TaskError.self) { try Tasks.complete(tasks[1], in: n) }
}

// MARK: Usage

@Test func usageCountsRecallsAndReadsNotTheCore() {
    let now = Date()
    let vault = URL(fileURLWithPath: "/v")
    let old = now.addingTimeInterval(-60 * days)
    let notes = [note("oft", created: old), note("nie", created: old), note("neu", created: now),
                 note("kern", layer: .core, created: old), note("privat", frontmatter: ["privacy": .string("private")], created: old)]
    let events = [
        ActivityEvent(time: now, client: "c", kind: .recall, hits: [Hit(id: "oft", score: 1)], vault: vault),
        ActivityEvent(time: now, client: "c", kind: .read, hits: [Hit(id: "oft", score: 1)], vault: vault),
        ActivityEvent(time: now, client: "c", kind: .core, hits: [Hit(id: "kern", score: 1), Hit(id: "nie", score: 1)], vault: vault),
        ActivityEvent(time: now, client: "c", kind: .recall, hits: [Hit(id: "nie", score: 1)], vault: URL(fileURLWithPath: "/andere")),
        ActivityEvent(time: now.addingTimeInterval(-100 * days), client: "c", kind: .recall, hits: [Hit(id: "nie", score: 1)], vault: vault),
    ]
    let report = Usage.report(events: events, notes: notes, vault: vault, now: now)
    #expect(report.used.map(\.note.id) == ["oft"])
    #expect(report.used.first?.count == 2)
    #expect(report.unused.map(\.id) == ["nie"])
    #expect(report.eligible == 3)
    #expect(report.usedPercent == 33)
}
