import SwiftUI
import Charts
import PhotosUI
import UniformTypeIdentifiers

/// 组件容器：负责按 refresh 周期拉取 endpoint 数据，再分发给具体渲染器。
/// chat/upload/progress 自管网络（发送/上传/短周期轮询），不走容器轮询。
struct WidgetContainer: View {
    @EnvironmentObject private var store: SettingsStore
    let spec: WidgetSpec

    @State private var payload: Any?
    @State private var history: [Double] = []
    @State private var error: String?

    /// 是否需要容器统一轮询拉数
    private var polled: Bool {
        switch spec.type {
        case "chat", "upload", "progress": return false
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = spec.title, !t.isEmpty {
                Text(t).font(.headline).foregroundColor(Theme.ink)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: spec.endpoint) { if polled { await loop() } }
    }

    @ViewBuilder
    private var content: some View {
        switch spec.type {
        case "stats":
            StatsWidget(spec: spec, payload: payload)
        case "gauge":
            GaugeWidget(spec: spec, payload: payload)
        case "chart":
            ChartWidget(spec: spec, history: history)
        case "list":
            ListWidget(spec: spec, payload: payload)
        case "keyvalue":
            KeyValueWidget(spec: spec, payload: payload)
        case "auto":
            AutoWidget(payload: payload)
        case "actions":
            ActionsWidget(spec: spec)
        case "chat":
            ChatWidget(spec: spec)
        case "upload":
            UploadWidget(spec: spec)
        case "imagegrid":
            ImageGridWidget(spec: spec, payload: payload)
        case "progress":
            ProgressWidget(spec: spec)
        default:
            Text("未知组件类型：\(spec.type)")
                .font(.footnote).foregroundColor(Theme.sub)
        }
    }

    private func loop() async {
        await fetch()
        while !Task.isCancelled {
            let s = max(spec.refresh ?? 30, 3)
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            await fetch()
        }
    }

    private func fetch() async {
        guard let ep = spec.endpoint else {
            error = "未配置 endpoint"
            return
        }
        do {
            let obj = try await store.client.proxyJSON(ep)
            payload = obj
            error = nil
            // chart：累积历史点
            if spec.type == "chart", let v = JSONPath.number(obj, spec.value) {
                let cap = max(spec.history ?? 60, 10)
                history.append(v)
                if history.count > cap { history.removeFirst(history.count - cap) }
            }
        } catch {
            if payload == nil { self.error = error.localizedDescription }
        }
    }
}

// ---------------------------------------------------------------- 各类渲染器

struct StatsWidget: View {
    let spec: WidgetSpec
    let payload: Any?

    var body: some View {
        let items = (spec.items ?? []).compactMap { item -> StatItem? in
            if case .stat(let s) = item { return s }
            return nil
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 4) {
                    Text(it.label ?? "")
                        .font(.caption).foregroundColor(Theme.sub)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(JSONPath.display(JSONPath.resolve(payload, it.value)))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(it.unit ?? "")
                            .font(.caption).foregroundColor(Theme.sub)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
            }
        }
    }
}

struct GaugeWidget: View {
    let spec: WidgetSpec
    let payload: Any?

    var body: some View {
        let raw = JSONPath.number(payload, spec.value)
        let maxV = max(spec.max ?? 100, 1)
        let pct = raw.map { min(max($0 / maxV, 0), 1) }
        let color = raw.map { v -> Color in
            let r = v / maxV
            if r > 0.9 { return Theme.danger }
            if r > 0.7 { return Theme.accent }
            return Theme.ok
        } ?? Theme.line
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(raw.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.ink)
                Text(spec.unit ?? "")
                    .font(.subheadline).foregroundColor(Theme.sub)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.bg).frame(height: 10)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * (pct ?? 0), height: 10)
                }
            }
            .frame(height: 10)
        }
    }
}

struct ChartWidget: View {
    let spec: WidgetSpec
    let history: [Double]

