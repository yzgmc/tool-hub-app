import SwiftUI

struct NativeRemote: View {
    let spec: JSON
    @EnvironmentObject var store: HubStore
    @Environment(\.scenePhase) var phase
    @State private var frame: UIImage?
    @State private var error: String?
    @State private var text = ""
    @State private var fullScreen = false
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            display
            Button("全屏控制", systemImage: "arrow.up.left.and.arrow.down.right") { fullScreen = true }.frame(minHeight: 44)
            keyboard
            if let error { Text(error).font(.subheadline).foregroundStyle(.orange) }
        }.task { await frames() }
            .fullScreenCover(isPresented: $fullScreen) {
                NavigationStack {
                    ScrollView { VStack(spacing: 20) { display; keyboard }.padding() }
                        .navigationTitle(spec["title"].text).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { fullScreen = false } } }
                }
            }
    }
    @ViewBuilder var display: some View {
        if let frame {
            GeometryReader { geometry in
                Image(uiImage: frame).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                        let scale = min(geometry.size.width / frame.size.width, geometry.size.height / frame.size.height)
                        let size = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
                        let origin = CGPoint(x: (geometry.size.width-size.width)/2, y: (geometry.size.height-size.height)/2)
                        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x-origin.x)/size.width, y: (p.y-origin.y)/size.height) }
                        let from = point(gesture.startLocation), to = point(gesture.location)
                        guard [from.x,from.y,to.x,to.y].allSatisfy({ $0 >= 0 && $0 <= 1 }) else { return }
                        if abs(gesture.translation.width)+abs(gesture.translation.height) < 8 {
                            send("tap", body: ["x": .number(from.x), "y": .number(from.y)])
                        } else if spec["actionMode"].text == "path" {
                            send("swipe", body: ["fromX": .number(from.x), "fromY": .number(from.y), "toX": .number(to.x), "toY": .number(to.y)])
                        } else {
                            send("swipe", body: ["x": .number(from.x), "y": .number(from.y), "toX": .number(to.x), "toY": .number(to.y)])
                        }
                    })
            }.aspectRatio(frame.size.width/frame.size.height, contentMode: .fit)
                .accessibilityLabel("远程画面，可点击或拖动")
        } else { ProgressView("正在连接画面…").frame(maxWidth: .infinity, minHeight: 160) }
    }
    var keyboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("发送文字到远程设备", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("发送文字", systemImage: "keyboard") { let value = text; text = ""; send("text", body: ["text": .string(value)]) }.frame(minHeight: 44).disabled(text.isEmpty || busy)
            if spec["actionMode"].text != "path" {
                HStack { ForEach(["enter", "escape", "backspace", "tab"], id: \.self) { key in
                    Button(["enter":"回车","escape":"退出","backspace":"退格","tab":"Tab"][key] ?? key) { send("key", body: ["key": .string(key)]) }.buttonStyle(.bordered).frame(minHeight: 44)
                } }
            }
        }
    }
    func frames() async {
        while !Task.isCancelled {
            if phase == .active {
                do {
                    let (data, _) = try await store.api.raw(store.api.request(spec["endpoint"].text))
                    if let image = UIImage(data: data) { frame = image; error = nil }
                    else { error = "设备未返回有效画面。" }
                } catch { if !Task.isCancelled { self.error = "画面暂不可用，请确认设备或桌面已连接。" } }
            }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { break }
        }
    }
    func send(_ action: String, body: [String: JSON]) {
        guard !busy else { return }; busy = true
        Task {
            do {
                var payload = body
                var path = spec["actionEndpoint"].text
                if spec["actionMode"].text == "path" { path += "/" + action }
                else { payload["action"] = .string(action) }
                _ = try await store.api.json(path, method: "POST", body: .object(payload)); error = nil
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
