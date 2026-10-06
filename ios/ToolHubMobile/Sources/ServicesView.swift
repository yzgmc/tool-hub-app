import SwiftUI

/// 服务管理：外部服务状态 + 启停按钮组（比总览页更全的操作入口）。
struct ServicesView: View {
    @EnvironmentObject private var store: SettingsStore

    @State private var overview: Overview?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let o = overview {
                        let sids = (o.services?.states ?? []).sorted { $0.key < $1.key }
                        Text("共 \(o.services?.total ?? sids.count) 个服务 · \(o.services?.controllable ?? 0) 个可控")
                            .font(.caption).foregroundColor(Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(sids, id: \.key) { sid, st in
                            ServiceRow(sid: sid, st: st) {
                                Task { await fetch(silent: true) }
                            }
                        }
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
            .navigationTitle("服务")
            .refreshable { await fetch() }
            .task { await fetch() }
        }
    }

    private func fetch(silent: Bool = false) async {
        if !silent { loading = overview == nil }
        defer { loading = false }
        do {
            overview = try await store.client.overview()
            error = nil
        } catch {
            if !silent { self.error = error.localizedDescription }
        }
    }
}

struct ServiceRow: View {
    @EnvironmentObject private var store: SettingsStore
    let sid: String
    let st: ServiceState
    var onChanged: () -> Void

    @State private var busyAction: String?
    @State private var confirmAction: String?
    @State private var result: ServiceResult?
    @State private var fail: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill((st.running ?? false) ? Theme.ok : Theme.line)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ServiceNames.name(sid))
                        .font(.subheadline).foregroundColor(Theme.ink)
                    HStack(spacing: 8) {
                        if let p = st.port { Text(":\(p)") }
                        Text(st.running == true ? "运行中" : "已停止")
                    }
                    .font(.caption2).foregroundColor(Theme.sub)
                }
                Spacer()
                if busyAction != nil { ProgressView() }
            }
            if st.controllable == true {
                HStack(spacing: 10) {
                    actionButton("启动", "play.fill", "start", enabled: st.running != true)
                    actionButton("停止", "stop.fill", "stop", enabled: st.running == true, danger: true)
                    actionButton("重启", "arrow.clockwise", "restart", enabled: true)
                }
            } else {
                Text("只读监控（未配置启停）")
                    .font(.caption2).foregroundColor(Theme.sub)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
            Button("好", role: .cancel) { result = nil; fail = nil }
        } message: {
            Text(result?.summary ?? fail ?? "")
        }
    }

    private func actionButton(_ label: String, _ icon: String, _ action: String,
                              enabled: Bool, danger: Bool = false) -> some View {
        Button {
            confirmAction = action
        } label: {
            Label(label, systemImage: icon)
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(enabled ? (danger ? Theme.danger.opacity(0.12) : Theme.bg) : Theme.bg.opacity(0.5)))
                .foregroundColor(enabled ? (danger ? Theme.danger : Theme.ink) : Theme.line)
        }
        .disabled(!enabled || busyAction != nil)
    }

    private func actionName(_ a: String) -> String {
        ["start": "启动", "stop": "停止", "restart": "重启"][a] ?? "操作"
    }

    private func run(_ action: String) async {
        confirmAction = nil
        busyAction = action
        defer { busyAction = nil }
        do {
            result = try await store.client.serviceAction(sid, action)
            onChanged()
        } catch {
            fail = error.localizedDescription
        }
    }
}
