import UIKit

/// عنصر موضوع على الصفحة: نص مكتوب بلوحة المفاتيح أو صورة.
/// الإحداثيات بنقاط الصفحة (عرض الصفحة القياسي 820).
struct PageItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    var id: UUID = UUID()
    var kind: Kind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var text: String = ""
    var fontSize: Double = 22
    var colorHex: String = "#1C1C1E"
    var isBold: Bool = false
    /// الصورة محفوظة كمرفق في المذكرة (حتى تظهر في المعرض أيضاً).
    var attachmentID: UUID? = nil

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Double(newValue.origin.x)
            y = Double(newValue.origin.y)
            width = Double(newValue.size.width)
            height = Double(newValue.size.height)
        }
    }

    var font: UIFont {
        let size = CGFloat(max(8, min(fontSize, 160)))
        return isBold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    }

    /// يحسب ارتفاع النص حسب العرض الحالي.
    mutating func fitTextHeight() {
        guard kind == .text else { return }
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let bounds = attributed.boundingRect(with: CGSize(width: max(40, width), height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             context: nil)
        height = Double(ceil(bounds.height) + 8)
    }

    static func newText(at point: CGPoint, pageWidth: CGFloat, colorHex: String) -> PageItem {
        let width = min(420, max(160, pageWidth - point.x - 24))
        var item = PageItem(kind: .text,
                            x: Double(point.x),
                            y: Double(point.y),
                            width: Double(width),
                            height: 40,
                            text: "",
                            fontSize: 22,
                            colorHex: colorHex)
        item.fitTextHeight()
        return item
    }
}

/// عنصر مع موضعه في لوحة الرسم (للعرض في وضع التمرير المتصل).
struct PlacedItem: Identifiable, Equatable {
    var item: PageItem
    var pageID: UUID
    var pageOriginY: CGFloat

    var id: UUID { item.id }

    var canvasFrame: CGRect {
        item.frame.offsetBy(dx: 0, dy: pageOriginY)
    }
}
