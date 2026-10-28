import SwiftUI
import Charts

struct PluginDetailView: View {
    let plugin: Plugin
    @EnvironmentObject var store: HubStore
    @State private var page = 0
    @State private var refreshID = UUID()
    @State private var serviceAction: String?
    @State private var busy = false
    @State private var result: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: plugin.symbol).font(.largeTitle).foregroundStyle(.blue).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plugin.category).font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                        Text(plugin.subtitle.isEmpty ? "连接你的服务器工具" : plugin.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).modifier(GlassSurface())
                if plugin.controllable {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(store.online(plugin) == true ? "服务正在运行" : "服务已停止或状态待同步", systemImage: "server.rack").font(.headline)
                        HStack {
                            ForEach(["start", "stop", "restart"], id: \.self) { action in
                                Button(action == "start" ? "启动" : action == "stop" ? "停止" : "重启") { serviceAction = action }
                                    .buttonStyle(.bordered).frame(minHeight: 44).disabled(busy)
                            }
                            if busy { ProgressView() }
                        }
                        if let result { Text(result).font(.subheadline).textSelection(.enabled) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                if plugin.pages.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(plugin.pages.indices, id: \.self) { i in
                                Button(plugin.pages[i].title ?? "页面 \(i + 1)") { page = i }
                                    .buttonStyle(.bordered).tint(page == i ? .blue : .secondary).frame(minHeight: 44)
                            }
                        }
                    }
                }
                if plugin.pages.indices.contains(page) {
                    VStack(spacing: 16) {
                        ForEach(Array(plugin.pages[page].layout.enumerated()), id: \.offset) { _, spec in
                            NativeWidget(spec: spec, refreshID: refreshID)
                        }
                    }.id(page)
                }
                ForEach(plugin.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }.padding(20)
        }.background { CanvasBackground() }.navigationTitle(plugin.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.toggleFavorite(plugin.id) } label: { Image(systemName: store.favorites.contains(plugin.id) ? "star.fill" : "star") }
                        .accessibilityLabel(store.favorites.contains(plugin.id) ? "取消收藏" : "收藏工具")
                }
            }
            .refreshable { refreshID = UUID(); await store.refresh() }
            .confirmationDialog("确认服务操作", isPresented: Binding(get: { serviceAction != nil }, set: { if !$0 { serviceAction = nil } }), titleVisibility: .visible) {
                if let action = serviceAction {
                    Button("确认\(action == "start" ? "启动" : action == "stop" ? "停止" : "重启")", role: action == "stop" ? .destructive : nil) {
                        busy = true
                        Task {
                            do {
                                _ = try await store.api.json("/api/v1/services/\(plugin.id)/actions/\(action)", method: "POST")
                                result = "操作已完成"; store.log(plugin.name, detail: "服务操作已完成", success: true)
                                await store.refresh()
                            } catch { result = error.localizedDescription; store.log(plugin.name, detail: error.localizedDescription, success: false) }
                            busy = false
                        }
                    }
                }
                Button("取消", role: .cancel) { serviceAction = nil }
            } message: { Text("此操作会影响服务器上的 \(plugin.name)。") }
    }
}

struct Sample: Identifiable { let id = UUID(); let date = Date(); let value: Double }
struct ChatLine: Identifiable { let id = UUID(); let text: String; let user: Bool }

