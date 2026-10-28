import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SharedFile: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CameraCapture: UIViewControllerRepresentable {
    var completion: (UIImage?) -> Void
    @Environment(\.dismiss) var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ parent: CameraCapture) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.completion(info[.originalImage] as? UIImage); parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct NativeUpload: View {
    let spec: JSON
    var completion: (String) -> Void
    @EnvironmentObject var store: HubStore
    @State private var photo: PhotosPickerItem?
    @State private var fields: [String: JSON] = [:]
    @State private var result: JSON = .null
    @State private var camera = false
    @State private var importer = false
    @State private var selectedData: Data?
    @State private var filename = ""
    @State private var mime = "application/octet-stream"
    @State private var preview: UIImage?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeFields(definitions: spec["inputs"].array, values: $fields)
            if let preview { Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityLabel("待上传图片预览") }
            ViewThatFits(in: .horizontal) {
                HStack { mediaButtons }
                VStack(alignment: .leading) { mediaButtons }
            }
            if selectedData != nil {
                Label(filename, systemImage: "doc").font(.subheadline).lineLimit(2)
                Button { upload() } label: { Label(busy ? "正在上传…" : "上传到服务器", systemImage: "arrow.up.circle.fill") }
                    .buttonStyle(.borderedProminent).disabled(busy).frame(minHeight: 44)
            }
            if busy { ProgressView() }
            if result != .null {
                NativeResult(value: result, definitions: spec["resultItems"].array)
                if !result["url"].text.isEmpty { NativeGallery(rows: [result], spec: .null) }
            }
            if let error { Text(error).font(.subheadline).foregroundStyle(.orange) }
        }
        .sheet(isPresented: $camera) { CameraCapture { image in
            guard let image, let data = image.jpegData(compressionQuality: 0.88) else { return }
            preview = image; selectedData = data; filename = "Camera.jpg"; mime = "image/jpeg"; error = nil
        }.ignoresSafeArea() }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 100 * 1024 * 1024 else { throw HubFailure(message: "请选择 100 MB 以内的文件。") }
                let data = try Data(contentsOf: url)
                if spec["endpoint"].text == "/api/scan-upload" {
                    guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.88) else {
                        throw HubFailure(message: "扫描工具需要图片文件。")
                    }
                    selectedData = jpeg; filename = "Scan.jpg"; mime = "image/jpeg"; preview = image
                } else {
                    selectedData = data; filename = url.lastPathComponent
                    mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    preview = UIImage(data: data)
                }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                          let jpeg = image.jpegData(compressionQuality: 0.88) else { throw HubFailure(message: "无法读取所选照片。") }
                    selectedData = jpeg; preview = image; filename = "Photo.jpg"; mime = "image/jpeg"; error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    @ViewBuilder var mediaButtons: some View {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button { camera = true } label: { Label("拍照", systemImage: "camera") }.buttonStyle(.bordered).frame(minHeight: 44).disabled(busy)
        }
        PhotosPicker(selection: $photo, matching: .images) { Label("照片", systemImage: "photo") }.buttonStyle(.bordered).frame(minHeight: 44).disabled(busy)
        Button { importer = true } label: { Label("文件", systemImage: "folder") }.buttonStyle(.bordered).frame(minHeight: 44).disabled(busy)
    }
    func upload() {
        guard let data = selectedData else { return }
        busy = true; error = nil
        Task {
            do {
                var values = fields
                values["filename"] = .string(filename)
                for field in spec["inputs"].array {
                    let value = NativeBinding.fieldValue(field, row: .null, values: values)
                    if let message = NativeBinding.validation(field, value: value) { throw HubFailure(message: message) }
                    values[field["name"].text] = value
                }
                var resolved = NativeBinding.value(spec, row: .null, fields: values).object
                var uploadFields = spec["fields"].object
                for (key, value) in values { uploadFields[key] = value }
                resolved["fields"] = .object(uploadFields)
                resolved["endpoint"] = .string(NativeBinding.endpoint(spec["endpoint"].text, row: .null, fields: values))
                result = try await store.api.upload(.object(resolved), data: data, name: filename, mime: mime)
                completion("上传成功，下拉刷新查看处理结果。")
                store.log(spec["title"].text, detail: "文件已上传", success: true)
                selectedData = nil; preview = nil; photo = nil
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct RemoteImage: View {
    let path: String
    @EnvironmentObject var store: HubStore
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Label("图片不可用", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
            else { ProgressView() }
        }.frame(minHeight: 90, maxHeight: 180).frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("工具结果图片")
            .task(id: path) {
                image = nil; failed = false
                guard !path.isEmpty else { failed = true; return }
                do {
                    let (data, _) = try await store.api.raw(store.api.request(path))
                    image = UIImage(data: data); failed = image == nil
                } catch { failed = true }
            }
    }
}
