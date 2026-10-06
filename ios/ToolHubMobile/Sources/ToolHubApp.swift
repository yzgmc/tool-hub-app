import SwiftUI

@main
struct ToolHubApp: App {
    @StateObject private var store = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)   // 固定浅色（Anthropic 米白主题）
        }
    }
}
