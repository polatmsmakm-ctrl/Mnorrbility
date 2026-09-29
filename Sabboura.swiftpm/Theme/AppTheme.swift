import SwiftUI
import UIKit

// MARK: - الثيمات

/// ثيمات التطبيق: ثلاثة داكنة وأربعة فاتحة.
enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case coreDark
    case darkBlue
    case jetBlack
    case classic
    case sage
    case peach
    case rose

    var id: String { rawValue }

    static let darkThemes: [AppTheme] = [.coreDark, .darkBlue, .jetBlack]
    static let lightThemes: [AppTheme] = [.classic, .sage, .peach, .rose]

    var title: String {
        switch self {
        case .coreDark: return "داكن أساسي"
        case .darkBlue: return "أزرق داكن"
        case .jetBlack: return "أسود فاحم"
        case .classic: return "كلاسيكي"
        case .sage: return "أخضر هادئ"
        case .peach: return "خوخي"
        case .rose: return "وردي"
        }
    }

    var isDark: Bool { AppTheme.darkThemes.contains(self) }

    /// خلفية القائمة الجانبية
    var sidebarHex: String {
        switch self {
        case .coreDark: return "#1D2026"
        case .darkBlue: return "#1B2130"
        case .jetBlack: return "#141414"
        case .classic: return "#F2F3F7"
        case .sage: return "#EEF3E8"
        case .peach: return "#F8EEE8"
        case .rose: return "#F8EBEA"
        }
    }

    /// خلفية المحتوى الرئيسية
    var backgroundHex: String {
        switch self {
        case .coreDark: return "#111317"
        case .darkBlue: return "#0E121B"
        case .jetBlack: return "#000000"
        case .classic: return "#FFFFFF"
        case .sage: return "#FBFCF8"
        case .peach: return "#FFFBF8"
        case .rose: return "#FFFAFA"
        }
    }

    /// بطاقات ولوحات
    var cardHex: String {
        switch self {
        case .coreDark: return "#1A1D22"
        case .darkBlue: return "#161B26"
        case .jetBlack: return "#0F0F10"
        case .classic: return "#FFFFFF"
        case .sage: return "#FFFFFF"
        case .peach: return "#FFFFFF"
        case .rose: return "#FFFFFF"
        }
    }

    var borderHex: String {
        switch self {
        case .coreDark: return "#2C3038"
        case .darkBlue: return "#2A3244"
        case .jetBlack: return "#2A2A2C"
        case .classic: return "#E3E5EA"
        case .sage: return "#DDE6D3"
        case .peach: return "#EFDDD2"
        case .rose: return "#F0D8D6"
        }
    }

    /// العنصر المختار في القائمة الجانبية
    var selectionHex: String {
        switch self {
        case .coreDark: return "#2E333D"
        case .darkBlue: return "#2F3A52"
        case .jetBlack: return "#262628"
        case .classic: return "#E1E6F2"
        case .sage: return "#DCE8CF"
        case .peach: return "#F4DCCD"
        case .rose: return "#F3D6D3"
        }
    }

    var accentHex: String {
        switch self {
        case .coreDark: return "#5B9BF0"
        case .darkBlue: return "#5AA2F2"
        case .jetBlack: return "#5AA2F2"
        case .classic: return "#2F6FE4"
        case .sage: return "#4F7A28"
        case .peach: return "#D0662E"
        case .rose: return "#C9463D"
        }
    }

    var primaryTextHex: String { isDark ? "#F2F4F8" : "#15181E" }
    var secondaryTextHex: String { isDark ? "#98A1B3" : "#6A7080" }

    /// شريط الأدوات العائم في المحرر
    var toolbarHex: String {
        switch self {
        case .coreDark: return "#1F2228"
        case .darkBlue: return "#161B26"
        case .jetBlack: return "#121213"
        default: return "#FFFFFF"
        }
    }

    /// المساحة حول الصفحات في المحرر
    var deskHex: String {
        switch self {
        case .coreDark: return "#0A0B0D"
        case .darkBlue: return "#070A10"
        case .jetBlack: return "#000000"
        case .classic: return "#DADDE3"
        case .sage: return "#D8DECF"
        case .peach: return "#E6DAD2"
        case .rose: return "#E6D6D4"
        }
    }

    /// ورق الصفحة عند تفعيل «المحتوى يطابق الثيم» في الثيمات الداكنة
    var darkPaperHex: String {
        switch self {
        case .coreDark: return "#15171B"
        case .darkBlue: return "#0B0F17"
        default: return "#000000"
        }
    }

    var darkPaperLineHex: String { "#1D4F58" }
    var darkPaperMarginHex: String { "#9C1C1C" }

    // ألوان SwiftUI
    var sidebar: Color { Color(hex: sidebarHex) }
    var background: Color { Color(hex: backgroundHex) }
    var card: Color { Color(hex: cardHex) }
    var border: Color { Color(hex: borderHex) }
    var selection: Color { Color(hex: selectionHex) }
    var accent: Color { Color(hex: accentHex) }
    var primaryText: Color { Color(hex: primaryTextHex) }
    var secondaryText: Color { Color(hex: secondaryTextHex) }
    var toolbar: Color { Color(hex: toolbarHex) }
    var desk: Color { Color(hex: deskHex) }
}