struct NativeWidget: View {
    let spec: JSON
    let refreshID: UUID
    @EnvironmentObject var store: HubStore
    @Environment(\.scenePhase) var phase
    @State private var data: JSON = .null
    @State private var busy = false
    @State private var loading = false
    @State private var error: String?
    @State private var feedback: String?
    @State private var samples: [Sample] = []
    @State private var pendingAction: JSON?
    @State private var text = ""
    @State private var messages: [ChatLine] = []
    @State private var fields: [String: String] = [:]
    @State private var shared: SharedFile?
    var kind: String { spec["type"].text }
    var title: String { spec["title"].text }
    var rows: [JSON] {
        if !spec["listPath"].text.isEmpty { return data.value(at: spec["listPath"].text).array }
        if case .array(let a) = data { return a }
        for key in ["items", "data", "rows", "devices", "containers", "files", "jobs"] {
            if case .array(let a) = data[key] { return a }
        }
        return []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !title.isEmpty { Text(title).font(.headline) }
            if loading && data == .null && kind != "actions" { ProgressView("正在获取…").font(.footnote) }
            if kind == "notice" {
                Label(spec["text"].text, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
            } else if kind == "stats" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 20) {
                    ForEach(Array(spec["items"].array.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item["label"].text).font(.caption).foregroundStyle(.secondary)
                            Text(display(item["value"].text) + item["unit"].text).font(.title2.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            } else if kind == "gauge" || kind == "progress" {
                let value = data.value(at: spec["value"].text).number
                let maximum = spec["max"].number > 0 ? spec["max"].number : 100
                ProgressView(value: min(max(value, 0), maximum), total: maximum) {
                    Text(spec["status"].text.isEmpty ? "当前使用" : display(spec["status"].text)).font(.subheadline).foregroundStyle(.secondary)
                } currentValueLabel: { Text(String(format: "%.1f", value) + spec["unit"].text).monospacedDigit() }
            } else if kind == "chart" {
                if samples.isEmpty { Text("等待数据…").foregroundStyle(.secondary) }
                Chart(samples) { sample in
                    LineMark(x: .value("时间", sample.date), y: .value("数值", sample.value)).foregroundStyle(.blue)
                    PointMark(x: .value("时间", sample.date), y: .value("数值", sample.value)).foregroundStyle(.blue)
                }.frame(height: 160).accessibilityLabel(title.isEmpty ? "实时曲线" : title)
            } else if kind == "list" {
                if rows.isEmpty && !loading { Text("暂无数据").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(Array(rows.prefix(100).enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(display(spec["item"]["title"].text, in: row, fallback: "条目 \(index + 1)")).font(.subheadline.weight(.medium))
                                if !spec["item"]["subtitle"].text.isEmpty {
                                    Text(display(spec["item"]["subtitle"].text, in: row)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if !spec["item"]["value"].text.isEmpty {
                                Text(display(spec["item"]["value"].text, in: row) + spec["item"]["valueUnit"].text).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if !spec["item"]["actions"].array.isEmpty {
                            HStack {
                                ForEach(Array(spec["item"]["actions"].array.enumerated()), id: \.offset) { _, action in
                                    actionButton(action, row: row)
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                    if index < min(rows.count, 100) - 1 { Divider() }
                }
                if rows.count > 100 { Text("已显示前 100 项").font(.caption).foregroundStyle(.secondary) }
            } else if kind == "keyvalue" || kind == "auto" {
                if !spec["items"].array.isEmpty {
                    ForEach(Array(spec["items"].array.enumerated()), id: \.offset) { _, item in
                        if case .object = item { LabeledContent(item["label"].text, value: display(item["value"].text)) }
                        else { LabeledContent(item.text.replacingOccurrences(of: "$.", with: ""), value: display(item.text)) }
                    }
                } else { JSONTree(value: data) }
            } else if kind == "actions" {
                ViewThatFits(in: .horizontal) {
                    HStack { actionButtons }
                    VStack(alignment: .leading) { actionButtons }
                }
            } else if kind == "upload" {
                NativeUpload(spec: spec) { refreshResult in feedback = refreshResult }
            } else if kind == "imagegrid" {
                if rows.isEmpty && !loading { Text("还没有图片").foregroundStyle(.secondary).font(.subheadline) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 10) {
                    ForEach(Array(rows.prefix(60).enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 5) {
                            RemoteImage(path: row.value(at: spec["urlPath"].text.isEmpty ? "$.url" : spec["urlPath"].text).text)
                            Text(row.value(at: spec["titlePath"].text.isEmpty ? "$.title" : spec["titlePath"].text).text)
                                .font(.caption).lineLimit(2)
                        }
                    }
                }
            } else if kind == "chat" {
                ForEach(messages) { message in
                    Text(message.text).font(.body).textSelection(.enabled).padding(12)
                        .frame(maxWidth: .infinity, alignment: message.user ? .trailing : .leading)
                        .background(message.user ? Color.blue.opacity(0.1) : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                }
                TextField(spec["placeholder"].text.isEmpty ? "输入消息" : spec["placeholder"].text, text: $text, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder).accessibilityLabel("消息内容")
                Button { sendMessage() } label: { Label(busy ? "正在回复…" : "发送", systemImage: "arrow.up.circle.fill") }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if kind == "form" {
                ForEach(Array(spec["fields"].array.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(field["label"].text).font(.subheadline)
                        TextField(field["placeholder"].text, text: Binding(get: { fields[field["name"].text] ?? field["default"].text }, set: { fields[field["name"].text] = $0 }))
                            .textFieldStyle(.roundedBorder).accessibilityLabel(field["label"].text)
                    }
                }
                Button(spec["submitLabel"].text.isEmpty ? "提交" : spec["submitLabel"].text) {
                    var body = spec["body"].object
                    for field in spec["fields"].array {
                        let key = field["name"].text
                        body[key] = .string(fields[key] ?? field["default"].text)
                    }
                    var action = spec.object; action["body"] = .object(body)
                    chooseAction(.object(action), row: .null)
                }.buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(busy)
            } else { Label("此组件需要更新 App 才能使用。", systemImage: "app.badge").foregroundStyle(.secondary) }
            if busy && kind != "chat" { ProgressView("正在执行…") }
            if let feedback { Label(feedback, systemImage: "checkmark.circle").font(.subheadline).textSelection(.enabled) }
            if let error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
                    Button("重试") { Task { await load() } }.frame(minHeight: 44)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            .task(id: refreshID) {
                await load()
                let interval = max(3, spec["refresh"].number)
                if spec["refresh"].number > 0 && !spec["endpoint"].text.isEmpty && !["chat", "form", "upload"].contains(kind) {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(interval)) } catch { break }
                        if phase == .active { await load() }
                    }
                }
            }
            .confirmationDialog("确认操作", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
                if let action = pendingAction {
                    Button("确认执行", role: action["style"].text == "danger" ? .destructive : nil) { execute(action) }
                }
                Button("取消", role: .cancel) { pendingAction = nil }
            } message: { Text(pendingAction?["confirm"].text.isEmpty == false ? pendingAction!["confirm"].text : "此操作会更改服务器上的数据或服务状态。") }
            .sheet(item: $shared) { file in ShareSheet(items: [file.url]) }
    }
    @ViewBuilder var actionButtons: some View {
        ForEach(Array(spec["actions"].array.enumerated()), id: \.offset) { _, action in actionButton(action, row: .null) }
    }
    func display(_ path: String, in row: JSON? = nil, fallback: String = "—") -> String {
        guard !path.isEmpty else { return fallback }
        let value = (row ?? data).value(at: path).text
        return value.isEmpty ? fallback : value
    }
    func actionButton(_ action: JSON, row: JSON) -> some View {
        Button(action["label"].text.isEmpty ? "执行" : action["label"].text) { chooseAction(action, row: row) }
            .buttonStyle(.bordered).tint(action["style"].text == "danger" ? .red : .blue).frame(minHeight: 44).disabled(busy)
    }
    func chooseAction(_ action: JSON, row: JSON) {
        var next = action.object
        if !action["paramFrom"].text.isEmpty {
            var body = action["body"].object
            body[action["paramKey"].text] = row.value(at: action["paramFrom"].text)
            next["body"] = .object(body)
        }
        if action["style"].text == "danger" || !action["confirm"].text.isEmpty { pendingAction = .object(next) }
        else { execute(.object(next)) }
    }
    func execute(_ action: JSON) {
        busy = true; feedback = nil; error = nil; pendingAction = nil
        Task {
            do {
                if action["download"].bool {
                    shared = SharedFile(url: try await store.api.download(action["endpoint"].text))
                    feedback = "文件已下载，可保存或分享。"
                } else {
                    let result = try await store.api.json(action["endpoint"].text,
                        method: action["method"].text.isEmpty ? "POST" : action["method"].text,
                        body: action["body"] == .null ? nil : action["body"], form: action["encoding"].text == "form")
                    feedback = result["msg"].text.isEmpty ? "操作已完成" : result["msg"].text
                }
                store.log(action["label"].text.isEmpty ? title : action["label"].text, detail: feedback ?? "已完成", success: true)
                await load()
            } catch { self.error = error.localizedDescription; store.log(title, detail: error.localizedDescription, success: false) }
            busy = false
        }
    }
    @MainActor func load() async {
        guard !["form", "upload", "chat", "actions", "notice"].contains(kind), !spec["endpoint"].text.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await store.api.json(spec["endpoint"].text)
            guard !Task.isCancelled else { return }
            data = next; error = nil
            if kind == "chart" {
                samples.append(Sample(value: next.value(at: spec["value"].text).number))
                if samples.count > 60 { samples.removeFirst() }
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func sendMessage() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        messages.append(ChatLine(text: message, user: true)); text = ""; busy = true; error = nil
        Task {
            do {
                let input = spec["inputField"].text.isEmpty ? "content" : spec["inputField"].text
                let result = try await store.api.json(spec["endpoint"].text, method: "POST", body: .object([input: .string(message)]))
                let reply = result.value(at: spec["response"].text.isEmpty ? "$.reply" : spec["response"].text).text
                messages.append(ChatLine(text: reply.isEmpty ? "服务器未返回文字回复。" : reply, user: false))
            } catch { self.error = error.localizedDescription; text = message }
            busy = false
        }
    }
}

struct JSONTree: View {
    let value: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .object(let fields) = value {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    if let item = fields[key] {
                        if case .object = item { DisclosureGroup(key) { JSONTree(value: item) } }
                        else if case .array = item { DisclosureGroup(key) { JSONTree(value: item) } }
                        else { LabeledContent(key, value: item.text.isEmpty ? "—" : item.text).font(.subheadline) }
                    }
                }
            } else if case .array(let rows) = value {
                ForEach(Array(rows.prefix(100).enumerated()), id: \.offset) { _, row in JSONTree(value: row) }
            } else { Text(value.text.isEmpty ? "暂无数据" : value.text).font(.subheadline).textSelection(.enabled) }
        }
    }
}
