import CortexKit
import SwiftUI

enum Theme {
    static func name(_ layer: Layer) -> String {
        switch layer {
        case .core: "Core"
        case .context: "Context"
        case .memory: "Memory"
        case .pack: "Packs"
        }
    }

    static func caption(_ layer: Layer) -> String {
        switch layer {
        case .core: "Always loaded"
        case .context: "When relevant"
        case .memory: "On search"
        case .pack: "Installed expertise"
        }
    }
}

extension EnvironmentValues {
    @Entry var graphStyle = GraphStyle()
}

extension GraphStyle {
    func color(_ layer: Layer) -> Color {
        switch layer {
        case .core: Color(hex: coreColor)
        case .context: Color(hex: contextColor)
        case .memory: Color(hex: memoryColor)
        case .pack: Color(hex: packColor)
        }
    }
}

/// Sidebar/legend dot in the note's current graph colour (packs use their own colour).
struct LayerDot: View {
    let layer: Layer
    var size: CGFloat = 8
    var hex: String?
    @Environment(\.graphStyle) private var style

    var body: some View {
        Circle()
            .fill(hex.map { Color(hex: $0) } ?? style.color(layer))
            .frame(width: size, height: size)
    }
}
