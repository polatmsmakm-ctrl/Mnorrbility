import CoreText
import SwiftUI
import UIKit

/// خط الواجهة: Inter للحروف اللاتينية والأرقام، والعربي يُعرض تلقائياً بخط النظام.
///
/// ملفات الخط في Resources/Fonts (رخصة SIL Open Font License — انظر Inter-LICENSE.txt).
/// إن لم تُحمَّل الملفات لأي سبب يرجع كل شيء لخط النظام بدون أي خلل.
enum AppFont {
    private static var registered = false
    private(set) static var isAvailable = false
    private static var cache: [String: UIFont] = [:]

    /// يسجّل ملفات Inter المرفقة بالتطبيق (يُستدعى مرة واحدة عند التشغيل).
    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        var urls: [URL] = []
        for folder in [nil, "Fonts", "Resources/Fonts"] {
            urls += Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: folder) ?? []
        }
        for url in urls where url.lastPathComponent.hasPrefix("Inter-") {
            // إن كان مسجلاً مسبقاً يرجع خطأ لا يهمنا
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        isAvailable = UIFont(name: "Inter-Regular", size: 12) != nil
        applyBarAppearance()
    }

    // MARK: إنشاء الخطوط

    static func uiFont(size: CGFloat, weight: UIFont.Weight = .regular, monospacedDigits: Bool = false) -> UIFont {
        let key = "\(size)|\(weight.rawValue)|\(monospacedDigits)"
        if let cached = cache[key] { return cached }

        let system = monospacedDigits
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        guard isAvailable, let inter = UIFont(name: postScriptName(for: weight), size: size) else {
            cache[key] = system
            return system
        }
        // الحروف غير الموجودة في Inter (العربية) تُؤخذ من خط النظام بنفس الوزن
        let arabicFallback = (CTFontCopyDefaultCascadeListForLanguages(system as CTFont, ["ar"] as CFArray)
            as? [UIFontDescriptor]) ?? []
        var attributes: [UIFontDescriptor.AttributeName: Any] = [
            .cascadeList: [system.fontDescriptor] + arabicFallback
        ]
        if monospacedDigits {
            attributes[.featureSettings] = [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector
            ]]
        }
        let font = UIFont(descriptor: inter.fontDescriptor.addingAttributes(attributes), size: size)
        cache[key] = font
        return font
    }

    /// خط بحجم أحد أنماط النظام (يتكبّر مع إعداد حجم النص في الجهاز).
    static func uiFont(_ style: UIFont.TextStyle, weight: UIFont.Weight? = nil,
                       monospacedDigits: Bool = false) -> UIFont {
        let size = baseSize(for: style)
        let font = uiFont(size: size, weight: weight ?? defaultWeight(for: style), monospacedDigits: monospacedDigits)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    private static func postScriptName(for weight: UIFont.Weight) -> String {
        switch weight.rawValue {
        case ..<0.1: return "Inter-Regular"
        case ..<0.27: return "Inter-Medium"
        case ..<0.37: return "Inter-SemiBold"
        case ..<0.5: return "Inter-Bold"
        case ..<0.6: return "Inter-ExtraBold"
        default: return "Inter-Black"
        }
    }

    /// أحجام أنماط النص الافتراضية في iOS (حجم النص «كبير»).
    private static func baseSize(for style: UIFont.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title1: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption1: return 12
        case .caption2: return 11
        default: return 17
        }
    }

    private static func defaultWeight(for style: UIFont.TextStyle) -> UIFont.Weight {
        style == .headline ? .semibold : .regular
    }

    // MARK: أشرطة التنقل

    private static func applyBarAppearance() {
        guard isAvailable else { return }
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = [.font: uiFont(size: 17, weight: .semibold)]
        bar.largeTitleTextAttributes = [.font: uiFont(size: 34, weight: .bold)]
    }
}

extension Font {
    /// خط Inter بحجم أحد أنماط النظام، مثل `.font(.inter(.headline))`.
    static func inter(_ style: Font.TextStyle, weight: Font.Weight? = nil, monospacedDigits: Bool = false) -> Font {
        let font = AppFont.uiFont(style.uiTextStyle, weight: weight?.uiWeight, monospacedDigits: monospacedDigits)
        return Font(font as CTFont)
    }

    /// خط Inter بحجم ثابت، مثل `.font(.inter(size: 17, weight: .semibold))`.
    static func inter(size: CGFloat, weight: Font.Weight = .regular, monospacedDigits: Bool = false) -> Font {
        Font(AppFont.uiFont(size: size, weight: weight.uiWeight, monospacedDigits: monospacedDigits) as CTFont)
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

private extension Font.Weight {
    var uiWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}
