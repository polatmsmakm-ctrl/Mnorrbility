import SwiftUI
import UIKit

// MARK: - تحويل الألوان من وإلى صيغة HEX

extension UIColor {
    /// يقبل "#RRGGBB" أو "RRGGBB" أو "#RRGGBBAA".
    convenience init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        let number = UInt64(value, radix: 16) ?? 0
        let r, g, b, a: CGFloat
        switch value.count {
        case 8:
            r = CGFloat((number >> 24) & 0xFF) / 255
            g = CGFloat((number >> 16) & 0xFF) / 255
            b = CGFloat((number >> 8) & 0xFF) / 255
            a = CGFloat(number & 0xFF) / 255
        case 6:
            r = CGFloat((number >> 16) & 0xFF) / 255
            g = CGFloat((number >> 8) & 0xFF) / 255
            b = CGFloat(number & 0xFF) / 255
            a = 1
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            getWhite(&white, alpha: &a)
            r = white; g = white; b = white
        }
        func clamp(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// هل اللون داكن؟ (لاختيار لون نص/حدود متباين)
    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }
}

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

enum HexColor {
    /// يعيد صيغة موحّدة "#RRGGBB" أو nil إن كان النص غير صالح.
    static func normalized(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + value
    }
}

/// آخر الألوان المخصّصة التي استخدمها المستخدم.
enum RecentColors {
    private static let key = "sabboura.recentColors"

    static var all: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ hex: String) {
        guard let normalized = HexColor.normalized(hex) else { return }
        var list = all.filter { $0 != normalized }
        list.insert(normalized, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: key)
    }
}

enum ColorPresets {
    static let ink: [String] = [
        "#1C1C1E", "#4B5563", "#1D4ED8", "#0EA5E9", "#0F766E", "#16A34A",
        "#DC2626", "#F97316", "#FFD60A", "#9333EA", "#DB2777", "#8B5E3C", "#FFFFFF"
    ]

    static let subjects: [String] = [
        "#2563EB", "#7C3AED", "#059669", "#DC2626", "#F59E0B", "#0EA5E9",
        "#DB2777", "#B45309", "#4B5563", "#16A34A", "#9333EA", "#0F766E"
    ]
}
