import SwiftUI

/// 主界面：4 个固定标签 + 最多 2 个钉选插件动态标签。
/// 每 30 秒轮询清单版本，变化即自动同步（OTA）。
struct MainTabView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .tabItem { Label("总览", systemImage: "house") }
                .tag(0)

            ServicesView()
                .tabItem { Label("服务", systemImage: "gearshape.2") }
                .tag(1)

            PluginsView()
                .tabItem { Label("插件", systemImage: "square.grid.2x2") }
                .tag(2)

            SettingsTabView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)

            ForEach(Array(store.manifest?.pinnedPlugins.enumerated() ?? [].enumerated()),
                    id: \.element.id) { idx, p in
                NavigationStack { PluginPageView(plugin: p) }
                    .tabItem {
                        Label { Text(p.displayName) } icon: { Text(p.displayIcon) }
                    }
                    .tag(4 + idx)
            }
        }
        .task { await syncLoop() }
    }

    /// OTA 同步循环：每 30 秒查一次版本号，变化即拉新清单
    private func syncLoop() async {
        // 进前台先同步一次
        await store.syncManifest()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await store.checkVersion()
        }
    }
}

/// 设置页（第 4 个固定标签）
struct SettingsTabView: View {
    @EnvironmentObject private var store: SettingsStore

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var syncing = false
    @State private var message: String?
    @State private var ok = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 连接配置
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("连接")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("服务器地址").font(.footnote).foregroundColor(Theme.sub)
                            TextField("http://…", text: $url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Token").font(.footnote).foregroundColor(Theme.sub)
                            TextField("X-ToolHub-Token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                        }
                        HStack(spacing: 12) {
                            Button {
                                store.saveConfig(url, token)
                                Task { await manualSync() }
                            } label: {
                                Text("保存")
                                    .padding(.horizontal, 20).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                                    .foregroundColor(.white)
                            }
                            Button(role: .destructive) {
                                store.reset()
                            } label: {
                                Text("断开并清除")
                                    .padding(.horizontal, 20).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.12)))
                                    .foregroundColor(Theme.danger)
                            }
                        }
                    }
                    .padding(16)
                    .card()

                    // 同步状态
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("同步")
                        keyValue("清单版本", store.manifestVersionText)
                        keyValue("插件数量", "\(store.manifest?.plugins?.count ?? 0)")
                        keyValue("上次同步", store.lastSync.map {
                            $0.formatted(date: .abbreviated, time: .standard)
                        } ?? "从未")
                        if let e = store.lastError {
                            Text(e).font(.footnote).foregroundColor(Theme.danger)
                        }
                        Button {
                            Task { await manualSync() }
                        } label: {
                            HStack {
                                if syncing { ProgressView().tint(.white) }
                                Text(syncing ? "同步中…" : "立即同步")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink))
                            .foregroundColor(.white)
                        }
                        if let m = message {
                            Text(m).font(.footnote).foregroundColor(ok ? Theme.ok : Theme.danger)
                        }
                    }
                    .padding(16)
                    .card()

                    Text("OTA 机制：服务器插件目录变化后，App 每 30 秒自动检测并同步，无需重新安装。")
                        .font(.caption).foregroundColor(Theme.sub)
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("设置")
            .onAppear {
                url = store.serverURL
                token = store.token
            }
        }
    }

    private func keyValue(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundColor(Theme.sub)
            Spacer()
            Text(v).font(.subheadline).foregroundColor(Theme.ink)
        }
    }

    private func manualSync() async {
        syncing = true
        message = nil
        defer { syncing = false }
        await store.syncManifest()
        if let e = store.lastError {
            ok = false
            message = e
        } else {
            ok = true
            message = "同步成功，共 \(store.manifest?.plugins?.count ?? 0) 个插件"
        }
    }
}
