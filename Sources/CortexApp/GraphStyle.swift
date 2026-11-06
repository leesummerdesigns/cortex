import SwiftUI

/// Every visual parameter of the graph. Sent to the web view as JSON (keys match graph.js `S`).
struct GraphStyle: Codable, Equatable {
    enum LabelMode: String, Codable, CaseIterable {
        case none, core, context, all
        var title: String {
            switch self {
            case .none: "None"
            case .core: "Core only"
            case .context: "Core + Context"
            case .all: "All"
            }
        }
    }

    // Spheres
    var coreColor = "#f3e9df"
    var contextColor = "#e5484d"
    var memoryColor = "#b8a397"
    var orphanColor = "#5e463c"
    var recallColor = "#ffc21a"
    var packColor = "#5b9bd5"    // fallback for packs without their own colour
    var nodeSize = 1.0
    var nodeOpacity = 1.0

    // Material
    var gloss = 70.0          // Phong shininess: sharpness of the highlight
    var reflection = 0.35     // specular strength
    var glow = 0.0            // halo opacity
    var glowSize = 4.0        // halo radius in node radii
    var groupGlow = 0.35      // opacity of the coloured cloud behind each group's cluster

    // Lines
    var manualLinkColor = "#eb5458"
    var autoLinkColor = "#a0b6b4"
    var manualLinkOpacity = 0.85
    var autoLinkOpacity = 0.5
    var lineWidth = 0.2       // 0 = 1px hairline
    var curvature = 0.0
    var showAutoLinks = true

    // Pulses: small signals travelling along random lines
    var pulseRate = 6.0       // pulses per second across the whole network
    var pulseSize = 1.2
    var pulseSpeed = 0.01
    var pulseColor = "#f3e9df"

    // Labels
    var labels = LabelMode.context
    var labelSize = 1.0

    // Background & motion
    var backgroundInner = "#3a3938"
    var backgroundOuter = "#141414"
    var rotation = 0.3
    var spread = 1.0

    static let presets: [(name: String, style: GraphStyle)] = [
        ("Coral", GraphStyle()),
        ("Calcium", {
            var s = GraphStyle()
            s.coreColor = "#ffc983"; s.contextColor = "#b9c6cf"; s.memoryColor = "#5d6d7b"; s.orphanColor = "#2c343c"
            s.recallColor = "#7dffa8"; s.gloss = 10; s.reflection = 0.05; s.glow = 0.6; s.glowSize = 6
            s.manualLinkColor = "#e8d6ba"; s.autoLinkColor = "#78aac8"; s.manualLinkOpacity = 0.4; s.autoLinkOpacity = 0.18
            s.lineWidth = 0; s.labels = .core; s.backgroundInner = "#0b1016"; s.backgroundOuter = "#020304"; s.pulseColor = "#7dffa8"; s.pulseRate = 10
            return s
        }()),
        ("Blueprint", {
            var s = GraphStyle()
            s.coreColor = "#ffffff"; s.contextColor = "#7cc4ff"; s.memoryColor = "#3f6c99"; s.orphanColor = "#24405e"
            s.recallColor = "#ff8a3d"; s.gloss = 20; s.reflection = 0.15
            s.manualLinkColor = "#9fd3ff"; s.autoLinkColor = "#5b88b5"; s.manualLinkOpacity = 0.7; s.autoLinkOpacity = 0.35
            s.lineWidth = 0.1; s.curvature = 0.25; s.backgroundInner = "#173356"; s.backgroundOuter = "#06101d"
            return s
        }()),
        ("Paper", {
            var s = GraphStyle()
            s.coreColor = "#1d1d1f"; s.contextColor = "#d23c3c"; s.memoryColor = "#8c8279"; s.orphanColor = "#c9c0b6"
            s.recallColor = "#2f6bff"; s.gloss = 40; s.reflection = 0.2
            s.manualLinkColor = "#d23c3c"; s.autoLinkColor = "#6f6a65"; s.manualLinkOpacity = 0.6; s.autoLinkOpacity = 0.3
            s.lineWidth = 0.12; s.backgroundInner = "#f7f3ee"; s.backgroundOuter = "#d8d0c6"
            return s
        }()),
    ]

    private static let defaultsKey = "graphStyle"

    static func load() -> GraphStyle {
        // Merge saved values over the defaults, so settings survive when new parameters are added.
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(GraphStyle())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new }),
              let style = try? JSONDecoder().decode(GraphStyle.self, from: merged) else { return GraphStyle() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
