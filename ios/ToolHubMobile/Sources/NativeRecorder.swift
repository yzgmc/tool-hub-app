import SwiftUI
import AVFoundation

@MainActor final class NativeRecording: ObservableObject {
    @Published var recording = false
    @Published var file: URL?
    @Published var error: String?
    private var recorder: AVAudioRecorder?
    func start() async {
        let allowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { error = "请在系统设置中允许 ToolHub 使用麦克风。"; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("Recording-\(UUID().uuidString).m4a")
            recorder = try AVAudioRecorder(url: path, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192000])
            guard recorder?.record() == true else { throw HubFailure(message: "无法开始录音。") }
            recording = true; file = path; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func stop() { recorder?.stop(); recording = false; try? AVAudioSession.sharedInstance().setActive(false) }
    func discard() { stop(); if let file { try? FileManager.default.removeItem(at: file) }; file = nil }
}

struct NativeRecorder: View {
    let spec: JSON
    @EnvironmentObject var store: HubStore
    @StateObject private var recorder = NativeRecording()
    @State private var fields: [String: JSON] = [:]
    @State private var busy = false
    @State private var feedback: String?
    @State private var result: JSON = .null
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeFields(definitions: spec["fields"].array, values: $fields)
            if recorder.recording {
                Label("正在录音…", systemImage: "waveform").foregroundStyle(.red)
                Button("停止录音", systemImage: "stop.circle") { recorder.stop() }.buttonStyle(.borderedProminent).frame(minHeight: 44)
            } else {
                Button("开始录音", systemImage: "mic") { Task { await recorder.start() } }.buttonStyle(.bordered).frame(minHeight: 44).disabled(busy)
            }
            if recorder.file != nil && !recorder.recording {
                HStack {
                    Button("上传录音", systemImage: "arrow.up.circle") { upload() }.buttonStyle(.borderedProminent).disabled(busy)
                    Button("重新录制") { recorder.discard() }.buttonStyle(.bordered).disabled(busy)
                }.frame(minHeight: 44)
            }
            if busy { ProgressView("正在上传并检查录音…") }
            if let error = recorder.error { Text(error).foregroundStyle(.orange).font(.subheadline) }
            if let feedback { Text(feedback).font(.subheadline) }
            NativeResult(value: result, definitions: spec["resultItems"].array)
        }.onDisappear { recorder.stop() }
    }
    func upload() {
        guard let file = recorder.file else { return }
        var values = fields
        for field in spec["fields"].array {
            let v = NativeBinding.fieldValue(field, row: .null, values: values)
            if let error = NativeBinding.validation(field, value: v) { recorder.error = error; return }
            values[field["name"].text] = v
        }
        busy = true; feedback = nil
        Task {
            do {
                var request = spec.object
                request["endpoint"] = .string(NativeBinding.endpoint(spec["endpoint"].text, row: .null, fields: values))
                request["encoding"] = .string("raw")
                result = try await store.api.upload(.object(request), data: Data(contentsOf: file), name: "Recording.m4a", mime: "audio/mp4")
                feedback = "录音已上传。"; recorder.discard()
            } catch { recorder.error = error.localizedDescription }
            busy = false
        }
    }
}
