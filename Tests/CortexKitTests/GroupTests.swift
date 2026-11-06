import Foundation
import Testing
@testable import CortexKit

private func note(_ id: String, group: String?, url: URL = URL(fileURLWithPath: "/dev/null")) -> Note {
    Note(id: id, title: id, url: url, folder: "", frontmatter: group.map { ["group": .string($0)] } ?? [:],
         body: "", links: [], layer: .memory)
}

@Test func groupComesFromFrontmatter() {
    #expect(note("a", group: " Bloodlog ").group == "Bloodlog")
    #expect(note("b", group: "").group == nil)
    #expect(note("c", group: nil).group == nil)
}

@Test func groupColoursAreStableAndOverridable() {
    var config = CortexConfig()
    #expect(Groups.palette.contains(Groups.color("Bloodlog", config: config)))
    #expect(Groups.color("Bloodlog", config: config) == Groups.color("Bloodlog", config: config))
    config.groupColors["Bloodlog"] = "#123456"
    #expect(Groups.color("Bloodlog", config: config) == "#123456")
    #expect(Groups.nextColor(existing: ["Bloodlog"], config: config) == Groups.palette[0])
}

@Test func configWithoutGroupColorsStillLoads() throws {
    let config = try JSONDecoder().decode(CortexConfig.self, from: Data(#"{"enabledPacks":["x"]}"#.utf8))
    #expect(config.enabledPacks == ["x"])
    #expect(config.groupColors.isEmpty)
}

@Test func assignWritesAndRemovesGroup() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-group-\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: url) }
    try "---\nstatus: aktiv\n---\n# X".write(to: url, atomically: true, encoding: .utf8)
    let n = note("x", group: nil, url: url)

    try Groups.assign(n, to: "AI: Tools")
    var (fm, body) = Parser.frontmatter(try String(contentsOf: url, encoding: .utf8))
    #expect(fm["group"]?.string == "AI: Tools")
    #expect(fm["status"]?.string == "aktiv")
    #expect(body == "# X")

    try Groups.assign(n, to: nil)
    (fm, _) = Parser.frontmatter(try String(contentsOf: url, encoding: .utf8))
    #expect(fm["group"] == nil)
}

@Test func graphCarriesGroups() {
    let payload = Index(notes: [note("a", group: "G"), note("b", group: nil)]).graph(groupColors: ["G": "#ff0000"])
    #expect(payload.nodes.first { $0.id == "a" }?.group == "G")
    #expect(payload.nodes.first { $0.id == "b" }?.group == nil)
    #expect(payload.groups == ["G": "#ff0000"])
}
