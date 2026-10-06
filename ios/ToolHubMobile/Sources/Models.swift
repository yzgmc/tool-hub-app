import Foundation

// ---------------------------------------------------------------------------
// manifest 契约模型。全部字段 Optional + 宽容解码：服务器端清单缺字段/多字段
// 都不影响解析，任何一层出错都不该让整个 App 崩溃。
// ---------------------------------------------------------------------------

struct Manifest: Codable {
    var version: Int?
    var name: String?
    var plugins: [Plugin]?

    /// 钉选到底部标签栏的原生插件（最多 2 个）
    var pinnedPlugins: [Plugin] {
        (plugins ?? []).filter { ($0.pinned ?? false) && $0.isNative }.prefix(2).map { $0 }
    }
}

struct Plugin: Codable, Identifiable {
    var id: String
    var name: String?
    var tag: String?
    var icon: String?
    var color: String?
    var desc: String?
    var type: String?        // "native" | "web"
    var url: String?
    var pinned: Bool?
    var pages: [PluginPage]?

    var isNative: Bool { (type ?? "web") == "native" }
    var displayName: String { name ?? id }
    var displayIcon: String { icon ?? "🧩" }
}

struct PluginPage: Codable {
    var title: String?
    var layout: [WidgetSpec]?
}

// ---------------------------------------------------------------------------
// Widget 声明
// ---------------------------------------------------------------------------

struct WidgetSpec: Codable {
    var type: String          // stats | gauge | chart | list | keyvalue | auto | actions
                              // | chat | upload | imagegrid | progress
    var title: String?
    var endpoint: String?
    var refresh: Double?      // 刷新秒数
    var items: [FlexItem]?    // stats: 对象数组 / keyvalue: 路径字符串数组
    var value: String?        // gauge/chart/progress 取值路径
    var max: Double?          // gauge 满刻度
    var unit: String?
    var history: Int?         // chart 历史点数
    var item: ListItemSpec?   // list 行映射
    var actions: [ActionSpec]?
    var status: String?       // progress 状态文本路径
    // chat
    var inputField: String?         // 发送请求体的键名
    var response: String?           // 回复文本取值路径
    var placeholder: String?        // 输入框占位文本
    var chatHistory: ChatHistory?   // 历史配置（JSON 里同样是 "history" 键）
    // upload
    var fileParam: String?          // 文件字段名
    var accept: String?             // "image" 用相册选择，其余用文件导入
    var fields: [String: String]?   // 附加表单字段
    // imagegrid
    var listPath: String?           // 列表取值路径
    var urlPath: String?            // 图片地址路径
    var titlePath: String?          // 标题路径

    private enum CodingKeys: String, CodingKey {
        case type, title, endpoint, refresh, items, value, max, unit, history,
             item, actions, status, inputField, response, placeholder,
             fileParam, accept, fields, listPath, urlPath, titlePath
    }

    /// 手写解码：history 键兼容 chart 的点数(Int)与 chat 的历史配置(对象)两种形态；
    /// 其余字段缺键/类型不符一律置 nil，绝不让整个清单解析失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        endpoint = try? c.decodeIfPresent(String.self, forKey: .endpoint)
        refresh = try? c.decodeIfPresent(Double.self, forKey: .refresh)
        items = try? c.decodeIfPresent([FlexItem].self, forKey: .items)
        value = try? c.decodeIfPresent(String.self, forKey: .value)
        max = try? c.decodeIfPresent(Double.self, forKey: .max)
        unit = try? c.decodeIfPresent(String.self, forKey: .unit)
        item = try? c.decodeIfPresent(ListItemSpec.self, forKey: .item)
        actions = try? c.decodeIfPresent([ActionSpec].self, forKey: .actions)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        inputField = try? c.decodeIfPresent(String.self, forKey: .inputField)
        response = try? c.decodeIfPresent(String.self, forKey: .response)
        placeholder = try? c.decodeIfPresent(String.self, forKey: .placeholder)
        fileParam = try? c.decodeIfPresent(String.self, forKey: .fileParam)
        accept = try? c.decodeIfPresent(String.self, forKey: .accept)
        fields = try? c.decodeIfPresent([String: String].self, forKey: .fields)
        listPath = try? c.decodeIfPresent(String.self, forKey: .listPath)
        urlPath = try? c.decodeIfPresent(String.self, forKey: .urlPath)
        titlePath = try? c.decodeIfPresent(String.self, forKey: .titlePath)
        // history 双形态：对象 → chat 历史配置，数字 → chart 点数
        if let h = try? c.decodeIfPresent(ChatHistory.self, forKey: .history) {
            chatHistory = h
        } else {
            history = try? c.decodeIfPresent(Int.self, forKey: .history)
        }
    }
}