    var body: some View {
        if history.isEmpty {
            Text("等待数据…").font(.footnote).foregroundColor(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else {
            VStack(spacing: 8) {
                Chart(Array(history.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(Theme.accent.opacity(0.08))
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
                HStack {
                    Spacer()
                    Text(history.last.map { String(format: "%.1f", $0) } ?? "--")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.ink)
                    Text(spec.unit ?? "")
                        .font(.caption).foregroundColor(Theme.sub)
                }
            }
        }
    }
}

struct ListWidget: View {
    @EnvironmentObject private var store: SettingsStore
    let spec: WidgetSpec
    let payload: Any?

    @State private var pending: RowAction?
    @State private var running: String?
    @State private var result: String?

    /// 行级操作的暂存上下文（行数据 + 动作）
    private struct RowAction {
        let row: Any
        let action: ActionSpec
    }

    var body: some View {
        // listPath 指定数组位置（如 $.devices）；取不到且根本身是数组时用根（如 qbt）
        let rows = (JSONPath.resolve(payload, spec.listPath ?? "$.items") as? [Any])
            ?? (payload as? [Any]) ?? []
        let m = spec.item ?? ListItemSpec()
        Group {
            if rows.isEmpty {
                Text("暂无数据").font(.footnote).foregroundColor(Theme.sub)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        rowView(row, m: m, last: i == rows.count - 1)
                    }
                }
            }
        }
        .confirmationDialog("确认执行「\(pending?.action.label ?? "")」？",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("执行", role: pending?.action.style == "danger" ? .destructive : nil) {
                if let p = pending { Task { await runRow(p.action, p.row) } }
            }
            Button("取消", role: .cancel) { pending = nil }
        }
        .alert("结果", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(result ?? "")
        }
    }

    @ViewBuilder
    private func rowView(_ row: Any, m: ListItemSpec, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(JSONPath.display(JSONPath.resolve(row, m.title)))
                        .font(.subheadline).foregroundColor(Theme.ink)
                        .lineLimit(1)
                    let sub = JSONPath.display(JSONPath.resolve(row, m.subtitle))
                    if sub != "--" {
                        Text(sub).font(.caption2).foregroundColor(Theme.sub)
                            .lineLimit(1)
                    }
                }
                Spacer()
                let v = JSONPath.display(JSONPath.resolve(row, m.value))
                if v != "--" {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(v).font(.subheadline).foregroundColor(Theme.accent)
                        Text(m.valueUnit ?? "").font(.caption2).foregroundColor(Theme.sub)
                    }
                }
            }
            rowActions(row, actions: m.actions ?? [])
        }
        .padding(.vertical, 8)
        if !last { Divider().overlay(Theme.line) }
    }

    @ViewBuilder
    private func rowActions(_ row: Any, actions: [ActionSpec]) -> some View {
        if !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                    Button {
                        if a.confirm != nil {
                            pending = RowAction(row: row, action: a)
                        } else {
                            Task { await runRow(a, row) }
                        }
                    } label: {
                        Text(a.label ?? "操作")
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(
                                a.style == "danger" ? Theme.danger.opacity(0.12) : Theme.bg))
                            .foregroundColor(a.style == "danger" ? Theme.danger : Theme.ink)
                    }
                    .disabled(running != nil)
                }
                Spacer()
                if running != nil { ProgressView().scaleEffect(0.8) }
            }
        }
    }

    /// 行级操作执行：paramFrom/paramKey 存在时把行数据注入请求体，encoding=="form" 表单发送
    private func runRow(_ a: ActionSpec, _ row: Any) async {
        pending = nil
        running = a.label
        defer { running = nil }
        var act = a
        act.confirm = nil
        if let pf = a.paramFrom, let pk = a.paramKey {
            act.body = .object([pk: JSONValue.from(JSONPath.resolve(row, pf) ?? NSNull())])
        }
        do {
            let s = try await store.client.runAction(act)
            result = s
        } catch {
            result = error.localizedDescription
        }
    }
}

struct KeyValueWidget: View {
    let spec: WidgetSpec
    let payload: Any?

    var body: some View {
        let paths: [String] = (spec.items ?? []).compactMap { item -> String? in
            if case .path(let s) = item { return s }
            return nil
        }
        VStack(spacing: 0) {
            ForEach(Array(paths.enumerated()), id: \.offset) { i, p in
                HStack {
                    Text(label(of: p)).font(.subheadline).foregroundColor(Theme.sub)
                    Spacer()
                    Text(JSONPath.display(JSONPath.resolve(payload, p)))
                        .font(.subheadline).foregroundColor(Theme.ink)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 6)
                if i < paths.count - 1 { Divider().overlay(Theme.line) }
            }
        }
    }

