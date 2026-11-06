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

            Section("Spheres") {
                color("Core", \.coreColor)
                color("Packs (fallback)", \.packColor)
                color("Context", \.contextColor)
                color("Memory", \.memoryColor)
                color("Unconnected", \.orphanColor)
                color("Recall", \.recallColor)
                slider("Size", \.nodeSize, 0.4...2.5, format: "%.1f×")
                slider("Opacity", \.nodeOpacity, 0.2...1, format: "%.0f%%", scale: 100)
            }

            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups, id: \.self) { group in
                        ColorPicker(group, selection: Binding(
                            get: { Color(hex: model.groupColor(group)) },
                            set: { model.setGroupColor(group, $0.hex) }
                        ), supportsOpacity: false)
                    }
                    slider("Cluster glow", \.groupGlow, 0...1, format: "%.0f%%", scale: 100)
                }
            }

            Section("Material") {
                slider("Gloss", \.gloss, 0...200, format: "%.0f")
                slider("Reflection", \.reflection, 0...1, format: "%.0f%%", scale: 100)
                slider("Glow", \.glow, 0...1, format: "%.0f%%", scale: 100)
                slider("Glow radius", \.glowSize, 2...12, format: "%.1f")
            }

            Section("Lines") {
                color("Linked", \.manualLinkColor)
                slider("Linked opacity", \.manualLinkOpacity, 0...1, format: "%.0f%%", scale: 100)
                color("Automatic", \.autoLinkColor)
                slider("Automatic opacity", \.autoLinkOpacity, 0...1, format: "%.0f%%", scale: 100)
                slider("Thickness", \.lineWidth, 0...1.2, format: "%.2f")
                Text("0 = hairline").font(.caption).foregroundStyle(.secondary)
                slider("Curvature", \.curvature, 0...0.8, format: "%.2f")
                Toggle("Show automatic connections", isOn: $model.style.showAutoLinks)
            }

            Section("Pulses") {
                slider("Rate", \.pulseRate, 0...30, format: "%.0f/s")
                slider("Size", \.pulseSize, 0.4...4, format: "%.1f")
                slider("Speed", \.pulseSpeed, 0.002...0.04, format: "%.3f")
                color("Colour", \.pulseColor)
            }

            Section("Labels") {
                Picker("Show", selection: $model.style.labels) {
                    ForEach(GraphStyle.LabelMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                slider("Size", \.labelSize, 0.5...2.5, format: "%.1f×")
            }

            Section("Background") {
                color("Inner", \.backgroundInner)
                color("Outer", \.backgroundOuter)
            }

            Section("Motion & layout") {
                slider("Rotation", \.rotation, 0...2, format: "%.1f")
                slider("Spacing", \.spread, 0.5...2.5, format: "%.1f×")
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
