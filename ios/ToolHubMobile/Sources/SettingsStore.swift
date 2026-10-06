import Foundation
import SwiftUI

/// 全局配置与清单状态：持久化到 UserDefaults，冷启动先读缓存清单秒开，
/// 再后台同步最新版本（OTA 核心）。
@MainActor
final class SettingsStore: ObservableObject {

    // 配置
    @Published var serverURL: String
    @Published var token: String

    // 清单
    @Published var manifest: Manifest?
    @Published var lastSync: Date?
    @Published var lastError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        token = defaults.string(forKey: "token") ?? ""
        lastSync = defaults.object(forKey: "lastSync") as? Date

        // 冷启动：先恢复缓存的清单 JSON
        if let raw = defaults.string(forKey: "manifestCache"),
           let data = raw.data(using: .utf8),
           let m = try? JSONDecoder().decode(Manifest.self, from: data) {
            manifest = m
        }
    }

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var client: APIClient {
        APIClient(base: serverURL, token: token)
    }

    func saveConfig() {
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(token, forKey: "token")
        objectWillChange.send()
    }

    func saveConfig(_ url: String, _ tok: String) {
        serverURL = url
        token = tok
        saveConfig()
    }

    func reset() {
        serverURL = ""
        token = ""
        manifest = nil
        lastSync = nil
        lastError = nil
        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "token")
        defaults.removeObject(forKey: "manifestCache")
        defaults.removeObject(forKey: "lastSync")
    }

    /// 拉取最新清单并落盘缓存
    func syncManifest() async {
        let c = client
        guard c.isValid else {
            lastError = "服务器地址无效（需 http:// 或 https://）"
            return
        }
        do {
            let m = try await c.manifest()
            manifest = m
            lastError = nil
            lastSync = Date()
            defaults.set(lastSync, forKey: "lastSync")
            if let data = try? JSONEncoder().encode(m),
               let raw = String(data: data, encoding: .utf8) {
                defaults.set(raw, forKey: "manifestCache")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// OTA 轮询：版本号变化才重新拉清单
    func checkVersion() async {
        guard isConfigured else { return }
        do {
            let v = try await client.manifestVersion()
            if v != (manifest?.version ?? -1) {
                await syncManifest()
            }
        } catch {
            // 静默：轮询失败不打扰用户，错误会在手动刷新时显示
        }
    }

    var manifestVersionText: String {
        guard let v = manifest?.version else { return "未同步" }
        return String(v)
    }
}