    private func label(of path: String) -> String {
        path.split(separator: ".").last.map(String.init) ?? path
    }
}

struct AutoWidget: View {
    let payload: Any?

    var body: some View {
        let rows = JSONPath.flatten(payload)
        if rows.isEmpty {
            Text("暂无数据").font(.footnote).foregroundColor(Theme.sub)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, kv in
                    HStack(alignment: .top) {
                        Text(kv.key).font(.subheadline).foregroundColor(Theme.sub)
                        Spacer()
                        Text(kv.value).font(.subheadline).foregroundColor(Theme.ink)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 5)
                    if i < rows.count - 1 { Divider().overlay(Theme.line) }
                }
            }
        }
    }
}

struct ActionsWidget: View {
    @EnvironmentObject private var store: SettingsStore
    let spec: WidgetSpec

    @State private var pending: ActionSpec?
    @State private var running: String?
    @State private var result: String?
    @State private var resultOK = true

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array((spec.actions ?? []).enumerated()), id: \.offset) { _, a in
                Button {
                    if a.open == true {
                        openExternally(a)
                    } else if a.confirm != nil { pending = a } else { Task { await run(a) } }
                } label: {
                    HStack {
                        if running == a.label { ProgressView().tint(.white) }
                        Text(a.label ?? "操作")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(a.style == "danger" ? Theme.danger : Theme.accent))
                    .foregroundColor(.white)
                }
                .disabled(running != nil)
            }
        }
        .confirmationDialog("确认执行「\(pending?.label ?? "")」？",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("执行", role: pending?.style == "danger" ? .destructive : nil) {
                if let a = pending { Task { await run(a) } }
            }
            Button("取消", role: .cancel) { pending = nil }
        }
        .alert("结果", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(result ?? "")
        }
    }

    /// open 链接：拼上 token 交给 Safari（下载类接口用，走浏览器下载/分享面板）
    private func openExternally(_ a: ActionSpec) {
        guard let ep = a.endpoint else { return }
        let sep = ep.contains("?") ? "&" : "?"
        let s = store.client.base + ep + sep + "token=" + store.client.token
        guard let u = URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
        else { return }
        UIApplication.shared.open(u)
    }

    private func run(_ a: ActionSpec) async {
        pending = nil
        running = a.label
        defer { running = nil }
        do {
            let s = try await store.client.runAction(a)
            resultOK = true
            result = s
        } catch {
            resultOK = false
            result = error.localizedDescription
        }
    }
}

// ---------------------------------------------------------------- 交互类组件

/// chat 组件：AI 对话。进页拉历史（失败静默），底部输入框发送，
/// POST {inputField: 文本} 后按 response 路径取回复（取不到用 flatten 兜底）。
struct ChatWidget: View {
    @EnvironmentObject private var store: SettingsStore
    let spec: WidgetSpec

