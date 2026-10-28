import SwiftUI

// All templates are data bindings; downloaded definitions never execute code.
enum NativeBinding {
    static func endpoint(_ template: String, row: JSON, fields: [String: JSON]) -> String {
        var result = template
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#) else { return result }
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let full = Range(match.range, in: result), let keyRange = Range(match.range(at: 1), in: template) else { continue }
            let key = String(template[keyRange])
            if key.hasPrefix("field.") && fields[String(key.dropFirst(6))] == nil { continue }
            let value = key.hasPrefix("field.") ? fields[String(key.dropFirst(6))] ?? .null : row.value(at: key.hasPrefix("$.") ? key : "$." + key)
            var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "/?&=+#%")
            result.replaceSubrange(full, with: value.text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        return result
    }
    static func value(_ input: JSON, row: JSON, fields: [String: JSON]) -> JSON {
        switch input {
        case .object(let values): return .object(values.mapValues { value($0, row: row, fields: fields) })
        case .array(let values): return .array(values.map { value($0, row: row, fields: fields) })
        case .string(let s):
            if s.hasPrefix("$row.") { return row.value(at: "$." + s.dropFirst(5)) }
            if s.hasPrefix("$field.") { return fields[String(s.dropFirst(7))] ?? input }
            return .string(endpoint(s, row: row, fields: fields))
        default: return input
        }
    }
    static func selectionValue(_ option: JSON, field: JSON) -> JSON {
        let value: JSON
        if !field["valuePath"].text.isEmpty { value = option.value(at: field["valuePath"].text) }
        else { value = option["value"] == .null ? option : option["value"] }
        if field["valueType"].text == "integer", let number = Double(value.text) { return .number(number) }
        return value
    }
    static func fieldValue(_ field: JSON, row: JSON, values: [String: JSON]) -> JSON {
        if let v = values[field["name"].text] { return v }
        if !field["from"].text.isEmpty { let v = row.value(at: field["from"].text); if v != .null { return v } }
        if field["default"] != .null { return field["default"] }
        return field["type"].text == "toggle" ? .bool(false) : .string("")
    }
    static func validation(_ field: JSON, value: JSON) -> String? {
        let label = field["label"].text
        if field["required"].bool && value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写" + label }
        if ["number", "integer"].contains(field["type"].text), !value.text.isEmpty {
            guard let n = Double(value.text), n.isFinite else { return label + "需要填写数字" }
            if field["type"].text == "integer" && n != n.rounded() { return label + "需要填写整数" }
            if field["min"] != .null && n < field["min"].number { return label + "不能小于 " + field["min"].text }
            if field["max"] != .null && n > field["max"].number { return label + "不能大于 " + field["max"].text }
        }
        return nil
    }
}

struct NativeFields: View {
    let definitions: [JSON]
    var source: JSON = .null
    @Binding var values: [String: JSON]
    var body: some View {
        ForEach(Array(definitions.enumerated()), id: \.offset) { _, field in
            NativeField(field: field, source: source, values: $values)
        }
    }
}

