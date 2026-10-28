import SwiftUI

@main struct ToolHubApp: App {
    @StateObject private var store = HubStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(.blue)
                .onOpenURL { store.receive($0) }
        }
    }
}

struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

struct CanvasBackground: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .overlay(alignment: .topTrailing) {
                RadialGradient(colors: [.blue.opacity(0.12), .clear], center: .topTrailing,
                               startRadius: 10, endRadius: 420)
            }.ignoresSafeArea()
    }
}

struct RootView: View {
    @EnvironmentObject var store: HubStore
    @Environment(\.scenePhase) var phase
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            LibraryView().tabItem { Label("工具", systemImage: "square.grid.2x2") }.tag(0)
            ActivityView().tabItem { Label("活动", systemImage: "clock.arrow.circlepath") }.tag(1)
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }.tag(2)
        }
        .task {
            if !store.configured { tab = 2 }
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                if phase == .active { await store.refresh() }
            }
        }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await store.refresh() } }
        }
        .sheet(isPresented: Binding(get: { store.pendingConnection != nil }, set: { if !$0 { store.pendingConnection = nil } })) {
            NavigationStack {
                SettingsView(incoming: store.pendingConnection)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { store.pendingConnection = nil } } }
            }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var store: HubStore
    @Environment(\.dynamicTypeSize) var typeSize
    @State private var query = ""
    @State private var category = "全部"
    var categories: [String] { ["全部", "收藏"] + Array(Set(store.plugins.map(\.category))).sorted() }
    var filtered: [Plugin] {
        store.plugins.filter {
            (category == "全部" || category == "收藏" && store.favorites.contains($0.id) || $0.category == category)
            && (query.isEmpty || ($0.name + $0.subtitle + $0.category).localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        Image(systemName: store.error == nil && store.configured ? "point.3.connected.trianglepath.dotted" : "network")
                            .font(.title2).foregroundStyle(.blue).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.configured ? "你的工具，随手可用。" : "连接后，工具就在这里。").font(.headline)
                            Text(store.updatedAt.map { "已同步 \(store.plugins.count) 个工具 · " + $0.formatted(date: .omitted, time: .shortened) } ?? "在设置中连接你的总控台")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(18).modifier(GlassSurface())
                    if let error = store.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                            if store.catalog != nil { Text("当前显示上次同步的目录。").font(.caption) }
                            Button("重试") { Task { await store.refresh() } }.frame(minHeight: 44)
                        }.foregroundStyle(.orange).padding().background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories, id: \.self) { item in
                                Button { category = item } label: {
                                    HStack(spacing: 5) {
                                        if item == "收藏" { Image(systemName: "star.fill") }
                                        Text(item)
                                    }.font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(minHeight: 44)
                                        .background(category == item ? Color.primary : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                        .foregroundStyle(category == item ? Color(uiColor: .systemBackground) : .primary)
                                }.buttonStyle(.plain).accessibilityAddTraits(category == item ? .isSelected : [])
                            }
                        }
                    }
                    if store.loading && store.catalog == nil {
                        ProgressView("正在同步工具…").frame(maxWidth: .infinity, minHeight: 200)
                    } else if filtered.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "这里还没有工具" : "没有找到相关工具", systemImage: "square.grid.2x2",
                            description: Text(query.isEmpty ? "连接服务器后下拉刷新，获取最新工具。" : "换个名称，或查看其他分类。"))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 154), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { plugin in
                                NavigationLink(value: plugin) { PluginCard(plugin: plugin) }
                                    .buttonStyle(.plain)
                                    .contextMenu { Button(store.favorites.contains(plugin.id) ? "取消收藏" : "收藏", systemImage: "star") { store.toggleFavorite(plugin.id) } }
                            }
                        }
                    }
                    if !filtered.isEmpty { Text("\(filtered.count) 个工具").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }.padding(20)
            }
            .background { CanvasBackground() }
            .navigationTitle("工具")
            .searchable(text: $query, prompt: "搜索你的工具")
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh() } } label: {
                        if store.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }.disabled(store.loading || !store.configured).accessibilityLabel("刷新工具")
                }
            }
            .navigationDestination(for: Plugin.self) { plugin in
                PluginDetailView(plugin: store.plugins.first(where: { $0.id == plugin.id }) ?? plugin)
            }
        }
    }
}

struct PluginCard: View {
    let plugin: Plugin
    @EnvironmentObject var store: HubStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: plugin.symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(.blue)
                    .frame(width: 48, height: 48).background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 15)).accessibilityHidden(true)
                Spacer()
                if store.favorites.contains(plugin.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(plugin.name).font(.headline).foregroundStyle(.primary).lineLimit(2).frame(minHeight: 44, alignment: .topLeading)
                Text(plugin.configured ? plugin.category : "原生能力待配置").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 5) {
                Circle().fill(store.online(plugin).map { $0 ? Color.green : Color.gray } ?? .orange).frame(width: 6, height: 6)
                Text(store.online(plugin).map { $0 ? "在线" : "已停止" } ?? "状态待同步").font(.caption2).foregroundStyle(.secondary)
                Spacer(); Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .combine)
    }
}

struct ActivityView: View {
    @EnvironmentObject var store: HubStore
    var body: some View {
        NavigationStack {
            List {
                if store.activities.isEmpty {
                    ContentUnavailableView("还没有操作记录", systemImage: "clock", description: Text("工具操作的结果会显示在这里。"))
                }
                ForEach(store.activities) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(entry.success ? .green : .orange).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.headline)
                            Text(entry.detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
            }.navigationTitle("活动")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: HubStore
    var incoming: Connection? = nil
    @State private var server = ""
    @State private var token = ""
    @State private var busy = false
    @State private var message: String?
    @State private var succeeded = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("ToolHub", systemImage: "square.stack.3d.up.fill").font(.title2.weight(.semibold)).padding(.vertical, 8)
                    Text("一个入口，连接你的所有工具。").foregroundStyle(.secondary)
                }
                Section {
                    TextField("服务器地址", text: $server).textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("serverAddress")
                    SecureField("连接令牌", text: $token).textContentType(.password).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("connectionToken")
                    Button {
                        busy = true; message = nil
                        Task {
                            do {
                                try await store.connect(Connection(server: server.trimmingCharacters(in: .whitespacesAndNewlines), token: token))
                                succeeded = true; message = "连接成功，已同步 \(store.plugins.count) 个工具。"; store.pendingConnection = nil
                            } catch { succeeded = false; message = error.localizedDescription }
                            busy = false
                        }
                    } label: {
                        HStack { Text(busy ? "正在连接…" : "连接并同步"); Spacer(); if busy { ProgressView() } else { Image(systemName: "arrow.right") } }
                    }.disabled(busy || server.isEmpty).frame(minHeight: 44)
                    if let message { Label(message, systemImage: succeeded ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(succeeded ? .green : .orange) }
                } header: { Text("连接服务器") } footer: { Text("填写手机可访问的总控台手机网关地址。令牌只保存在本机钥匙串中。") }
                Section("关于") {
                    LabeledContent("版本", value: "2.0 · 原生重构")
                    LabeledContent("工具同步", value: "下拉刷新 · 前台自动同步")
                    LabeledContent("外观", value: "跟随系统")
                    if let catalog = store.catalog { LabeledContent("目录版本", value: catalog.version).font(.footnote) }
                }
            }.navigationTitle("设置")
                .onAppear { server = incoming?.server ?? store.connection.server; token = incoming?.token ?? store.connection.token }
        }
    }
}
