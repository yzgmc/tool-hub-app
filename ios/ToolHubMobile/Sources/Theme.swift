import SwiftUI

/// Anthropic 风格主题：暖米白底 + 赤陶橙强调，克制冷静，无渐变。
enum Theme {
    static let bg     = Color(hex: 0xF0EEE6)   // 页面背景（暖米白）
    static let card   = Color(hex: 0xFFFFFF)   // 卡片
    static let accent = Color(hex: 0xD97757)   // 主强调（赤陶橙）
    static let ink    = Color(hex: 0x191919)   // 正文
    static let sub    = Color(hex: 0x6B6A66)   // 次要文字
    static let ok     = Color(hex: 0x788C5D)   // 成功绿
    static let danger = Color(hex: 0xBF4D43)   // 危险红
    static let line   = Color(hex: 0xE3E1D9)   // 分隔线
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue:  Double(hex & 0xFF) / 255.0
        )
    }
}

/// 由插件 JSON 里的 "#22c55e" 颜色字符串生成 Color，解析失败回退主题色。
extension String {
    var themeColor: Color {
        let h = self.hasPrefix("#") ? String(self.dropFirst()) : self
        guard let v = UInt32(h, radix: 16), h.count == 6 else { return Theme.accent }
        return Color(hex: v)
    }
}

extension View {
    /// 统一卡片容器：白底圆角 + 柔和阴影。
    func card() -> some View {
        self
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.card)
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
            )
    }

    func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundColor(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
