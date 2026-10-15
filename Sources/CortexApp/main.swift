import SwiftUI

struct CortexApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // Single window: cortex:// URLs are delivered to it instead of spawning a new one.
        Window("Cortex", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1480, height: 920)
    }
}

NSApplication.shared.setActivationPolicy(.regular)
CortexApp.main()
