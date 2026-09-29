import UIKit

/// معلومات التشغيل: نوع الجهاز ووضع الاختبار الآلي.
enum AppEnvironment {
    static let arguments = ProcessInfo.processInfo.arguments

    /// يعمل التطبيق تحت الاختبار الآلي (XCUITest).
    static let isUITest = arguments.contains("-uitest")
    /// مسح بيانات الاختبار قبل التشغيل.
    static let resetData = arguments.contains("-uitest-reset")
    /// استيراد ملف PDF تجريبي تلقائياً عند فتح مذكرة (للاختبار).
    static let importSamplePDF = arguments.contains("-uitest-import-pdf")
    /// إجبار الثيم الداكن (للاختبار).
    static let forceDark = arguments.contains("-uitest-dark")
    /// ثيم محدد للاختبار: -uitest-theme jetBlack
    static var forcedTheme: AppTheme? {
        guard let index = arguments.firstIndex(of: "-uitest-theme"), index + 1 < arguments.count else { return nil }
        return AppTheme(rawValue: arguments[index + 1])
    }

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// يُستدعى مرة واحدة عند بدء التطبيق قبل قراءة أي إعدادات.
    static func prepare() {
        guard isUITest, resetData else { return }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sabboura.") {
            defaults.removeObject(forKey: key)
        }
    }
}
