import PencilKit
import UIKit

// MARK: - أدوات الكتابة

enum ToolKind: String, CaseIterable, Codable, Identifiable {
    case pen
    case pencil
    case marker
    case fountainPen
    case monoline
    case crayon
    case watercolor
    case eraser
    case lasso
    case text
    /// ترتيب الخط: ارسم دائرة حول الكتابة لتصبح أرتب
    case tidy

    var id: String { rawValue }

    static let inkKinds: [ToolKind] = [.pen, .pencil, .fountainPen, .monoline, .marker, .crayon, .watercolor]
    /// أقلام إضافية تظهر في قائمة «المزيد» بشريط الأدوات
    static let extraInkKinds: [ToolKind] = [.fountainPen, .monoline, .crayon, .watercolor]

    var isInk: Bool { inkType != nil }

    var title: String {
        switch self {
        case .pen: return "قلم حبر"
        case .pencil: return "قلم رصاص"
        case .marker: return "قلم تحديد"
        case .fountainPen: return "قلم ريشة"
        case .monoline: return "قلم خط ثابت"
        case .crayon: return "قلم شمع"
        case .watercolor: return "ألوان مائية"
        case .eraser: return "الممحاة"
        case .lasso: return "التحديد الحر"
        case .text: return "النص والصور"
        case .tidy: return "ترتيب الخط"
        }
    }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .fountainPen: return "signature"
        case .monoline: return "line.diagonal"
        case .crayon: return "scribble.variable"
        case .watercolor: return "paintbrush"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .tidy: return "wand.and.stars"
        }
    }

    var inkType: PKInkingTool.InkType? {
        switch self {
        case .pen: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .fountainPen: return .fountainPen
        case .monoline: return .monoline
        case .crayon: return .crayon
        case .watercolor: return .watercolor
        case .eraser, .lasso, .text, .tidy: return nil
        }
    }

    var widthRange: ClosedRange<Double> {
        switch self {
        case .pen: return 0.5...20
        case .pencil: return 1...16
        case .marker: return 4...36
        case .fountainPen: return 1...20
        case .monoline: return 0.5...16
        case .crayon: return 3...30
        case .watercolor: return 4...40
        case .eraser: return 4...80
        case .lasso, .text, .tidy: return 1...2
        }
    }

    var defaultWidth: Double {
        switch self {
        case .pen: return 2.5
        case .pencil: return 3
        case .marker: return 16
        case .fountainPen: return 4
        case .monoline: return 2
        case .crayon: return 10
        case .watercolor: return 16
        case .eraser: return 20
        case .lasso, .text, .tidy: return 1
        }
    }

    var defaultColorHex: String {
        switch self {
        case .marker: return "#FFD60A"
        case .watercolor: return "#3B82F6"
        case .crayon: return "#DC2626"
        default: return "#1C1C1E"
        }
    }
}

enum EraserMode: String, CaseIterable, Codable, Identifiable {
    case pixel
    case stroke
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixel: return "يدوية"
        case .stroke: return "كلمة كاملة"
        case .area: return "تحديد ومسح"
        }
    }

    var icon: String {
        switch self {
        case .pixel: return "eraser"
        case .stroke: return "eraser.line.dashed"
        case .area: return "lasso.and.sparkles"
        }
    }

    var explanation: String {
        switch self {
        case .pixel: return "تمسح الأجزاء التي تمرّ عليها فقط، مثل الممحاة الحقيقية. غيّر حجمها من الشريط."
        case .stroke: return "تحذف الخط بالكامل بمجرد لمسه — مثالية لحذف كلمة أو رسمة بسرعة."
        case .area: return "ارسم دائرة حول أي كتلة مكتوبة ليتم مسحها دفعة واحدة، أو انقر على خط لحذفه."
        }
    }
}

/// الكتابة بالإصبع وبأي قلم (مفعّلة افتراضياً). عند إيقافها يكتب قلم أبل فقط
/// ويصبح الإصبع للتمرير والتكبير (رفض كامل لراحة اليد).
enum FingerDrawingSetting {
    private static let key = "sabboura.fingerDrawing"

    static func load() -> Bool {
        if AppEnvironment.isUITest || AppEnvironment.isPhone { return true }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func save(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// حالة الأدوات (تُحفظ تلقائياً ليجدها المستخدم كما تركها).
struct ToolSettings: Codable, Equatable {
    var kind: ToolKind = .pen
    var previousKind: ToolKind = .pen
    var lastInkKind: ToolKind = .pen
    var colors: [String: String] = [:]
    var widths: [String: Double] = [:]
    var eraserMode: EraserMode = .pixel
    var eraserWidth: Double = ToolKind.eraser.defaultWidth
    /// صف الألوان الثمانية في شريط الأدوات (قابل للتخصيص بالضغط المطوّل)
    var swatches: [String] = ToolSettings.defaultSwatches

    static let defaultSwatches = ["#D6338A", "#0A7AFF", "#8E1B1B", "#E0301E", "#34C759", "#F5C400", "#9B30D9", "#1C1C1E"]

    func color(for kind: ToolKind) -> String {
        colors[kind.rawValue] ?? kind.defaultColorHex
    }

    func width(for kind: ToolKind) -> Double {
        let value = kind == .eraser ? eraserWidth : (widths[kind.rawValue] ?? kind.defaultWidth)
        return min(max(value, kind.widthRange.lowerBound), kind.widthRange.upperBound)
    }

    mutating func setWidth(_ width: Double, for kind: ToolKind) {
        let clamped = min(max(width, kind.widthRange.lowerBound), kind.widthRange.upperBound)
        if kind == .eraser {
            eraserWidth = clamped
        } else {
            widths[kind.rawValue] = clamped
        }
    }

    func makePKTool() -> PKTool {
        switch kind {
        case .eraser:
            switch eraserMode {
            case .stroke:
                return PKEraserTool(.vector)
            case .pixel, .area:
                return PKEraserTool(.bitmap, width: CGFloat(width(for: .eraser)))
            }
        case .lasso, .text, .tidy:
            return PKLassoTool()
        default:
            let inkType = kind.inkType ?? .pen
            return PKInkingTool(inkType,
                                color: UIColor(hex: color(for: kind)),
                                width: CGFloat(width(for: kind)))
        }
    }

    private static let storageKey = "sabboura.toolSettings"

    static func load() -> ToolSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(ToolSettings.self, from: data) else {
            return ToolSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// ما يُطبَّق على لوحة الرسم؛ يُقارن لتجنّب إعادة تعيين الأداة بلا داعٍ.
struct CanvasToolState: Equatable {
    var tools: ToolSettings
    var fingerDrawing: Bool
    var rulerActive: Bool
    var smartShapes: Bool
    var tidy: TidyOptions
}

enum EditorPopover: Hashable {
    case tool(ToolKind)
    case color
    case size
    case moreTools
    case background
    case viewSettings
}

/// ملف مختار من تطبيق الملفات قبل إدراجه.
struct ImportedFile: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let typeIdentifier: String

    var isPDF: Bool { name.lowercased().hasSuffix(".pdf") || typeIdentifier == "com.adobe.pdf" }
    var isImage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"].contains(ext)
    }
}
