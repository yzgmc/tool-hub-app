import SwiftUI

/// 插件网格：清单里的全部插件，2 列卡片。点击进入原生页或 WebView。
struct PluginsView: View {
    @EnvironmentObject private var store: SettingsStore

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    let plugins = store.manifest?.plugins ?? []
                    Text("已同步 \(plugins.count) 个插件 · 版本 \(store.manifestVersionText)")
                        .font(.caption).foregroundColor(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(plugins) { p in
                            NavigationLink {
                                if p.isNative {
                                    PluginPageView(plugin: p)
                                } else {
                                    WebPluginView(plugin: p)
                                }
                            } label: {
                                PluginCard(plugin: p)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if plugins.isEmpty {
                        VStack(spacing: 10) {
                            Text("📦").font(.largeTitle)
                            Text("暂无插件，下拉刷新同步")
                                .font(.footnote).foregroundColor(Theme.sub)
                        }
                        .padding(.top, 80)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("插件")
            .refreshable { await store.syncManifest() }
        }
    }
}

struct PluginCard: View {
    let plugin: Plugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plugin.displayIcon).font(.system(size: 30))
                Spacer()
                Text(plugin.tag ?? "插件")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((plugin.color ?? "").themeColor))
            }
            Text(plugin.displayName)
                .font(.subheadline).foregroundColor(Theme.ink)
                .lineLimit(1)
            Text(plugin.desc ?? "")
                .font(.caption2).foregroundColor(Theme.sub)
                .lineLimit(2)
                .frame(minHeight: 28, alignment: .top)
            HStack(spacing: 4) {
                Image(systemName: plugin.isNative ? "sparkles" : "safari")
                    .font(.caption2)
                Text(plugin.isNative ? "原生" : "网页")
            }
            .font(.caption2)
            .foregroundColor(Theme.accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
