import Foundation

/// 极简 JSONPath：从 JSONSerialization 产物（Any）按 "$.a.b.0.c" 取值。
/// 取不到一律返回 nil，由调用方显示 "--"，绝不崩溃。
enum JSONPath {

    static func resolve(_ root: Any?, _ path: String?) -> Any? {
        guard let path, path.hasPrefix("$") else { return nil }
        var cur: Any? = root
        // "$.a.b.0.c" -> ["a","b","0","c"]；根本身为 "$" 时 parts 为空
        let parts = path.dropFirst().split(separator: ".").filter { !$0.isEmpty }
        for p in parts {
            guard let c = cur else { return nil }
            if let dict = c as? [String: Any] {
                cur = dict[String(p)]
            } else if let arr = c as? [Any], let idx = Int(p) {
                cur = (idx >= 0 && idx < arr.count) ? arr[idx] : nil
            } else {
                return nil
            }
        }
        return cur
    }

    /// 把任意 JSON 标量转成可显示字符串。
    static func display(_ v: Any?) -> String {
        guard let v else { return "--" }
        switch v {
        case is NSNull:
            return "--"
        case let n as NSNumber:
            // JSONSerialization 下 Bool 也是 NSNumber，用 CF 类型区分
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "开" : "关"
            }
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 {
                return String(Int64(d))
            }
            return String(format: "%.1f", d)
        case let s as String:
            return s.isEmpty ? "--" : s
        case let dict as [String: Any]:
            return "\(dict.count) 项"
        case let arr as [Any]:
            return "\(arr.count) 项"
        default:
            return String(describing: v)
        }
    }

    /// 数字取值（gauge/chart 用），取不到返回 nil。
    static func number(_ root: Any?, _ path: String?) -> Double? {
        guard let v = resolve(root, path) else { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            return n.doubleValue
        }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// auto 组件：把顶层字典递归平铺（深度 2）为键值对列表。
    static func flatten(_ root: Any?, depth: Int = 2) -> [(key: String, value: String)] {
        guard let dict = root as? [String: Any] else {
            if let arr = root as? [Any] { return [("数组", "\(arr.count) 项")] }
            return []
        }
        var out: [(String, String)] = []
        for (k, v) in dict {
            if let sub = v as? [String: Any], depth > 0 {
                for (k2, v2) in sub {
                    out.append(("\(k).\(k2)", display(v2)))
                }
            } else if v is [Any] {
                // 数组不展开，只给数量（大数组会撑爆页面）
                out.append((k, display(v)))
            } else {
                out.append((k, display(v)))
            }
        }
        return out
    }
}
