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
        let plugin = store.plugins.first(where: { $0.id == self.plugin.id }) ?? self.plugin
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
        }.onChange(of: plugin.pages.count) { _, count in if page >= count { page = 0 } }
            .scrollDismissesKeyboard(.interactively).background { CanvasBackground() }.navigationTitle(plugin.name).navigationBarTitleDisplayMode(.inline)
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
    var context: JSON = .null
    @EnvironmentObject var store: HubStore
    @Environment(\.scenePhase) var phase
    @State private var data: JSON = .null
    @State private var visibleLimit = 100
    @State private var busy = false
    @State private var loading = false
    @State private var error: String?
    @State private var feedback: String?
    @State private var samples: [Sample] = []
    @State private var pendingAction: JSON?
    @State private var text = ""
    @State private var messages: [ChatLine] = []
    @State private var fields: [String: JSON] = [:]
    @State private var record: NativeRecord?
    @State private var actionResult: JSON = .null
    @State private var chatAssets: [JSON] = []
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
            } else if kind == "collection" {
                NativeCollection(spec: spec, context: context)
            } else if kind == "remote" {
                NativeRemote(spec: spec)
            } else if kind == "image" {
                NativeGallery(rows: [.object(["url": .string(NativeBinding.endpoint(spec["endpoint"].text, row: context, fields: fields)), "title": .string(title), "kind": .string("image")])], spec: .null)
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
                let metric = data.value(at: spec["value"].text)
                let value = metric.number
                let maximum = spec["max"].number > 0 ? spec["max"].number : 100
                if metric == .null { Text("暂无数据").font(.subheadline).foregroundStyle(.secondary) }
                else { ProgressView(value: min(max(value, 0), maximum), total: maximum) {
                    Text(spec["status"].text.isEmpty ? "当前使用" : display(spec["status"].text)).font(.subheadline).foregroundStyle(.secondary)
                } currentValueLabel: { Text(String(format: "%.1f", value) + spec["unit"].text).monospacedDigit() } }
            } else if kind == "chart" {
                if samples.isEmpty { Text("等待数据…").foregroundStyle(.secondary) }
                Chart(samples) { sample in
                    LineMark(x: .value("时间", sample.date), y: .value("数值", sample.value)).foregroundStyle(.blue)
                    PointMark(x: .value("时间", sample.date), y: .value("数值", sample.value)).foregroundStyle(.blue)
                }.frame(height: 160).accessibilityLabel(title.isEmpty ? "实时曲线" : title)
            } else if kind == "list" {
                if rows.isEmpty && !loading { Text("暂无数据").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(Array(rows.prefix(visibleLimit).enumerated()), id: \.offset) { index, row in
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
                        if !spec["item"]["detail"].array.isEmpty {
                            Button("查看详情与操作", systemImage: "chevron.right") {
                                record = NativeRecord(title: display(spec["item"]["title"].text, in: row), source: row, layout: spec["item"]["detail"].array)
                            }.frame(minHeight: 44)
                        }
                        if !spec["item"]["actions"].array.isEmpty {
                            HStack {
                                ForEach(Array(spec["item"]["actions"].array.enumerated()), id: \.offset) { _, action in
                                    actionButton(action, row: row)
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                    if index < min(rows.count, visibleLimit) - 1 { Divider() }
                }
                if rows.count > visibleLimit { Button("显示更多（还有 \(rows.count - visibleLimit) 项）") { visibleLimit += 100 }.frame(minHeight: 44) }
            } else if kind == "keyvalue" || kind == "auto" {
                if !spec["items"].array.isEmpty {
                    ForEach(Array(spec["items"].array.enumerated()), id: \.offset) { _, item in
                        if case .object = item { LabeledContent(item["label"].text, value: NativeDisplay.text(data.value(at: item["value"].text), field: item)) }
                        else { LabeledContent(item.text.replacingOccurrences(of: "$.", with: ""), value: display(item.text)) }
                    }
                } else { Text("此页面尚未完成业务展示配置。").font(.subheadline).foregroundStyle(.secondary) }
            } else if kind == "actions" {
                ViewThatFits(in: .horizontal) {
                    HStack { actionButtons }
                    VStack(alignment: .leading) { actionButtons }
                }
            } else if kind == "recorder" {
                NativeRecorder(spec: spec)
            } else if kind == "upload" {
                NativeUpload(spec: spec) { refreshResult in feedback = refreshResult }
            } else if kind == "imagegrid" || kind == "gallery" {
                NativeGallery(rows: rows, spec: spec)
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
                if !chatAssets.isEmpty { NativeGallery(rows: chatAssets, spec: .null) }
            } else if kind == "form" {
                NativeFields(definitions: spec["fields"].array, source: data == .null ? context : data, values: $fields)
                Button(spec["submitLabel"].text.isEmpty ? "保存" : spec["submitLabel"].text) { submitForm() }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(busy)
            } else { Label("此组件需要更新 App 才能使用。", systemImage: "app.badge").foregroundStyle(.secondary) }
            if busy && kind != "chat" { ProgressView("正在执行…") }
            if let feedback { Label(feedback, systemImage: "checkmark.circle").font(.subheadline).textSelection(.enabled) }
            if actionResult != .null { NativeResult(value: actionResult, definitions: spec["resultItems"].array) }
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
            .onChange(of: spec) { _, _ in Task { await load() } }
            .sheet(item: $shared) { file in ShareSheet(items: [file.url]) }
            .sheet(item: $record, onDismiss: { Task { await load() } }) { NativeRecordView(record: $0) }
    }
    @ViewBuilder var actionButtons: some View {
        ForEach(Array(spec["actions"].array.enumerated()), id: \.offset) { _, action in actionButton(action, row: .null) }
    }
    func display(_ path: String, in row: JSON? = nil, fallback: String = "—") -> String {
        guard !path.isEmpty else { return fallback }
        return (row ?? data).render(path, fallback: fallback)
    }
    func actionButton(_ action: JSON, row: JSON) -> some View {
        Button(action["label"].text.isEmpty ? "执行" : action["label"].text) { chooseAction(action, row: row) }
            .buttonStyle(.bordered).tint(action["style"].text == "danger" ? .red : .blue).frame(minHeight: 44).disabled(busy)
    }
    func chooseAction(_ action: JSON, row: JSON) {
        var next = NativeBinding.value(action, row: row == .null ? context : row, fields: fields).object
        if !action["fields"].array.isEmpty {
            var form = next; form["type"] = .string("form"); form["submitLabel"] = action["label"]
            record = NativeRecord(title: action["label"].text, source: row, layout: [.object(form)])
            return
        }
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
                    shared = SharedFile(url: try await store.api.download(action["endpoint"].text, method: action["method"].text.isEmpty ? "GET" : action["method"].text, body: action["body"] == .null ? nil : action["body"], form: action["encoding"].text == "form"))
                    feedback = "文件已下载，可保存或分享。"
                } else {
                    let result = try await store.api.json(action["endpoint"].text,
                        method: action["method"].text.isEmpty ? "POST" : action["method"].text,
                        body: action["body"] == .null ? nil : action["body"], form: action["encoding"].text == "form")
                    actionResult = result
                    let message = [result["message"].text, result["msg"].text, result["note"].text].first { !$0.isEmpty }
                    feedback = message ?? "操作已完成"
                    if !action["resultLayout"].array.isEmpty {
                        record = NativeRecord(title: action["label"].text.isEmpty ? title : action["label"].text, source: result, layout: action["resultLayout"].array)
                    } else if !action["resultItems"].array.isEmpty {
                        record = NativeRecord(title: action["label"].text.isEmpty ? "操作结果" : action["label"].text,
                            source: result, layout: [.object(["type": .string("keyvalue"), "title": .string("结果"), "items": action["resultItems"]])])
                    }
                    if !action["downloadFrom"].text.isEmpty {
                        let path = NativeBinding.endpoint(action["downloadFrom"].text, row: result, fields: fields)
                        shared = SharedFile(url: try await store.api.download(path))
                    }
                }
                store.log(action["label"].text.isEmpty ? title : action["label"].text, detail: feedback ?? "已完成", success: true)
                await load()
            } catch { self.error = error.localizedDescription; store.log(title, detail: error.localizedDescription, success: false) }
            busy = false
        }
    }
    @MainActor func load() async {
        if spec["endpoint"].text.isEmpty && spec["loadEndpoint"].text.isEmpty { data = context; return }
        let endpoint = kind == "form" ? spec["loadEndpoint"].text : spec["endpoint"].text
        guard !["collection", "remote", "recorder", "image", "upload", "chat", "actions", "notice"].contains(kind), !endpoint.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await store.api.json(endpoint)
            guard !Task.isCancelled else { return }
            data = next; error = nil
            if kind == "chart" && next.value(at: spec["value"].text) != .null {
                samples.append(Sample(value: next.value(at: spec["value"].text).number))
                if samples.count > 60 { samples.removeFirst() }
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func submitForm() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        var values = fields
        let source = data == .null ? context : data
        for field in spec["fields"].array {
            let v = NativeBinding.fieldValue(field, row: source, values: values)
            if let message = NativeBinding.validation(field, value: v) { error = message; return }

            values[field["name"].text] = v
        }
        fields = values
        var action = NativeBinding.value(spec, row: source, fields: values).object
        action.removeValue(forKey: "fields")
        var body = action["body"]?.object ?? [:]
        if !spec["bodyOnly"].bool {
            for (key, value) in values {
                if spec["fields"].array.contains(where: { $0["name"].text == key && $0["type"].text == "secret" }) && value.text.isEmpty { continue }
                body[key] = value
            }
        }
        action["body"] = .object(body)
        var endpoint = NativeBinding.endpoint(spec["endpoint"].text, row: source, fields: values)
        if spec["method"].text.uppercased() == "GET" {
            var parts = URLComponents(string: endpoint)
            let query = (parts?.queryItems ?? []) + body.map { URLQueryItem(name: $0.key, value: $0.value.wireText) }
            parts?.queryItems = query
            endpoint = parts?.string ?? endpoint; action.removeValue(forKey: "body")
        }
        action["endpoint"] = .string(endpoint)
        chooseAction(.object(action), row: source)
    }
    func sendMessage() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        messages.append(ChatLine(text: message, user: true)); text = ""; busy = true; error = nil
        Task {
            do {
                let input = spec["inputField"].text.isEmpty ? "content" : spec["inputField"].text
                var payload = NativeBinding.value(spec["body"], row: context, fields: fields).object
                payload[input] = .string(message)
                let result = try await store.api.json(spec["endpoint"].text, method: "POST", body: .object(payload))
                chatAssets = result["items"].array
                let reply = result.value(at: spec["response"].text.isEmpty ? "$.reply" : spec["response"].text).text
                messages.append(ChatLine(text: reply.isEmpty ? "服务器未返回文字回复。" : reply, user: false))
            } catch { self.error = error.localizedDescription; text = message }
            busy = false
        }
    }
}
