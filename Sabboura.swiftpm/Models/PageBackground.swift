import UIKit

// MARK: - أنواع خلفيات الصفحة

enum BackgroundKind: String, CaseIterable, Codable, Identifiable {
    case blank
    case lined
    case grid
    case dots
    case cornell
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "فارغة"
        case .lined: return "مسطّرة"
        case .grid: return "مربعات"
        case .dots: return "نقاط"
        case .cornell: return "كورنيل"
        case .music: return "نوتة موسيقية"
        }
    }
}

/// إعدادات خلفية قابلة للحفظ كقالب افتراضي للصفحات الجديدة.
struct PageTemplate: Codable, Equatable {
    var kind: BackgroundKind
    var backgroundHex: String
    var lineHex: String
    var spacing: Double

    static let factory = PageTemplate(kind: .lined, backgroundHex: "#FFFFFF", lineHex: "#C7D3E3", spacing: 34)

    private static let storageKey = "sabboura.defaultPageTemplate"

    static var savedDefault: PageTemplate {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let template = try? JSONDecoder().decode(PageTemplate.self, from: data) else {
            return factory
        }
        return template
    }

    func saveAsDefault() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// كل ما يحتاجه الرسّام لرسم خلفية صفحة (يُمرَّر بين الخيوط بأمان).
struct PageBackgroundConfig: Equatable {
    var kind: BackgroundKind
    var backgroundHex: String
    var lineHex: String
    var spacing: CGFloat
    var pageSize: CGSize
    /// عرض الصفحة داكنة («المحتوى يطابق الثيم»)
    var darkContent: Bool = false
    var darkPaperHex: String = "#000000"
    var darkLineHex: String = "#1D4F58"
    var darkMarginHex: String = "#9C1C1C"
    /// صفحة PDF: تُعكس ألوانها في الوضع الداكن
    var isPDF: Bool = false

    /// نسخة من الإعداد مهيّأة للعرض حسب الثيم الحالي.
    func themed(dark: Bool, theme: AppTheme) -> PageBackgroundConfig {
        var copy = self
        copy.darkContent = dark
        copy.darkPaperHex = theme.darkPaperHex
        copy.darkLineHex = theme.darkPaperLineHex
        copy.darkMarginHex = theme.darkPaperMarginHex
        return copy
    }

    /// الألوان الفعلية بعد تطبيق الوضع الداكن (الخلفيات الداكنة أصلاً تبقى كما هي).
    var effectiveColors: (paper: String, line: String, margin: String?) {
        let paperIsDark = UIColor(hex: backgroundHex).isDark
        if darkContent && !paperIsDark && !isPDF {
            return (darkPaperHex, darkLineHex, darkMarginHex)
        }
        return (backgroundHex, lineHex, paperIsDark ? nil : "#E57373")
    }
}

/// سبورات جاهزة: لون خلفية + لون خطوط مناسب.
struct BoardPreset: Identifiable, Hashable {
    let name: String
    let backgroundHex: String
    let lineHex: String

    var id: String { name }

    static let all: [BoardPreset] = [
        BoardPreset(name: "ورق أبيض", backgroundHex: "#FFFFFF", lineHex: "#C7D3E3"),
        BoardPreset(name: "ورق كريمي", backgroundHex: "#FBF6E9", lineHex: "#D8C9AA"),
        BoardPreset(name: "أصفر قانوني", backgroundHex: "#FFF6BF", lineHex: "#8DB8E0"),
        BoardPreset(name: "وردي هادئ", backgroundHex: "#FDEEF2", lineHex: "#E9B7C6"),
        BoardPreset(name: "سبورة خضراء", backgroundHex: "#2E4A3D", lineHex: "#5F7F6F"),
        BoardPreset(name: "سبورة سوداء", backgroundHex: "#1F2124", lineHex: "#474B52"),
        BoardPreset(name: "مخطط أزرق", backgroundHex: "#1C3A5E", lineHex: "#46709E"),
        BoardPreset(name: "رمادي داكن", backgroundHex: "#2B2D33", lineHex: "#50545E")
    ]
}
