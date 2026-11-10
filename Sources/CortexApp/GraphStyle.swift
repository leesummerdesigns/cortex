import SwiftUI

/// Every visual parameter of the memory map. Sent to the web view as JSON (keys match graph.js `S`).
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

    var background = "#242834"

    // Notes
    var coreColor = "#b6ff00"
    var personaColor = "#7d53ff"
    var contextColor = "#e9ecf2"
    var memoryColor = "#7a8195"
    var orphanColor = "#4a5063"
    var recallColor = "#b6ff00"
    var packColor = "#9aa1b5"
    var nodeSize = 1.0

    // Groups
    var nebula = 1.0          // strength of each group's tinted area

    // Lines
    var manualLinkColor = "#e9ecf2"
    var autoLinkColor = "#e9ecf2"
    var manualLinkOpacity = 0.22
    var autoLinkOpacity = 0.04
    var showAutoLinks = true

    // Impulses: small signals travelling along the lines
    var pulseRate = 5.0       // per second across the whole map
    var pulseColor = "#e9ecf2"

    // Labels & layout
    var labels = LabelMode.context
    var labelSize = 1.0
    var spread = 1.0

    static let presets: [(name: String, style: GraphStyle)] = [
        ("Signal", GraphStyle()),
        ("Graphite", {
            var s = GraphStyle()
            s.background = "#16181d"; s.coreColor = "#f2f2f2"; s.personaColor = "#9a9fad"; s.contextColor = "#c9ccd4"
            s.memoryColor = "#5d626e"; s.orphanColor = "#383b44"; s.recallColor = "#b6ff00"; s.packColor = "#7c818d"
            s.nebula = 0.7; s.manualLinkColor = "#c9ccd4"; s.autoLinkColor = "#c9ccd4"
            return s
        }()),
        ("Paper", {
            var s = GraphStyle()
            s.background = "#f4f2ee"; s.coreColor = "#242834"; s.personaColor = "#7d53ff"; s.contextColor = "#3b4050"
            s.memoryColor = "#9a9ea8"; s.orphanColor = "#c9c8c3"; s.recallColor = "#5a8f00"; s.packColor = "#8a8f9a"
            s.manualLinkColor = "#242834"; s.autoLinkColor = "#242834"; s.manualLinkOpacity = 0.25; s.autoLinkOpacity = 0.06
            s.pulseColor = "#3b4050"
            return s
        }()),
    ]

    /// New key for the 2D map: settings saved for the old 3D graph would bring its colours back.
    private static let defaultsKey = "mapStyle"

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
