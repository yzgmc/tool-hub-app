import SwiftUI

struct ActivityEntry: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let success: Bool
    let date = Date()
}

@MainActor final class HubStore: ObservableObject {
    @Published var connection: Connection
    @Published var catalog: Catalog?
    @Published var overview: JSON = .null
    @Published var loading = false
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var activities: [ActivityEntry] = []
    @Published var favorites: Set<String>
    @Published var pendingConnection: Connection?
    private var generation = 0
    var api: HubAPI { HubAPI(connection: connection) }
    var plugins: [Plugin] { catalog?.plugins ?? [] }
    var configured: Bool { !connection.server.isEmpty }
    init() {
        connection = Connection(server: UserDefaults.standard.string(forKey: "server.v2") ?? "", token: SecureToken.read())
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites.v2") ?? [])
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites.v2")
    }
    func connect(_ value: Connection) async throws {
        let candidate = HubAPI(connection: value)
        let next = try await candidate.catalog()
        try SecureToken.save(value.token)
        generation += 1
        connection = value; catalog = next; overview = .null; updatedAt = Date(); error = nil
        UserDefaults.standard.set(value.server, forKey: "server.v2")
        await refresh()
    }
    func refresh() async {
        guard configured, !loading else { return }
        loading = true; error = nil
        let ticket = generation, client = api
        defer { loading = false }
        do {
            let next = try await client.catalog()
            guard generation == ticket else { return }
            catalog = next; updatedAt = Date()
            do { overview = try await client.json("/api/v1/overview") }
            catch { self.error = "工具目录已同步，服务状态暂不可用。" }
        } catch {
            if generation == ticket { self.error = error.localizedDescription }
        }
    }
    func online(_ plugin: Plugin) -> Bool? {
        if plugin.kind == "external" {
            let state = overview["services"]["states"][plugin.id]
            if state == .null { return nil }
            return state["port_open"].bool || state["running"].bool
        }
        let found = overview["health"]["tools"].array.first { $0["id"].text == plugin.id }
        return found?["up"].bool
    }
    func log(_ title: String, detail: String, success: Bool) {
        activities.insert(ActivityEntry(title: title, detail: detail, success: success), at: 0)
        if activities.count > 60 { activities.removeLast() }
    }
    func receive(_ url: URL) {
        guard url.scheme == "toolhub", url.host == "connect",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let server = c.queryItems?.first(where: { $0.name == "server" })?.value else { return }
        pendingConnection = Connection(server: server, token: c.queryItems?.first(where: { $0.name == "token" })?.value ?? "")
    }
}