    @State private var messages: [(role: String, text: String)] = []
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sending {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.8)
                    Text("思考中…").font(.caption).foregroundColor(Theme.sub)
                }
            }
            messageList
            inputBar
        }
        .task { await loadHistory() }
    }

    private var messageList: some View {
        ScrollView {
            ScrollViewReader { proxy in
                Group {
                    if messages.isEmpty {
                        VStack(spacing: 8) {
                            Text("💬").font(.title2)
                            Text("发送消息开始对话").font(.caption).foregroundColor(Theme.sub)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                                bubble(m).id(i)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onChange(of: messages.count) { _ in
                    guard !messages.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(messages.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 280)
        .frame(maxWidth: .infinity)
    }

    private func bubble(_ m: (role: String, text: String)) -> some View {
        let isUser = m.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 48) }
            Text(m.text)
                .font(.subheadline)
                .foregroundColor(isUser ? .white : Theme.ink)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(isUser ? Theme.accent : Theme.bg))
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(spec.placeholder ?? "输入…", text: $input)
                .font(.subheadline)
                .submitLabel(.send)
                .disabled(sending)
                .onSubmit { Task { await send() } }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(9)
                    .background(Circle().fill(Theme.accent))
            }
            .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard let ep = spec.endpoint else {
            messages.append(("assistant", "⚠️ 未配置 endpoint"))
            return
        }
        input = ""
        messages.append(("user", text))
        sending = true
        defer { sending = false }
        do {
            let body = JSONValue.object([spec.inputField ?? "message": .string(text)])
            let resp = try await store.client.proxyJSON(ep, method: "POST", body: body, timeout: 120)
            messages.append(("assistant", replyText(from: resp)))
        } catch {
            messages.append(("assistant", "⚠️ \(error.localizedDescription)"))
        }
    }

    /// 先按 response 路径取回复文本，取不到再 flatten 拼接兜底
    private func replyText(from resp: Any?) -> String {
        if let path = spec.response, let v = JSONPath.resolve(resp, path) {
            let s = JSONPath.display(v)
            if s != "--" { return s }
        }
        let flat = JSONPath.flatten(resp, depth: 1)
            .map { "\($0.key)：\($0.value)" }
            .joined(separator: "\n")
        return flat.isEmpty ? "（无回复内容）" : flat
    }

    /// 拉历史：根为数组直接用，否则尝试常见键名；role 含 user/我 判定为用户侧
    private func loadHistory() async {
        guard let h = spec.chatHistory, let ep = h.endpoint, messages.isEmpty else { return }
        do {
            let obj = try await store.client.proxyJSON(ep)
            let rows = historyRows(from: obj)
            var loaded: [(role: String, text: String)] = []
            for item in rows {
                guard let c = JSONPath.resolve(item, h.content) else { continue }
                let text = JSONPath.display(c)
                guard text != "--" else { continue }
                let r = JSONPath.display(JSONPath.resolve(item, h.role))
                let isUser = r.lowercased().contains("user") || r.contains("我")
                loaded.append((isUser ? "user" : "assistant", text))
            }
            if !loaded.isEmpty { messages = loaded }
        } catch {
            // 历史拉取失败静默，不阻塞对话
        }
    }

    private func historyRows(from obj: Any?) -> [Any] {
        if let arr = obj as? [Any] { return arr }
        for key in ["items", "data", "history", "messages", "list"] {
            if let arr = JSONPath.resolve(obj, "$.\(key)") as? [Any] { return arr }
        }
        return []
    }
}

/// upload 组件：accept=="image" 用相册选择（PhotosPicker），否则文件导入器，
/// 手写 multipart 上传，结果用 AutoWidget 风格平铺展示。
struct UploadWidget: View {
    @EnvironmentObject private var store: SettingsStore
    let spec: WidgetSpec

    @State private var photoItem: PhotosPickerItem?
    @State private var showImporter = false
    @State private var uploading = false
    @State private var result: Any?
    @State private var fail: String?

    private var isImage: Bool { (spec.accept ?? "any") == "image" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerButton
            if let f = fail {
                Text(f).font(.footnote).foregroundColor(Theme.danger)
            }
            if let r = result {
                VStack(alignment: .leading, spacing: 8) {
                    Text("上传结果").font(.subheadline).foregroundColor(Theme.sub)
                    AutoWidget(payload: r)
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { res in
            handleImporter(res)
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil   // 清掉以便可再次选同一张
            Task { await handlePhoto(item) }
        }
    }

    private var pickerButton: some View {
        Group {
            if isImage {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    buttonLabel("选择图片")
                }
            } else {
                Button { showImporter = true } label: {
                    buttonLabel("选择文件")
                }
            }
        }
        .disabled(uploading || spec.endpoint == nil)
    }

    private func buttonLabel(_ text: String) -> some View {
        HStack {
            if uploading { ProgressView().tint(.white) }
            Image(systemName: isImage ? "photo" : "folder")
            Text(uploading ? "上传中…" : text)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
        .foregroundColor(.white)
    }

    private func handlePhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            fail = "读取图片失败"
            return
        }
        await send(data, fileName: "photo.jpg", mimeType: "image/jpeg")
    }

    private func handleImporter(_ res: Result<[URL], Error>) {
        switch res {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let mime = Self.mime(for: url.pathExtension)
                Task { await send(data, fileName: url.lastPathComponent, mimeType: mime) }
            } catch {
                fail = error.localizedDescription
            }
        case .failure(let e):
            fail = e.localizedDescription
        }
    }

    private func send(_ data: Data, fileName: String, mimeType: String) async {
        guard let ep = spec.endpoint else { fail = "未配置 endpoint"; return }
        uploading = true
        fail = nil
        result = nil
        defer { uploading = false }
        do {
            result = try await store.client.upload(
                path: ep, fileData: data, fileName: fileName, mimeType: mimeType,
                fileParam: spec.fileParam ?? "file", fields: spec.fields ?? [:])
        } catch {
            fail = error.localizedDescription
        }
    }

    /// 常见扩展名 → MIME；未识别的按二进制流
    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "txt", "md", "log": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}

