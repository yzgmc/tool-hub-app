import SwiftUI

struct NativeCollection: View {
    let spec: JSON
    var context: JSON = .null
    @EnvironmentObject var store: HubStore
    @State private var records: [JSON] = []
    @State private var edits: [Int: [String: JSON]] = [:]
    @State private var selected: Set<Int> = []
    @State private var fields: [String: JSON] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var feedback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeFields(definitions: spec["fields"].array, source: context, values: $fields)
            if records.isEmpty && !busy { Text("暂无可处理条目").foregroundStyle(.secondary) }
            ForEach(Array(records.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 10) {
                    if spec["selectable"].bool {
                        Toggle(row.render(spec["itemTitle"].text.isEmpty ? "条目 \(index+1)" : spec["itemTitle"].text), isOn: Binding(get: { selected.contains(index) }, set: { checked in
                            if checked { selected.insert(index) } else { selected.remove(index) }
                        })).frame(minHeight: 44)
                    } else { Text(row.render(spec["itemTitle"].text.isEmpty ? "条目 \(index+1)" : spec["itemTitle"].text)).font(.headline) }
                    if !spec["imagePrefix"].text.isEmpty {
                        RemoteImage(path: spec["imagePrefix"].text + row.value(at: spec["idPath"].text.isEmpty ? "$.id" : spec["idPath"].text).text)
                    }
                    NativeFields(definitions: spec["itemFields"].array, source: row, values: Binding(get: { edits[index] ?? [:] }, set: { edits[index] = $0 }))
                }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            }
            if spec["selectable"].bool { Text("已选择 \(selected.count) / \(records.count) 项").font(.caption).foregroundStyle(.secondary) }
            Button(spec["submitLabel"].text.isEmpty ? "保存修改" : spec["submitLabel"].text) { submit() }.buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(busy || records.isEmpty)
            if busy { ProgressView("正在处理…") }
            if let error { Text(error).foregroundStyle(.orange).font(.subheadline) }
            if let feedback { Text(feedback).font(.subheadline) }
        }.task(id: spec["sourceEndpoint"].text) {
            busy = true
            do {
                let source: JSON
                if spec["sourceEndpoint"].text.isEmpty { source = context }
                else { source = try await store.api.json(spec["sourceEndpoint"].text) }
                records = source.value(at: spec["listPath"].text.isEmpty ? "$" : spec["listPath"].text).array
                if spec["selectAll"].bool { selected = Set(records.indices) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            busy = false
        }
    }
    func submit() {
        var changed: [JSON] = []
        for (index, row) in records.enumerated() {
            var item = row.object
            for field in spec["itemFields"].array {
                let value = NativeBinding.fieldValue(field, row: row, values: edits[index] ?? [:])
                if let error = NativeBinding.validation(field, value: value) { self.error = "第 \(index+1) 项：" + error; return }
                item[field["name"].text] = value
            }
            changed.append(.object(item))
        }
        var values = fields
        for field in spec["fields"].array {
            let value = NativeBinding.fieldValue(field, row: context, values: values)
            if let error = NativeBinding.validation(field, value: value) { self.error = error; return }
            values[field["name"].text] = value
        }
        values["records"] = .array(changed)
        values["selected"] = .array(records.indices.filter { selected.contains($0) }.map { records[$0].value(at: spec["idPath"].text.isEmpty ? "$.id" : spec["idPath"].text) })
        if spec["selectable"].bool && selected.isEmpty { error = "请至少选择一项。"; return }
        let body = NativeBinding.value(spec["body"], row: context, fields: values)
        busy = true; error = nil; feedback = nil
        Task {
            do {
                _ = try await store.api.json(spec["endpoint"].text, method: spec["method"].text.isEmpty ? "POST" : spec["method"].text, body: body)
                feedback = "已保存，请刷新查看最新结果。"
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
