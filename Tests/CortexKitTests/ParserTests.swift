import Testing
@testable import CortexKit

@Test func frontmatterScalarsAndLists() {
    let text = "---\ntags: [projekt, ai]\nstatus: aktiv\naliases:\n  - Foo\n  - \"Bar\"\n---\n# Body"
    let (fm, body) = Parser.frontmatter(text)
    #expect(fm["tags"] == .list(["projekt", "ai"]))
    #expect(fm["status"]?.string == "aktiv")
    #expect(fm["aliases"] == .list(["Foo", "Bar"]))
    #expect(body == "# Body")
}

@Test func noFrontmatterKeepsBody() {
    let (fm, body) = Parser.frontmatter("# Just text\n---\nnot yaml")
    #expect(fm.isEmpty)
    #expect(body == "# Just text\n---\nnot yaml")
}

@Test func wikilinksStripAliasHeadingPathAndAttachments() {
    let links = Parser.wikilinks("[[Schreibstil]] [[ICP|Kunden]] [[Karriere#Ziele]] [[03 Bereiche/Fitness.md]] ![[image.png]] [[schreibstil]]")
    #expect(links == ["schreibstil", "icp", "karriere", "fitness"])
}

@Test func layerInference() {
    #expect(Parser.layer(relativePath: "00 Kontext/Schreibstil.md", frontmatter: [:]) == .core)
    #expect(Parser.layer(relativePath: "02 Projekte/Cortex.md", frontmatter: ["status": .string("aktiv")]) == .context)
    #expect(Parser.layer(relativePath: "02 Projekte/Alt.md", frontmatter: ["status": .string("abgeschlossen")]) == .memory)
    #expect(Parser.layer(relativePath: "04 Ressourcen/AI/X.md", frontmatter: [:]) == .memory)
    #expect(Parser.layer(relativePath: "04 Ressourcen/X.md", frontmatter: ["layer": .string("core")]) == .core)
}