/// stats 的 items 是对象、keyvalue 的 items 是字符串，用同一字段名——
/// 用 FlexItem 兼容两种形态。
enum FlexItem: Codable {
    case path(String)
    case stat(StatItem)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .path(s)
        } else {
            self = .stat(try c.decode(StatItem.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .path(let s): try c.encode(s)
        case .stat(let s): try c.encode(s)
        }
    }
}

struct StatItem: Codable {
    var label: String?
    var value: String?
    var unit: String?
}

struct ListItemSpec: Codable {
    var title: String?
    var subtitle: String?
    var value: String?
    var valueUnit: String?
    var actions: [ActionSpec]?   // 行级操作（如 qbt 暂停/恢复）
}

/// chat 组件的历史记录接口配置
struct ChatHistory: Codable {
    var endpoint: String?    // 历史拉取地址（GET）
    var role: String?        // 角色字段路径
    var content: String?     // 内容字段路径
}

struct ActionSpec: Codable {
    var label: String?
    var endpoint: String?
    var method: String?
    var confirm: String?
    var style: String?       // "danger" 红色按钮
    var body: JSONValue?
    var open: Bool?          // true: 用 Safari 打开链接（如文件下载），不发网络请求
    var paramFrom: String?   // 行级操作：从行数据取值的路径
    var paramKey: String?    // 行级操作：注入请求体的键名
    var encoding: String?    // "form" 表单编码
}

// ---------------------------------------------------------------------------
// 任意 JSON 值（action.body 之类类型不定的字段）
// ---------------------------------------------------------------------------

enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// JSONSerialization 产物转 JSONValue（未知类型一律 .null，不崩溃）
    static func from(_ v: Any) -> JSONValue {
        switch v {
        case is NSNull:
            return .null
        case let n as NSNumber:
            // Bool 经 JSONSerialization 也是 NSNumber，用 CF 类型区分
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map { from($0) })
        case let o as [String: Any]:
            return .object(o.mapValues { from($0) })
        default:
            return .null
        }
    }
}

// ---------------------------------------------------------------------------
// overview / 服务启停
// ---------------------------------------------------------------------------

struct Overview: Decodable {
    var health: HealthInfo?
    var services: ServicesInfo?
}

struct HealthInfo: Decodable {
    var up: Int?
    var total: Int?
    var tools: [ToolHealth]?
}

struct ToolHealth: Decodable, Identifiable {
    var id: String?
    var up: Bool?
}

struct ServicesInfo: Decodable {
    var states: [String: ServiceState]?
    var total: Int?
    var controllable: Int?
}

struct ServiceState: Decodable {
    var running: Bool?
    var port: Int?
    var port_open: Bool?
    var controllable: Bool?
}

struct ServiceResult: Decodable {
    var ok: Bool?
    var running: Bool?
    var msg: String?
    var logs: [String]?

    var summary: String {
        var lines = logs ?? []
        if let m = msg, !lines.contains(m) { lines.insert(m, at: 0) }
        return lines.isEmpty ? (ok == true ? "操作成功" : "操作失败") : lines.joined(separator: "\n")
    }
}

struct PingResponse: Decodable {
    var ok: Bool?
    var name: String?
    var version: Int?
    var auth: Bool?
}

struct ManifestVersion: Decodable {
    var version: Int?
}

/// 已知外部服务的友好名称（与总控台 external_tools 对应，未收录的显示 id）
enum ServiceNames {
    static let map: [String: String] = [
        "dsh": "DeepSeek Harness",
        "fllm": "FreeLLMAPI 路由",
        "alist": "AList 网盘",
        "mcsm": "MCSManager",
        "wvc": "WebVirtCloud",
        "schulte": "舒尔特方格",
        "openclaw": "OpenClaw Control",
        "llamacpp": "Llama.cpp 推理",
        "glucose": "血糖监测",
        "novnc2": "noVNC 容器桌面",
        "comfyui": "ComfyUI 绘图",
        "immich": "Immich 相册",
        "vdesktop": "虚拟桌面",
        "bilinote": "BiliNote 视频笔记",
        "qbittorrent": "qBittorrent 下载",
        "wangp": "WanGP AI 视频"
    ]
    static func name(_ id: String) -> String { map[id] ?? id }
}
