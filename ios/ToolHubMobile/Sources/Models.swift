import Foundation

indirect enum JSON: Codable, Equatable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
    var text: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
        case .bool(let v): return v ? "是" : "否"
        case .null: return ""
        case .array(let v): return v.map(\.text).joined(separator: "、")
        case .object: return ""
        }
    }
    var wireText: String {
        if case .bool(let value) = self { return value ? "true" : "false" }
        if case .array = self, let data = try? JSONEncoder().encode(self) { return String(data: data, encoding: .utf8) ?? "" }
        return text
    }
    var bool: Bool { self == .bool(true) }
    var number: Double { if case .number(let n) = self { return n }; return Double(text) ?? 0 }
    func render(_ template: String, fallback: String = "—") -> String {
        if template == "$" { return text.isEmpty ? fallback : text }
        guard let regex = try? NSRegularExpression(pattern: #"\$\.[A-Za-z0-9_\.\[\]-]+"#) else { return fallback }
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        if matches.isEmpty { return template.isEmpty ? fallback : template }
        var result = template
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let resolved = value(at: String(result[range])).text
            result.replaceSubrange(range, with: resolved.isEmpty ? fallback : resolved)
        }
        return result
    }
    func value(at path: String) -> JSON {
        if path == "$" || path.isEmpty { return self }
        guard path.hasPrefix("$.") else { return .string(path) }
        return path.dropFirst(2).replacingOccurrences(of: "[", with: ".").replacingOccurrences(of: "]", with: "")
            .split(separator: ".").reduce(self) { current, key in
                if case .array(let a) = current, let i = Int(key), a.indices.contains(i) { return a[i] }
                return current[String(key)]
            }
    }
}

struct Catalog: Codable {
    let schemaVersion: Int
    let version: String
    let plugins: [Plugin]
}
struct Plugin: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let category: String
    let symbol: String
    let kind: String
    let controllable: Bool
    let configured: Bool
    let pages: [NativePage]
    let warnings: [String]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.pages == rhs.pages }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
struct NativePage: Codable, Equatable {
    let title: String?
    let layout: [JSON]
}
struct HubFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
