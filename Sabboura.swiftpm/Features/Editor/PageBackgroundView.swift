import UIKit

/// معلومات صفحة واحدة داخل لوحة الرسم (قيمة ثابتة آمنة للرسم في الخلفية).
struct PageRenderInfo {
    let id: UUID
    let index: Int
    let size: CGSize
    let originY: CGFloat
    let background: PageBackgroundConfig
    let pdfPage: CGPDFPage?

    var frame: CGRect { CGRect(x: 0, y: originY, width: size.width, height: size.height) }
}

// MARK: - طبقة الخلفية المقسّمة (CATiledLayer)
// ترسم كل الصفحات المرصوصة عمودياً (وضع التمرير المتصل) أو صفحة واحدة، على شكل
// مربعات بدقة متزايدة مع التكبير، فتبقى الخطوط وصفحات PDF حادّة عند أي تكبير.

final class PageStackTiledLayer: CATiledLayer {
    private let stateLock = NSLock()
    private var pages: [PageRenderInfo] = []
    private var deskColor: UIColor = .lightGray

    override class func fadeDuration() -> CFTimeInterval { 0 }

    func update(pages newPages: [PageRenderInfo], deskColor newDesk: UIColor) {
        stateLock.lock()
        let oldPages = pages
        let oldDesk = deskColor
        pages = newPages
        deskColor = newDesk
        stateLock.unlock()

        // إعادة رسم الصفحات التي تغيّرت فقط، حتى لا تومض الصفحات الأخرى
        let sameLayout = oldPages.count == newPages.count
            && zip(oldPages, newPages).allSatisfy { $0.frame == $1.frame }
        guard sameLayout, oldDesk.isEqual(newDesk) else {
            setNeedsDisplay()
            return
        }
        for (old, new) in zip(oldPages, newPages) where !Self.looksSame(old, new) {
            setNeedsDisplay(new.frame.insetBy(dx: -4, dy: -4))
        }
    }

    private static func looksSame(_ a: PageRenderInfo, _ b: PageRenderInfo) -> Bool {
        a.background == b.background && a.pdfPage === b.pdfPage
    }

    override func draw(in ctx: CGContext) {
        stateLock.lock()
        let pages = self.pages
        let desk = self.deskColor
        stateLock.unlock()

        let clip = ctx.boundingBoxOfClipPath
        ctx.setFillColor(desk.cgColor)
        ctx.fill(clip)

        for page in pages where page.frame.insetBy(dx: -4, dy: -4).intersects(clip) {
            // حافة رفيعة بدل الظل المموّه (الظل المموّه يُحسب على الصفحة كاملة في كل مربع فيبطئ الرسم كثيراً)
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.28).cgColor)
            ctx.fill(page.frame.insetBy(dx: -1, dy: -1))
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.08).cgColor)
            ctx.fill(page.frame.offsetBy(dx: 0, dy: 3))

            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.originY)
            PageBackgroundRenderer.draw(page.background, pdfPage: page.pdfPage, in: ctx)
            ctx.restoreGState()
        }
    }
}

final class PageBackgroundView: UIView {
    override class var layerClass: AnyClass { PageStackTiledLayer.self }

    private var tiledLayer: PageStackTiledLayer {
        // swiftlint:disable:next force_cast
        layer as! PageStackTiledLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        isOpaque = true
        // مربعات كبيرة = عدد رسومات أقل (أسرع ظهوراً للصفحة كاملة)
        tiledLayer.tileSize = CGSize(width: 1024, height: 1024)
        tiledLayer.levelsOfDetail = 7
        tiledLayer.levelsOfDetailBias = 4
    }

    func configure(pages: [PageRenderInfo], deskColor: UIColor) {
        tiledLayer.update(pages: pages, deskColor: deskColor)
    }
}
