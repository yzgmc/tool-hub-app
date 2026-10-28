import SwiftUI
import Photos
import QuickLook

struct NativeAsset: Identifiable {
    let id: String
    let title: String
    let preview: String
    let download: String
    let kind: String
    let filename: String
    static func parse(_ row: JSON, spec: JSON = .null) -> NativeAsset? {
        func path(_ key: String, fallback: String) -> String {
            if !spec[key + "Template"].text.isEmpty { return NativeBinding.endpoint(spec[key + "Template"].text, row: row, fields: [:]) }
            return row.value(at: spec[key + "Path"].text.isEmpty ? fallback : spec[key + "Path"].text).text
        }
        let preview = path("url", fallback: "$.url")
        var download = path("download", fallback: "$.download")
        if download.isEmpty { download = preview }
        guard download.hasPrefix("/"), !download.hasPrefix("//") else { return nil }
        let title = path("title", fallback: "$.title")
        let filename = row["filename"].text.isEmpty ? (row["name"].text.isEmpty ? "" : row["name"].text) : row["filename"].text
        let kind = row["kind"].text.isEmpty ? (row["type"].text.uppercased() == "VIDEO" ? "video" : (spec["kind"].text.isEmpty ? "image" : spec["kind"].text)) : row["kind"].text
        return NativeAsset(id: download, title: title.isEmpty ? (filename.isEmpty ? "成果文件" : filename) : title,
                           preview: preview.isEmpty ? download : preview, download: download, kind: kind, filename: filename)
    }
}

struct NativeGallery: View {
    let rows: [JSON]
    let spec: JSON
    @EnvironmentObject var store: HubStore
    @State private var selected: NativeAsset?
    @State private var shared: SharedFile?
    @State private var batch: [URL] = []
    @State private var showBatch = false
    @State private var busy = false
    @State private var cancelled = false
    @State private var completed = 0
    @State private var error: String?
    @State private var limit = 24
    var assets: [NativeAsset] { rows.compactMap { NativeAsset.parse($0, spec: spec) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !assets.isEmpty {
                HStack {
                    Text("共 \(assets.count) 个成果").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("下载全部", systemImage: "square.and.arrow.down") { downloadAll() }.disabled(busy).frame(minHeight: 44)
                }
                if busy {
                    ProgressView("正在下载 \(completed) / \(assets.count)", value: Double(completed), total: Double(max(assets.count, 1)))
                    Button("取消下载", role: .cancel) { cancelled = true }.frame(minHeight: 44)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138))], spacing: 14) {
                    ForEach(Array(assets.prefix(limit).enumerated()), id: \.offset) { _, asset in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { selected = asset } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    if asset.kind == "image" || asset.kind == "model" || (asset.kind == "video" && asset.preview != asset.download) { RemoteImage(path: asset.preview) }
                                    else { Image(systemName: asset.kind == "audio" ? "waveform" : (asset.kind == "video" ? "play.rectangle" : "doc.richtext")).font(.largeTitle).frame(maxWidth: .infinity, minHeight: 100).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12)) }
                                    Text(asset.title).font(.subheadline).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("预览：" + asset.title)
                            Button("下载或保存", systemImage: "square.and.arrow.down") { selected = asset }.font(.caption).frame(minHeight: 44)
                        }
                    }
                }
                if assets.count > limit { Button("显示更多（还有 \(assets.count-limit) 项）") { limit += 24 }.frame(minHeight: 44) }
            } else { Text("暂无成果。任务完成后刷新查看。").foregroundStyle(.secondary).font(.subheadline) }
            if let error { Text(error).foregroundStyle(.orange).font(.subheadline) }
        }.sheet(item: $selected) { asset in NativeAssetDetail(asset: asset) }
            .sheet(isPresented: $showBatch) { ShareSheet(items: batch) }
    }
    func downloadAll() {
        busy = true; cancelled = false; completed = 0; error = nil; batch = []
        let snapshot = assets
        Task {
            var failures = 0
            for asset in snapshot {
                if cancelled || Task.isCancelled { break }
                do { batch.append(try await store.api.download(asset.download, filename: asset.filename)) }
                catch { failures += 1 }
                completed += 1
            }
            busy = false
            if failures > 0 { error = "\(failures) 个文件下载失败，其余 \(batch.count) 个已下载，可以保存后重试失败项。" }
            if !batch.isEmpty { showBatch = true }
        }
    }
}

struct NativeAssetDetail: View {
    let asset: NativeAsset
    @EnvironmentObject var store: HubStore
    @Environment(\.dismiss) var dismiss
    @State private var preview: URL?
    @State private var original: URL?
    @State private var shared: SharedFile?
    @State private var busy = false
    @State private var error: String?
    @State private var feedback: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let preview { FilePreview(url: preview).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error { ContentUnavailableView("预览未能加载", systemImage: "doc.questionmark", description: Text(error)) }
                else { ProgressView("正在加载预览…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(asset.title).font(.headline).textSelection(.enabled)
                    if let feedback { Label(feedback, systemImage: "checkmark.circle").font(.subheadline) }
                    if let error { Text(error).foregroundStyle(.orange).font(.subheadline) }
                    ViewThatFits(in: .horizontal) {
                        HStack { resultButtons }
                        VStack(alignment: .leading) { resultButtons }
                    }
                    if busy { ProgressView("正在获取原始文件…") }
                }.padding()
            }.navigationTitle("成果预览").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task(id: asset.id) {
                    do { let file = try await store.api.download(asset.preview, filename: asset.preview == asset.download ? asset.filename : ""); preview = file; if asset.preview == asset.download { original = file } }
                    catch { if !Task.isCancelled { self.error = "预览暂不可用，仍可尝试下载原文件。" } }
                }
                .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
        }
    }
    @ViewBuilder var resultButtons: some View {
        Button("下载原文件", systemImage: "square.and.arrow.down") { perform(savePhoto: false) }.buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(busy)
        if asset.kind == "image" || asset.kind == "video" {
            Button("保存到相册", systemImage: "photo.badge.arrow.down") { perform(savePhoto: true) }.buttonStyle(.bordered).frame(minHeight: 44).disabled(busy)
        }
        if preview == nil { Button("重试预览") { Task { do { preview = try await store.api.download(asset.preview); error = nil } catch { self.error = error.localizedDescription } } }.frame(minHeight: 44) }
    }
    func perform(savePhoto: Bool) {
        busy = true; error = nil; feedback = nil
        Task {
            do {
                let file: URL
                if let original { file = original }
                else { file = try await store.api.download(asset.download, filename: asset.filename); original = file }
                if savePhoto {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard status == .authorized || status == .limited else { throw HubFailure(message: "请在系统设置中允许 ToolHub 添加照片；也可以下载后通过分享面板保存。") }
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: asset.kind == "video" ? .video : .photo, fileURL: file, options: nil)
                    }
                    feedback = "已保存到系统相册。"
                } else { shared = SharedFile(url: file); feedback = "文件已下载，可存储到“文件”或分享。" }
                store.log(asset.title, detail: savePhoto ? "成果已保存到相册" : "成果文件已下载", success: true)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
