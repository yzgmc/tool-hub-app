import SwiftUI

/// 根路由：未配置服务器 → 配置页；已配置 → 主界面。
struct RootView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        if store.isConfigured {
            MainTabView()
        } else {
            SetupView()
        }
    }
}

/// 首次配置：服务器地址 + Token，测试连接通过后进入主页。
struct SetupView: View {
    @EnvironmentObject private var store: SettingsStore

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 品牌区
                    VStack(spacing: 10) {
                        Text("🛠️")
                            .font(.system(size: 64))
                        Text("ToolHub")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.ink)
                        Text("服务器总控台 · 手机客户端")
                            .font(.subheadline)
                            .foregroundColor(Theme.sub)
                    }
                    .padding(.top, 48)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("服务器地址").font(.footnote).foregroundColor(Theme.sub)
                            TextField("http://192.168.1.15:7072", text: $url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.plain)
                                .foregroundColor(Theme.ink)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Token").font(.footnote).foregroundColor(Theme.sub)
                            TextField("服务器 /opt/tools-hub/mobile/token.txt", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.plain)
                                .foregroundColor(Theme.ink)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
                        }

                        if let r = testResult {
                            Text(r)
                                .font(.footnote)
                                .foregroundColor(testOK ? Theme.ok : Theme.danger)
                        }

                        Button {
                            Task { await test() }
                        } label: {
                            HStack {
                                if testing { ProgressView().tint(.white) }
                                Text(testing ? "测试中…" : "测试连接")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(testOK ? Theme.ok : Theme.accent))
                            .foregroundColor(.white)
                        }
                        .disabled(testing)
                        .opacity(testing ? 0.45 : 1.0)

                        Button {
                            store.saveConfig(url, token)
                            Task { await store.syncManifest() }
                        } label: {
                            Text("保存并进入")
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .fill(Theme.ink))
                                .foregroundColor(.white)
                        }
                        .disabled(testing)
                        .opacity(testing ? 0.45 : 1.0)

                        if testResult != nil && !testOK {
                            Text("测试未通过也可以直接保存，进入后可在设置里继续调试。")
                                .font(.caption2)
                                .foregroundColor(Theme.sub)
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card)
                        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2))
                    .padding(.horizontal, 20)

                    Text("插件采用 OTA 同步：服务器新增功能后，App 无需重新安装，自动同步出现。")
                        .font(.caption)
                        .foregroundColor(Theme.sub)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            let c = APIClient(base: url, token: token)
            guard c.isValid else {
                testOK = false
                testResult = url.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "请先填写服务器地址" : "地址需以 http:// 或 https:// 开头"
                return
            }
            let ping = try await c.ping()
            if ping.ok == true {
                testOK = true
                let authHint = (ping.auth == true) ? "鉴权开启" : "鉴权关闭"
                testResult = "✅ 连接成功：\(ping.name ?? "服务器")（\(authHint)，清单版本 \(ping.version ?? 0)）"
                // 顺手把 token 存上，避免"保存并进入"时丢失输入
                token = token.trimmingCharacters(in: .whitespaces)
            } else {
                testOK = false
                testResult = "服务器响应异常"
            }
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }
}