// MARK: - إعدادات المظهر

/// إعدادات المظهر المحفوظة (تُحقن في كل الشاشات).
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()

    private let defaults = UserDefaults.standard

    @Published var matchSystem: Bool { didSet { defaults.set(matchSystem, forKey: Keys.matchSystem) } }
    @Published var preferDark: Bool { didSet { defaults.set(preferDark, forKey: Keys.preferDark) } }
    @Published var darkTheme: AppTheme { didSet { defaults.set(darkTheme.rawValue, forKey: Keys.darkTheme) } }
    @Published var lightTheme: AppTheme { didSet { defaults.set(lightTheme.rawValue, forKey: Keys.lightTheme) } }
    @Published var contentMatchesTheme: Bool { didSet { defaults.set(contentMatchesTheme, forKey: Keys.content) } }
    @Published var colorfulFolders: Bool { didSet { defaults.set(colorfulFolders, forKey: Keys.colorful) } }
    @Published var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: Keys.keepAwake)
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
    }

    private enum Keys {
        static let matchSystem = "sabboura.theme.matchSystem"
        static let preferDark = "sabboura.theme.preferDark"
        static let darkTheme = "sabboura.theme.dark"
        static let lightTheme = "sabboura.theme.light"
        static let content = "sabboura.theme.contentMatches"
        static let colorful = "sabboura.theme.colorfulFolders"
        static let keepAwake = "sabboura.theme.keepAwake"
    }

    init() {
        let d = UserDefaults.standard
        matchSystem = d.object(forKey: Keys.matchSystem) as? Bool ?? true
        preferDark = d.object(forKey: Keys.preferDark) as? Bool ?? true
        darkTheme = AppTheme(rawValue: d.string(forKey: Keys.darkTheme) ?? "") ?? .darkBlue
        lightTheme = AppTheme(rawValue: d.string(forKey: Keys.lightTheme) ?? "") ?? .classic
        contentMatchesTheme = d.object(forKey: Keys.content) as? Bool ?? true
        colorfulFolders = d.object(forKey: Keys.colorful) as? Bool ?? false
        keepAwake = d.object(forKey: Keys.keepAwake) as? Bool ?? false

        if AppEnvironment.forceDark {
            matchSystem = false
            preferDark = true
            darkTheme = AppEnvironment.forcedTheme ?? darkTheme
        }
    }

    /// نظام الألوان المطلوب من النظام (nil = يتبع الجهاز).
    var preferredScheme: ColorScheme? {
        matchSystem ? nil : (preferDark ? .dark : .light)
    }

    func theme(for scheme: ColorScheme) -> AppTheme {
        if matchSystem {
            return scheme == .dark ? darkTheme : lightTheme
        }
        return preferDark ? darkTheme : lightTheme
    }

    func select(_ theme: AppTheme) {
        if theme.isDark {
            darkTheme = theme
            if !matchSystem { preferDark = true }
        } else {
            lightTheme = theme
            if !matchSystem { preferDark = false }
        }
    }

    func applyKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }
}

// MARK: - تمرير الثيم في البيئة

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .darkBlue
}

private struct ContentDarkKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }

    /// الصفحات تُعرض داكنة (الثيم داكن + «المحتوى يطابق الثيم»)
    var contentDark: Bool {
        get { self[ContentDarkKey.self] }
        set { self[ContentDarkKey.self] = newValue }
    }
}

/// يحسب الثيم الحالي من الإعدادات ومظهر الجهاز ويمرره لكل ما بداخله.
struct ThemedContainer<Content: View>: View {
    @EnvironmentObject private var settings: ThemeSettings
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let theme = settings.theme(for: scheme)
        content
            .environment(\.appTheme, theme)
            .environment(\.contentDark, theme.isDark && settings.contentMatchesTheme)
            .tint(theme.accent)
    }
}
