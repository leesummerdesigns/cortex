import SwiftUI

struct StyleInspector: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Presets") {
                HStack {
                    ForEach(GraphStyle.presets, id: \.name) { preset in
                        Button(preset.name) { model.style = preset.style }
                    }
                }
            }

            Section("Notes") {
                color("Core", \.coreColor)
                color("Persona", \.personaColor)
                color("Context", \.contextColor)
                color("Memory", \.memoryColor)
                color("Unconnected", \.orphanColor)
                color("Packs", \.packColor)
                color("Recall", \.recallColor)
                slider("Size", \.nodeSize, 0.5...2, format: "%.1f×")
            }

            Section("Groups") {
                ForEach(model.groups, id: \.self) { group in
                    ColorPicker(group, selection: Binding(
                        get: { Color(hex: model.groupColor(group)) },
                        set: { model.setGroupColor(group, $0.hex) }
                    ), supportsOpacity: false)
                }
                slider("Nebula", \.nebula, 0...2, format: "%.0f%%", scale: 100)
                if model.groups.isEmpty {
                    Text("Give notes a group in the note inspector, e.g. Finances or Career, and they gather in a nebula.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Lines") {
                color("Linked", \.manualLinkColor)
                slider("Linked opacity", \.manualLinkOpacity, 0...1, format: "%.0f%%", scale: 100)
                color("Automatic", \.autoLinkColor)
                slider("Automatic opacity", \.autoLinkOpacity, 0...0.5, format: "%.0f%%", scale: 100)
                Toggle("Show automatic connections", isOn: $model.style.showAutoLinks)
            }

            Section("Impulses") {
                slider("Rate", \.pulseRate, 0...20, format: "%.0f/s")
                color("Colour", \.pulseColor)
            }

            Section("Labels") {
                Picker("Show", selection: $model.style.labels) {
                    ForEach(GraphStyle.LabelMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                slider("Size", \.labelSize, 0.7...1.8, format: "%.1f×")
            }

            Section("Map") {
                color("Background", \.background)
                slider("Spacing", \.spread, 0.6...2, format: "%.1f×")
            }

            Section {
                Button("Reset to default") { model.style = GraphStyle() }
            }
        }
        .formStyle(.grouped)
    }

    private func color(_ title: String, _ key: WritableKeyPath<GraphStyle, String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(hex: model.style[keyPath: key]) },
            set: { model.style[keyPath: key] = $0.hex }
        ), supportsOpacity: false)
    }

    private func slider(_ title: String, _ key: WritableKeyPath<GraphStyle, Double>, _ range: ClosedRange<Double>,
                        format: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { model.style[keyPath: key] }, set: { model.style[keyPath: key] = $0 }), in: range)
                Text(String(format: format, model.style[keyPath: key] * scale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
