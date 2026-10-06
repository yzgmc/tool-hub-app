import SwiftUI

/// 总览：子应用健康 + 外部服务快捷管理。
struct DashboardView: View {
    @EnvironmentObject private var store: SettingsStore

    @State private var overview: Overview?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let o = overview {
                        healthCard(o)
                        servicesCard(o)
                    } else if loading {
                        ProgressView().padding(.top, 80)
                    } else if let e = error {
                        ErrorRetryView(message: e) { Task { await fetch() } }
                            .padding(.top, 80)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(store.manifest?.name ?? "总览")
            .refreshable { await fetch() }
            .task { await fetch() }
            .task(id: "dashboard-timer") {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await fetch(silent: true)
                }
            }
        }
    }

    // ------------------------------------------------------------ 子应用健康
    private func healthCard(_ o: Overview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("子应用健康")
                Spacer()
                Text("\(o.health?.up ?? 0)/\(o.health?.total ?? 0) 在线")
                    .font(.caption).foregroundColor(
                        (o.health?.up ?? 0) == (o.health?.total ?? 0) ? Theme.ok : Theme.sub)
            }
            let tools = o.health?.tools ?? []
            if tools.isEmpty {
                Text("暂无数据").font(.footnote).foregroundColor(Theme.sub)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(tools) { t in
                        HStack(spacing: 8) {
                            Circle()
                                .fill((t.up ?? false) ? Theme.ok : Theme.line)
                                .frame(width: 8, height: 8)
                            Text(ServiceNames.name(t.id ?? ""))
                                .font(.footnote)
                                .foregroundColor(Theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                    }
                }
            }
        }
        .padding(16)
        .card()
    }

    // ------------------------------------------------------------ 外部服务
    private func servicesCard(_ o: Overview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("外部服务")
            let sids = (o.services?.states ?? [:]).sorted { $0.key < $1.key }
            if sids.isEmpty {
                Text("暂无数据").font(.footnote).foregroundColor(Theme.sub)
            }
            ForEach(sids, id: \.key) { sid, st in
                HStack(spacing: 10) {
                    Circle()
                        .fill((st.running ?? false) ? Theme.ok : Theme.line)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ServiceNames.name(sid))
                            .font(.subheadline).foregroundColor(Theme.ink)
                        if let p = st.port {
                            Text("端口 \(p)").font(.caption2).foregroundColor(Theme.sub)
                        }
                    }
                    Spacer()
                    if st.controllable == true {
                        ServiceActionMenu(sid: sid, running: st.running ?? false) {
                            Task { await fetch(silent: true) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .card()
    }

    private func fetch(silent: Bool = false) async {
        if !silent { loading = overview == nil }
        defer { loading = false }
        do {
            overview = try await store.client.overview()
            error = nil
        } catch {
            if !silent { self.error = error.localizedDescription }
            if case APIError.unauthorized = error { store.lastError = error.localizedDescription }
        }
    }
}

/// 单个服务的启停菜单（带二次确认与结果弹窗）
struct ServiceActionMenu: View {
    @EnvironmentObject private var store: SettingsStore
    let sid: String
    let running: Bool
    var onDone: () -> Void

    @State private var busy = false
    @State private var confirmAction: String?
    @State private var result: ServiceResult?
    @State private var fail: String?

    var body: some View {
        Menu {
            if running {
                Button(role: .destructive) { confirmAction = "stop" } label: { Text("⏹ 停止") }
                Button { confirmAction = "restart" } label: { Text("🔄 重启") }
            } else {
                Button { confirmAction = "start" } label: { Text("▶️ 启动") }
            }
        } label: {
            if busy {
                ProgressView().padding(6)
            } else {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(Theme.sub)
            }
        }
        .confirmationDialog(
            "确定要\(actionName(confirmAction ?? ""))「\(ServiceNames.name(sid))」吗？",
            isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }),
            titleVisibility: .visible
        ) {
            Button(actionName(confirmAction ?? ""), role: confirmAction == "start" ? nil : .destructive) {
                if let a = confirmAction { Task { await run(a) } }
            }
            Button("取消", role: .cancel) { confirmAction = nil }
        }
        .alert("操作结果", isPresented: Binding(get: { result != nil || fail != nil },
                                          set: { if !$0 { result = nil; fail = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(result?.summary ?? fail ?? "")
        }
    }

    private func actionName(_ a: String) -> String {
        switch a {
        case "start": return "启动"
        case "stop": return "停止"
        case "restart": return "重启"
        default: return "操作"
        }
    }

    private func run(_ action: String) async {
        confirmAction = nil
        busy = true
        defer { busy = false }
        do {
            result = try await store.client.serviceAction(sid, action)
            onDone()
        } catch {
            fail = error.localizedDescription
        }
    }
}

/// 通用错误 + 重试
struct ErrorRetryView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("⚠️").font(.largeTitle)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.danger)
                .multilineTextAlignment(.center)
            Button {
                retry()
            } label: {
                Text("重试")
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                    .foregroundColor(.white)
            }
        }
        .padding()
    }
}
