import SwiftUI

/// 原生插件页：按 manifest 的 pages 分段，逐个渲染 widget。
struct PluginPageView: View {
    @EnvironmentObject private var store: SettingsStore
    let plugin: Plugin

    @State private var pageIndex = 0

    private var pages: [PluginPage] { plugin.pages ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if pages.isEmpty {
                    VStack(spacing: 10) {
                        Text("🧩").font(.largeTitle)
                        Text("该插件没有声明页面布局")
                            .font(.footnote).foregroundColor(Theme.sub)
                    }
                    .padding(.top, 80)
                } else {
                    if pages.count > 1 {
                        Picker("页面", selection: $pageIndex) {
                            ForEach(Array(pages.enumerated()), id: \.offset) { i, pg in
                                Text(pg.title ?? "页 \(i + 1)").tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 2)
                    }
                    if pageIndex < pages.count {
                        let layout = pages[pageIndex].layout ?? []
                        ForEach(Array(layout.enumerated()), id: \.offset) { _, spec in
                            WidgetContainer(spec: spec)
                        }
                    }
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.15), value: pageIndex)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(plugin.displayName)
        .onAppear { pageIndex = min(pageIndex, max(pages.count - 1, 0)) }
    }
}
