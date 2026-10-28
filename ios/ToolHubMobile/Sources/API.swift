import Foundation
import Security

struct Connection: Equatable {
    var server: String
    var token: String
}

enum SecureToken {
    static let service = "com.yxp.toolhub.connection.v2"
    static func read() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "gateway", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "gateway"]
        SecItemDelete(q as CFDictionary)
        if value.isEmpty { return }
        var insert = q
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw HubFailure(message: "无法将连接令牌保存到钥匙串。")
        }
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let origin = task.originalRequest?.url, let target = request.url,
              origin.scheme == target.scheme, origin.host == target.host, origin.port == target.port else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

struct HubAPI {
    let connection: Connection
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()
    func url(_ path: String) throws -> URL {
        guard var base = URLComponents(string: connection.server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme ?? ""), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              !path.components(separatedBy: "/").contains(".."),
              let relative = URLComponents(string: path), relative.host == nil, relative.scheme == nil,
              !relative.path.components(separatedBy: "/").contains("..") else {
            throw HubFailure(message: "请输入有效的服务器地址，例如 https://hub.example.com。")
        }
        base.path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "" : "/" + base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        base.path += relative.path
        // Existing gallery URLs may carry old query tokens; send credentials only in headers.
        base.queryItems = relative.queryItems?.filter { $0.name != "token" }
        guard let result = base.url else { throw HubFailure(message: "接口地址无效。") }
        return result
    }
    func request(_ path: String, method: String = "GET", body: JSON? = nil, form: Bool = false) throws -> URLRequest {
        var r = URLRequest(url: try url(path))
        r.httpMethod = method.uppercased()
        r.setValue(connection.token, forHTTPHeaderField: "X-ToolHub-Token")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if path.hasPrefix("/proxy/phone/ios12/") { r.setValue("1", forHTTPHeaderField: "X-WDA-Control") }
        if path.hasPrefix("/proxy/ddns/") { r.setValue("1", forHTTPHeaderField: "X-DDNS-Request") }
        if let body, r.httpMethod != "GET" {
            if form {
                var c = URLComponents(); c.queryItems = body.object.map { URLQueryItem(name: $0.key, value: $0.value.text) }
                r.httpBody = c.percentEncodedQuery?.data(using: .utf8)
                r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            } else {
                r.httpBody = try JSONEncoder().encode(body)
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return r
    }
    func raw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubFailure(message: "服务器没有返回有效响应。") }
        if http.statusCode == 401 { throw HubFailure(message: "连接令牌无效，请在设置中重新填写。") }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONDecoder().decode(JSON.self, from: data)
            let detail = json?["error"]["message"].text ?? ""
            throw HubFailure(message: detail.isEmpty ? "请求失败（HTTP \(http.statusCode)），请重试。" : detail)
        }
        return (data, http)
    }
    func json(_ path: String, method: String = "GET", body: JSON? = nil, form: Bool = false) async throws -> JSON {
        let (data, _) = try await raw(request(path, method: method, body: body, form: form))
        if data.isEmpty { return .object([:]) }
        guard let result = try? JSONDecoder().decode(JSON.self, from: data) else {
            throw HubFailure(message: "此接口没有返回 JSON，请更新插件的原生 API 配置。")
        }
        if result["ok"] == .bool(false) {
            let message = result["error"]["message"].text.isEmpty ? result["msg"].text : result["error"]["message"].text
            throw HubFailure(message: message.isEmpty ? "服务器未能完成操作。" : message)
        }
        if result.object.keys.contains("data") && result.object.keys.contains("error") { return result["data"] }
        return result
    }
    func catalog() async throws -> Catalog {
        let value = try await json("/api/v1/native/manifest")
        let catalog = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(value))
        guard catalog.schemaVersion == 2 else { throw HubFailure(message: "服务器清单版本不兼容，请更新 App。") }
        return catalog
    }
    func upload(_ spec: JSON, data: Data, name: String, mime: String) async throws -> JSON {
        var request = try request(spec["endpoint"].text, method: "POST")
            let boundary = UUID().uuidString
            var body = Data()
            func append(_ text: String) { body.append(Data(text.utf8)) }
            for (key, value) in spec["fields"].object {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value.text)\r\n")
            }
            let fileKey = spec["fileParam"].text.isEmpty ? "file" : spec["fileParam"].text
            let safeName = name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileKey)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n")
            body.append(data); append("\r\n--\(boundary)--\r\n")
            request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await raw(request)
        let result = try JSONDecoder().decode(JSON.self, from: data)
        if result["ok"] == .bool(false) { throw HubFailure(message: result["msg"].text) }
        return result
    }
    func download(_ path: String) async throws -> URL {
        let (data, http) = try await raw(request(path))
        let ext = http.mimeType == "image/png" ? "png" : http.mimeType == "image/jpeg" ? "jpg" : "dat"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ToolHub-\(UUID().uuidString).\(ext)")
        try data.write(to: file, options: .atomic)
        return file
    }
}