/// imagegrid 组件：3 列图片墙（找图结果 / 生成画廊），点击无动作。
struct ImageGridWidget: View {
    @EnvironmentObject private var store: SettingsStore
    let spec: WidgetSpec
    let payload: Any?

    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let items = resolveItems()
        if items.isEmpty {
            Text("暂无图片").font(.footnote).foregroundColor(Theme.sub)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    cell(item)
                }
            }
        }
    }

    /// listPath 取数组；取不到且根本身是数组时直接用根
    private func resolveItems() -> [Any] {
        if let arr = JSONPath.resolve(payload, spec.listPath ?? "$.items") as? [Any] { return arr }
        return payload as? [Any] ?? []
    }

    /// 相对路径（/ 开头）拼网关 base
    private func imageURL(_ item: Any) -> URL? {
        guard let raw = JSONPath.resolve(item, spec.urlPath ?? "$.url") as? String,
              !raw.isEmpty else { return nil }
        let full = raw.hasPrefix("/") ? store.client.base + raw : raw
        return URL(string: full)
    }

    private func cell(_ item: Any) -> some View {
        VStack(spacing: 4) {
            AsyncImage(url: imageURL(item)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    ZStack {
                        Rectangle().fill(Theme.bg)
                        Image(systemName: "photo").foregroundColor(Theme.line)
                    }
                default:
                    ZStack {
                        Rectangle().fill(Theme.bg)
                        ProgressView()
                    }
                }
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            let title = JSONPath.display(JSONPath.resolve(item, spec.titlePath ?? "$.title"))
            if title != "--" {
                Text(title)
                    .font(.caption2).foregroundColor(Theme.sub)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// progress 组件：短周期轮询任务进度，percent>=100 或状态词命中即停。
struct ProgressWidget: View {
    @EnvironmentObject private var store: SettingsStore
    let spec: WidgetSpec

    @State private var payload: Any?
    @State private var error: String?
    @State private var finished = false

    /// 触发停止轮询的状态词
    private static let stopWords: Set<String> = [
        "done", "finished", "completed", "error", "failed", "完成", "失败"
    ]

    var body: some View {
        let raw = JSONPath.number(payload, spec.value)
        let status = JSONPath.display(JSONPath.resolve(payload, spec.status))
        VStack(alignment: .leading, spacing: 10) {
            if let e = error {
                Text(e).font(.footnote).foregroundColor(Theme.danger)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(raw.map { String(format: "%.0f", $0) } ?? "--")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.ink)
                    Text("%").font(.subheadline).foregroundColor(Theme.sub)
                    Spacer()
                    if status != "--" {
                        Text(status).font(.subheadline).foregroundColor(Theme.sub)
                            .lineLimit(1)
                    } else if !finished {
                        ProgressView().scaleEffect(0.8)
                    }
                }
                if let f = fraction(raw) {
                    ProgressView(value: f)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                }
            }
        }
        .task(id: spec.endpoint) { await poll() }
    }

    /// 0~100 归一：>1 视为百分数按 /100 缩放
    private func fraction(_ raw: Double?) -> Double? {
        guard let raw else { return nil }
        let v = raw > 1 ? raw / 100 : raw
        return min(max(v, 0), 1)
    }

    private func poll() async {
        guard let ep = spec.endpoint else {
            error = "未配置 endpoint"
            return
        }
        let interval = max(spec.refresh ?? 2, 1)
        while !Task.isCancelled && !finished {
            await fetchOnce(ep)
            if !finished {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func fetchOnce(_ ep: String) async {
        do {
            let obj = try await store.client.proxyJSON(ep)
            payload = obj
            error = nil
            finished = isDone(obj)
        } catch {
            self.error = error.localizedDescription
            finished = true   // 出错即停，避免空转
        }
    }

    private func isDone(_ obj: Any?) -> Bool {
        if let p = JSONPath.number(obj, spec.value), p >= 100 { return true }
        let s = JSONPath.display(JSONPath.resolve(obj, spec.status)).lowercased()
        return Self.stopWords.contains(s)
    }
}