struct NativeField: View {
    let field: JSON
    let source: JSON
    @Binding var values: [String: JSON]
    @EnvironmentObject var store: HubStore
    @State private var remoteOptions: [JSON] = []
    @State private var optionError: String?
    var key: String { field["name"].text }
    var current: JSON { NativeBinding.fieldValue(field, row: source, values: values) }
    var text: Binding<String> { Binding(get: { current.text }, set: { raw in
        if ["number", "integer"].contains(field["type"].text), let number = Double(raw) { values[key] = .number(number) }
        else if field["valueType"].text == "integer", let number = Double(raw) { values[key] = .number(number) }
        else { values[key] = .string(raw) }
    }) }
    var options: [JSON] { field["options"].array + remoteOptions }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if field["type"].text == "toggle" {
                Toggle(field["label"].text, isOn: Binding(get: { current.bool }, set: { values[key] = .bool($0) })).frame(minHeight: 44)
            } else if field["type"].text == "select" {
                Picker(field["label"].text, selection: text) {
                    Text("请选择").tag("")
                    if !current.text.isEmpty && !options.contains(where: { optionValue($0) == current.text }) { Text(current.text).tag(current.text) }
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(optionLabel(option)).tag(optionValue(option)) }
                }.pickerStyle(.menu).frame(minHeight: 44)
                if let optionError { Text(optionError).font(.caption).foregroundStyle(.orange) }
            } else if field["type"].text == "multiselect" {
                Text(field["label"].text).font(.subheadline)
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Toggle(optionLabel(option), isOn: Binding(get: { current.array.contains(NativeBinding.selectionValue(option, field: field)) }, set: { selected in
                        let v = NativeBinding.selectionValue(option, field: field)
                        var list = current.array.filter { $0 != v }; if selected { list.append(v) }; values[key] = .array(list)
                    })).font(.subheadline).frame(minHeight: 44)
                }
                if let optionError { Text(optionError).font(.caption).foregroundStyle(.orange) }
            } else {
                Text(field["label"].text + (field["required"].bool ? " *" : "")).font(.subheadline)
                if field["type"].text == "secret" { SecureField(field["placeholder"].text, text: text).textFieldStyle(.roundedBorder) }
                else if field["type"].text == "multiline" { TextField(field["placeholder"].text, text: text, axis: .vertical).lineLimit(3...12).textFieldStyle(.roundedBorder) }
                else { TextField(field["placeholder"].text, text: text).textFieldStyle(.roundedBorder)
                    .keyboardType(["integer", "number"].contains(field["type"].text) ? .numbersAndPunctuation : .default)
                    .textInputAutocapitalization(field["type"].text == "url" ? .never : .sentences)
                    .autocorrectionDisabled(field["type"].text == "url") }
            }
            if !field["help"].text.isEmpty { Text(field["help"].text).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .contain)
            .task(id: field["optionsEndpoint"].text) {
                guard !field["optionsEndpoint"].text.isEmpty else { return }
                do {
                    let result = try await store.api.json(field["optionsEndpoint"].text)
                    remoteOptions = result.value(at: field["optionsPath"].text.isEmpty ? "$" : field["optionsPath"].text).array
                } catch { if !Task.isCancelled { optionError = "选项加载失败，请重新打开页面。" } }
            }
    }
    func optionValue(_ item: JSON) -> String {
        if !field["valuePath"].text.isEmpty { return item.value(at: field["valuePath"].text).text }
        return item["value"] == .null ? item.text : item["value"].text
    }
    func optionLabel(_ item: JSON) -> String {
        if !field["labelPath"].text.isEmpty { return item.render(field["labelPath"].text) }
        return item["label"] == .null ? optionValue(item) : item["label"].text
    }
}

struct NativeRecord: Identifiable {
    let id = UUID()
    let title: String
    let source: JSON
    let layout: [JSON]
}
struct NativeRecordView: View {
    let record: NativeRecord
    @Environment(\.dismiss) var dismiss
    @State private var refreshID = UUID()
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(Array(record.layout.enumerated()), id: \.offset) { _, widget in
                        NativeWidget(spec: NativeBinding.value(widget, row: record.source, fields: [:]), refreshID: refreshID, context: record.source)
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).background { CanvasBackground() }.navigationTitle(record.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .refreshable { refreshID = UUID() }
        }
    }
}

struct NativeResult: View {
    let value: JSON
    let definitions: [JSON]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(definitions.enumerated()), id: \.offset) { _, field in
                let item = value.value(at: field["value"].text)
                if item != .null {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field["label"].text).font(.caption).foregroundStyle(.secondary)
                        Text(item.text + field["unit"].text).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

enum NativeDisplay {
    static func text(_ value: JSON, field: JSON) -> String {
        guard value != .null else { return "暂无数据" }
        let mapped = field["map"][value.text]
        if mapped != .null { return mapped.text }
        if field["format"].text == "bytes" { return ByteCountFormatter.string(fromByteCount: Int64(max(0, value.number)), countStyle: .binary) }
        if field["format"].text == "date", value.number > 0 {
            return Date(timeIntervalSince1970: value.number).formatted(date: .abbreviated, time: .shortened)
        }
        let states = ["running":"运行中", "pending":"等待中", "queued":"排队中", "done":"已完成", "ready":"已就绪", "error":"失败", "failed":"失败", "stopped":"已停止", "cancelled":"已取消", "idle":"空闲", "processing":"处理中", "enabled":"已启用", "disabled":"已关闭", "online":"在线", "offline":"离线"]
        let result = field["format"].text == "status" ? states[value.text] ?? value.text : value.text
        return (result.isEmpty ? "暂无内容" : result) + field["unit"].text
    }
}
