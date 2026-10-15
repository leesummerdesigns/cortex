import Foundation
import Testing
@testable import CortexKit

private func tempVault() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ path: String, in root: URL) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Test func datesFromFrontmatterAndTitles() throws {
    let cal = Calendar(identifier: .gregorian)
    let iso = try #require(Parser.date("2026-07-06"))
    #expect(cal.component(.year, from: iso) == 2026)

    let short = try #require(Parser.createdDate(title: "Bloodlog 01.07.26", frontmatter: [:]))
    let parts = cal.dateComponents([.year, .month, .day], from: short)
    #expect(parts.year == 2026 && parts.month == 7 && parts.day == 1)

    let long = try #require(Parser.date("24.09.2025"))
    #expect(cal.component(.year, from: long) == 2025)

    let fm = try #require(Parser.createdDate(title: "Note", frontmatter: ["erstellt": .string("2024-08-10")]))
    #expect(cal.component(.year, from: fm) == 2024)
    #expect(Parser.createdDate(title: "No date here", frontmatter: [:]) == nil)
}

@Test func settingFrontmatterKeys() {
    let text = "---\ntags: [a]\nstatus: proposal\nlist:\n  - x\n---\nBody"
    #expect(Parser.settingFrontmatter(text, key: "status", value: "aktiv") == "---\ntags: [a]\nstatus: aktiv\nlist:\n  - x\n---\nBody")
    #expect(Parser.settingFrontmatter(text, key: "list", value: nil) == "---\ntags: [a]\nstatus: proposal\n---\nBody")
    #expect(Parser.settingFrontmatter(text, key: "privacy", value: "private").contains("privacy: private\n---\nBody"))
    #expect(Parser.settingFrontmatter("Just body", key: "privacy", value: "private") == "---\nprivacy: private\n---\nJust body")
    #expect(Parser.settingFrontmatter("Just body", key: "privacy", value: nil) == "Just body")
}

@Test func packsLoadOnlyWhenActive() throws {
    let vault = try tempVault()
    try write("# Me\nMy own note", "Me.md", in: vault)
    try write("hidden", ".claude/skills/SKILL.md", in: vault)

    let coach = PackManifest(id: "coach", name: "Coach", author: "Cortex", description: "d", kind: .persona, color: "#6cc3a0")
    let swift = PackManifest(id: "swift", name: "SwiftUI", author: "Cortex", description: "d", kind: .knowledge, color: "#f08a4b")
    for (m, note) in [(coach, "Ask questions."), (swift, "Use @Observable.")] {
        let src = vault.appendingPathComponent("src-\(m.id)")
        try write(note, "Note \(m.id).md", in: src)
        try JSONEncoder().encode(m).write(to: src.appendingPathComponent("pack.json"))
        try Packs.install(from: src, vault: vault)
    }
    #expect(Packs.installed(vault: vault).map(\.id) == ["coach", "swift"])

    // Installed but inactive: only the user's own (non-hidden) note, plus the source folders written above.
    #expect(try Vault.load(vault).filter { $0.pack != nil }.isEmpty)
    #expect(try !Vault.load(vault).contains { $0.id.hasPrefix(".claude") })

    try CortexConfig(activePersona: "coach", enabledPacks: ["swift"]).save(vault: vault)
    let notes = try Vault.load(vault)
    #expect(notes.first { $0.id == "pack:coach/Note coach" }?.layer == .core)
    #expect(notes.first { $0.id == "pack:swift/Note swift" }?.layer == .pack)
    #expect(notes.first { $0.id == "pack:swift/Note swift" }?.pack?.color == "#f08a4b")
}

@Test func packExportAndZipRoundTrip() throws {
    let vault = try tempVault()
    try write("---\nlayer: core\n---\nShort sentences.", "Style.md", in: vault)
    let note = try #require(try Vault.load(vault).first)
    let manifest = PackManifest(id: "me", name: "Me", author: "Louis", description: "My style", kind: .persona, color: "#ffffff")
    let zip = vault.appendingPathComponent("me.zip")
    try Packs.export([note], manifest: manifest, to: zip)

    let other = try tempVault()
    let installed = try Packs.install(from: zip, vault: other)
    #expect(installed == manifest)
    #expect(Packs.installed(vault: other).first?.noteCount == 1)
}

@Test func proposalsAcceptAndPrivacy() throws {
    let vault = try tempVault()
    try FileManager.default.createDirectory(at: vault.appendingPathComponent("01 Inbox"), withIntermediateDirectories: true)
    let url = try Proposals.propose(title: "Likes: tea / coffee?", content: "Tea.", tags: ["pref"], source: "Claude Code", vault: vault)
    #expect(url.lastPathComponent == "Likes  tea   coffee.md")
    let second = try Proposals.propose(title: "Likes: tea / coffee?", content: "Tea.", source: "x", vault: vault)
    #expect(second.lastPathComponent == "Likes  tea   coffee 2.md")

    var note = try #require(try Vault.load(vault).first { $0.url.lastPathComponent == url.lastPathComponent })
    #expect(note.isProposal && note.source == "Claude Code")
    try Proposals.accept(note)
    try Proposals.setPrivate(note, true)
    note = try #require(try Vault.load(vault).first { $0.url.lastPathComponent == url.lastPathComponent })
    #expect(!note.isProposal && note.isPrivate && note.status == "aktiv")
}

@Test func coreBundleExcludesPrivateNotes() throws {
    let vault = try tempVault()
    try write("Be direct.", "00 Kontext/Style.md", in: vault)
    try write("---\nprivacy: private\n---\nSecret.", "00 Kontext/Diary.md", in: vault)
    let index = Index(notes: try Vault.load(vault))
    let core = index.coreBundle()
    #expect(core.contains("Be direct.") && !core.contains("Secret."))
    #expect(index.recall("Secret", forAI: true).isEmpty)
    #expect(!index.recall("Secret").isEmpty)
}

@Test func starterVaultHasCoreAndLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-starter-\(UUID().uuidString)")
    try Vault.createStarter(at: root)
    let notes = try Vault.load(root)
    #expect(notes.count == 3)
    #expect(notes.filter { $0.layer == .core }.map(\.title).sorted() == ["About me", "How to respond"])
    #expect(notes.first { $0.title == "Welcome to Cortex" }?.links.contains("about me") == true)
    #expect(Vault.inboxFolder(root).lastPathComponent == "01 Inbox")
}
