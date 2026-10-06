import Foundation

enum APIError: LocalizedError {
    case badURL
    case unauthorized
    case http(Int)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .unauthorized: return "Token 无效或已变更，请在设置里核对"
        case .http(let code): return "服务器返回 \(code)"
        case .network(let msg): return "连接失败：\(msg)"
        case .decode(let msg): return "数据解析失败：\(msg)"
        }
    }
}

/// 网关 API 客户端：所有请求带 X-ToolHub-Token；值类型，随用随建。
struct APIClient {
    var base: String      // 如 "http://192.168.1.15:7072"（末尾不带 /）
    var token: String

    init(base: String, token: String) {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        base.hasPrefix("http://") || base.hasPrefix("https://")
    }

    func makeRequest(_ path: String, method: String = "GET",
                     jsonBody: Data? = nil, timeout: TimeInterval = 10,
                     auth: Bool = true) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw APIError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth && !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-ToolHub-Token")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        return req
    }

    private func data(for req: URLRequest) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.network("非 HTTP 响应") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw APIError.unauthorized
        case let code:
            // 尽量带回服务端的 msg
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["msg"] as? String {
                throw APIError.network("\(msg)（\(code)）")
            }
            throw APIError.http(code)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decode(String(describing: error))
        }
    }

    // ---------------------------------------------------------------- API

    func ping() async throws -> PingResponse {
        let req = try makeRequest("/api/ping", auth: false)
        let d = try await data(for: req)
        let r: PingResponse = try decode(d)
        return r
    }

    func manifest() async throws -> Manifest {
        let req = try makeRequest("/api/manifest")
        let d = try await data(for: req)
        return try decode(d)
    }

    func manifestVersion() async throws -> Int {
        let req = try makeRequest("/api/manifest/version")
        let d = try await data(for: req)
        let r: ManifestVersion = try decode(d)
        return r.version ?? 0
    }

    func overview() async throws -> Overview {
        let req = try makeRequest("/api/overview", timeout: 15)
        let d = try await data(for: req)
        return try decode(d)
    }

    func serviceAction(_ sid: String, _ action: String) async throws -> ServiceResult {
        let req = try makeRequest("/api/services/\(sid)/\(action)", method: "POST", timeout: 300)
        let d = try await data(for: req)
        return try decode(d)
    }

    /// /proxy 反代 GET，返回 JSONSerialization 产物（widget 数据源）。
    /// encoding == "form" 时把 body（JSONValue.object）转成表单编码发送。
    func proxyJSON(_ path: String, method: String = "GET",
                   body: JSONValue? = nil, timeout: TimeInterval = 60,
                   encoding: String? = nil) async throws -> Any {
        var bodyData: Data?
        if let b = body, method != "GET" {
            bodyData = (encoding == "form") ? Self.formBody(b) : try? JSONEncoder().encode(b)
        }
        var req = try makeRequest(path, method: method, jsonBody: bodyData, timeout: timeout)
        if encoding == "form" && bodyData != nil {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let d = try await data(for: req)
        let obj = try? JSONSerialization.jsonObject(with: d)
        return obj ?? [:]
    }

    /// multipart/form-data 上传：fields 先于 file，boundary 随机。
    /// 错误处理与 data(for:) 一致（401 → unauthorized）。
    func upload(path: String, fileData: Data, fileName: String, mimeType: String,
                fileParam: String = "file", fields: [String: String] = [:]) async throws -> Any {
        let boundary = "toolhub-\(UUID().uuidString)"
        var req = try makeRequest(path, method: "POST", timeout: 300)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func line(_ s: String) { body.append(s.data(using: .utf8) ?? Data()) }
        // 附加表单字段先于文件
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)\r\n")
            line("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            line("\(v)\r\n")
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "")
        line("--\(boundary)\r\n")
        line("Content-Disposition: form-data; name=\"\(fileParam)\"; filename=\"\(safeName)\"\r\n")
        line("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        line("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let d = try await data(for: req)
        let obj = try? JSONSerialization.jsonObject(with: d)
        return obj ?? [:]
    }

    /// JSONValue.object → "k=v&k2=v2"（value 数组用 "|" 连接，percentEncode 转义）
    static func formBody(_ body: JSONValue) -> Data? {
        guard case .object(let obj) = body else { return nil }
        let pairs = obj.sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode(formString($0.value)))" }
        return pairs.joined(separator: "&").data(using: .utf8)
    }

    /// JSONValue → 表单字符串（数组用 | 连接，嵌套对象不支持留空）
    private static func formString(_ v: JSONValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return String(n)
        case .string(let s): return s
        case .array(let arr): return arr.map { formString($0) }.joined(separator: "|")
        case .object: return ""
        }
    }

    /// percentEncode：保留字母数字与 -._~，其余（含中文）按 UTF-8 转义
    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// widget action 执行：POST/GET 后把返回转成人话摘要（透传 encoding）
    func runAction(_ spec: ActionSpec) async throws -> String {
        let method = (spec.method ?? "POST").uppercased()
        guard let endpoint = spec.endpoint else { throw APIError.badURL }
        let obj = try await proxyJSON(endpoint, method: method, body: spec.body,
                                      timeout: 120, encoding: spec.encoding)
        if let dict = obj as? [String: Any] {
            var lines: [String] = []
            if let ok = dict["ok"] as? Bool {
                lines.append(ok ? "✅ 操作成功" : "❌ 操作失败")
            }
            if let msg = dict["msg"] as? String { lines.append(msg) }
            if let logs = dict["logs"] as? [Any] {
                lines.append(contentsOf: logs.compactMap { JSONPath.display($0) })
            }
            return lines.isEmpty ? "已执行" : lines.joined(separator: "\n")
        }
        return "已执行"
    }
}
