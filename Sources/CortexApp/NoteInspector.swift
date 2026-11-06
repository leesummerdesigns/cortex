import CortexKit
import SwiftUI

struct NoteInspector: View {
    @Bindable var model: AppModel
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        if let note = model.selectedNote, let index = model.index {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if note.isProposal { ProposalBanner(model: model, note: note) }
                    header(note)
                    connections(index.neighbours(of: note.id))
                    Divider()
                    if isEditing {
                        TextEditor(text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 420)
                            .scrollContentBackground(.hidden)
                    } else {
                        MarkdownBody(text: note.body)
                    }
                }
                .padding(18)
                .textSelection(.enabled)
            }
            .toolbar {
                ToolbarItemGroup {
                    if isEditing {
                        Button("Cancel") { isEditing = false }
                        Button("Save") {
                            model.save(note, text: draft)
                            isEditing = false
                        }
                        .keyboardShortcut("s")
                    } else if note.pack == nil {
                        Button { startEditing(note) } label: { Label("Edit", systemImage: "pencil") }
                            .keyboardShortcut("e")
                    }
                }
            }
            .onChange(of: note.id) { isEditing = false }
        } else {
            ContentUnavailableView("No memory selected", systemImage: "circle.hexagongrid",
                                   description: Text("Click a sphere in the network or a note in the sidebar."))
        }
    }

    private func header(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LayerDot(layer: note.layer, hex: note.pack?.color)
                Text((note.pack.map { $0.kind == .persona ? "Persona" : "Pack" } ?? Theme.name(note.layer)).uppercased())
                    .font(.caption2.weight(.semibold)).tracking(1.2)
                    .foregroundStyle(note.pack.map { Color(hex: $0.color) } ?? model.style.color(note.layer))
                if let status = note.status, !note.isProposal {
                    Text("· \(status)").font(.caption2).foregroundStyle(.secondary)
                }
                if note.isPrivate {
                    Label("Private", systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(note.title).font(.title2.weight(.semibold))
            Text(note.folder).font(.caption).foregroundStyle(.secondary)
            if !note.tags.isEmpty {
                FlowTags(tags: note.tags)
            }
            HStack(spacing: 14) {
                if note.pack == nil {
                    GroupMenu(model: model, note: note)
                    RevisitMenu(model: model, note: note)
                    Toggle(isOn: Binding(get: { note.isPrivate }, set: { model.setPrivate(note, $0) })) {
                        Text("Private")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Private memories stay visible to you but are never given to AI tools.")
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func connections(_ n: (outgoing: [Note], backlinks: [Note], similar: [(Note, Double)])) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            linkGroup("Links to", notes: n.outgoing)
            linkGroup("Linked from", notes: n.backlinks)
            if !n.similar.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Related (automatic)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(n.similar, id: \.0.id) { note, weight in
                        noteButton(note, trailing: String(format: "%.0f%%", weight * 100))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkGroup(_ title: String, notes: [Note]) -> some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(notes) { noteButton($0) }
            }
        }
    }

    private func noteButton(_ note: Note, trailing: String? = nil) -> some View {
        Button { model.select(note.id) } label: {
            HStack(spacing: 8) {
                LayerDot(layer: note.layer, size: 6, hex: model.dotHex(note))
                Text(note.title).lineLimit(1)
                Spacer()
                if let trailing { Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func startEditing(_ note: Note) {
        draft = (try? String(contentsOf: note.url, encoding: .utf8)) ?? note.body
        isEditing = true
    }
}

/// Asks for the note to come back in Today on a chosen day.
private struct RevisitMenu: View {
    @Bindable var model: AppModel
    let note: Note

    var body: some View {
        Menu {
            ForEach([(1, "week"), (4, "weeks"), (12, "weeks"), (26, "weeks")], id: \.0) { amount, unit in
                Button("In \(amount) \(unit)") {
                    model.setRevisit(note, Calendar.current.date(byAdding: .weekOfYear, value: amount, to: Date()))
                }
            }
            if note.revisit != nil {
                Divider()
                Button("Never") { model.setRevisit(note, nil) }
            }
        } label: {
            Text(note.revisit.map { "Revisit \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Revisit")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Bring this note back in Today on a chosen day.")
    }
}

/// Puts the note into one group (or none); its group gathers in its own coloured cluster on the graph.
private struct GroupMenu: View {
    @Bindable var model: AppModel
    let note: Note
    @State private var isNaming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Menu {
            Button { model.setGroup(note, nil) } label: { item("No group", selected: note.group == nil) }
            if !model.groups.isEmpty { Divider() }
            ForEach(model.groups, id: \.self) { group in
                Button { model.setGroup(note, group) } label: { item(group, selected: note.group == group) }
            }
            Divider()
            Button("New group…") { name = ""; isNaming = true }
        } label: {
            Text(note.group.map { "Group: \($0)" } ?? "No group")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Notes in a group gather in their own coloured cluster on the graph.")
        // A sheet, not an alert: an alert opens with focus on Cancel, so the first space typed would close it.
        .sheet(isPresented: $isNaming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New group").font(.headline)
                Text("“\(note.title)” moves into the new group.").foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .onSubmit(create)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { isNaming = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 320)
            .defaultFocus($nameFocused, true)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        isNaming = false
        model.setGroup(note, trimmedName)
    }

    @ViewBuilder
    private func item(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// AI-proposed memory waiting for review: accept it into memory or discard it.
private struct ProposalBanner: View {
    @Bindable var model: AppModel
    let note: Note

    var body: some View {
        let fire = Color(hex: model.style.recallColor)
        VStack(alignment: .leading, spacing: 10) {
            Label("Proposed by \(note.source ?? "an AI tool")", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(fire)
            Text("Not part of your memory yet. AI tools can't see it until you accept it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { model.accept(note) } label: { Label("Accept", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .tint(fire.opacity(0.85))
                Button(role: .destructive) { model.discard(note) } label: { Label("Discard", systemImage: "trash") }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(fire.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(fire.opacity(0.3)))
    }
}

/// Lightweight block renderer: headings, bullets, quotes; inline Markdown via AttributedString.
struct MarkdownBody: View {
    let text: String
    /// Finds the note a [[wikilink]] points to. Links become clickable when this is set.
    var noteID: ((String) -> String?)? = nil
    @Environment(\.graphStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
    }

    @ViewBuilder
    private func row(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            inline(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Color(hex: style.contextColor))
                inline(String(line.dropFirst(2)))
            }
            .padding(.leading, CGFloat(raw.prefix(while: { $0 == " " || $0 == "\t" }).count) * 6)
        } else if line.hasPrefix(">") {
            inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color(hex: style.contextColor).opacity(0.5)).frame(width: 2) }
        } else {
            inline(line)
        }
    }

    /// Turns [[Title]] into a Markdown link for each note that exists.
    private func linked(_ s: String) -> String {
        guard let noteID else { return s }
        var out = s
        for match in s.matches(of: #/\[\[([^\]\|]+)\]\]/#) {
            let title = String(match.1).trimmingCharacters(in: .whitespaces)
            guard let id = noteID(title),
                  let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { continue }
            out = out.replacingOccurrences(of: String(match.0), with: "[\(title)](cortex://open?id=\(encoded))")
        }
        return out
    }

    private func inline(_ s: String) -> Text {
        let display = linked(s).replacingOccurrences(of: #"\[\[([^\]\|]+)\|([^\]]+)\]\]"#, with: "**$2**", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "**$1**", options: .regularExpression)
        let attributed = (try? AttributedString(markdown: display, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(display)
        return Text(attributed)
    }
}

private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags.prefix(6), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.07)))
            }
        }
    }
}
