import SwiftUI

/// أين يلتصق شريط الأدوات (مثل نوتبلتي: أعلى / أسفل / يسار / يمين).
enum ToolbarDock: String {
    case top, bottom, leading, trailing

    var isVertical: Bool { self == .leading || self == .trailing }
}

/// يضع الشريط بدقة: على الحافة المختارة وفي أي نقطة على طولها، أو تحت الإصبع أثناء السحب.
/// الحجم يُقاس من الشريط نفسه، فلا يخرج من الشاشة مهما تغيّر اتجاهه.
private struct DockLayout: Layout {
    var dock: ToolbarDock
    var fraction: CGFloat
    var dragPoint: CGPoint?
    var maxLength: CGFloat
    var topReserve: CGFloat      // أعلى الشاشة: صف الرجوع والأزرار
    var bottomReserve: CGFloat   // أسفل اليمين: مؤشر الصفحات

    private let edge: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 600)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let sub = subviews.first else { return }
        let vertical = dock.isVertical
        let size = sub.sizeThatFits(ProposedViewSize(width: vertical ? nil : maxLength,
                                                     height: vertical ? maxLength : nil))
        let w = size.width, h = size.height
        let W = bounds.width, H = bounds.height

        var cx: CGFloat, cy: CGFloat
        if let p = dragPoint {
            cx = p.x; cy = p.y
        } else {
            switch dock {
            case .top, .bottom:
                let lo = edge + (dock == .top ? 62 : 0) + w / 2
                let hi = W - edge - (dock == .top ? 300 : 0) - w / 2
                cx = hi >= lo ? min(max(fraction * W, lo), hi) : W / 2
                cy = dock == .top ? 8 + h / 2 : H - edge - h / 2
            case .leading, .trailing:
                let lo = topReserve + h / 2
                let hi = H - (dock == .trailing ? bottomReserve : edge) - h / 2
                cy = hi >= lo ? min(max(fraction * H, lo), hi) : H / 2
                cx = dock == .leading ? edge + w / 2 : W - edge - w / 2
            }
        }
        // لا يخرج من الشاشة أبداً
        cx = min(max(cx, w / 2 + 4), max(W - w / 2 - 4, w / 2 + 4))
        cy = min(max(cy, h / 2 + 4), max(H - h / 2 - 4, h / 2 + 4))
        sub.place(at: CGPoint(x: bounds.minX + cx, y: bounds.minY + cy), anchor: .center,
                  proposal: ProposedViewSize(size))
    }
}

/// طبقة تحرّك شريط الأدوات بحرية. تُسحب من المقبض، فيتحول الشريط إلى كبسولة أدوات صغيرة
/// وتظهر مناطق الإفلات الأربع والصفحة مضبّبة، وعند الإفلات يلتصق بأقرب حافة في المكان الذي تركته.
struct DockableToolbarLayer: View {
    @ObservedObject var controller: EditorController
    let area: CGSize
    var onInsertImage: () -> Void
    var onTakePhoto: () -> Void
    var onImageFromFiles: () -> Void
    var onImportPDF: () -> Void
    var onImportFile: () -> Void

    @AppStorage("sabboura.toolbar.dock") private var dockRaw = ToolbarDock.top.rawValue
    @AppStorage("sabboura.toolbar.frac") private var frac = 0.5

    @State private var dragLocation: CGPoint?

    @Environment(\.appTheme) private var theme

    private var storedDock: ToolbarDock { ToolbarDock(rawValue: dockRaw) ?? .top }

    private var shownDock: ToolbarDock {
        if let p = dragLocation { return nearestDock(to: p) }
        return storedDock
    }

    var body: some View {
        let dock = shownDock
        let vertical = dock.isVertical
        let dragging = dragLocation != nil
        ZStack {
            if dragging {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.25))
                    .ignoresSafeArea()
                    .transition(.opacity)
                dropZones(highlight: dock)
            }
            DockLayout(dock: dock, fraction: CGFloat(frac), dragPoint: dragLocation,
                       maxLength: maxLength(for: dock, compact: dragging),
                       topReserve: 70, bottomReserve: 150) {
                FloatingToolbar(controller: controller,
                                onInsertImage: onInsertImage,
                                onTakePhoto: onTakePhoto,
                                onImageFromFiles: onImageFromFiles,
                                onImportPDF: onImportPDF,
                                onImportFile: onImportFile,
                                vertical: vertical,
                                compact: dragging,
                                maxLength: maxLength(for: dock, compact: dragging),
                                grip: AnyView(grip(vertical: vertical)))
                    .overlay(alignment: storedDock.isVertical ? .top : .leading) { gripHitArea }
            }
        }
        .frame(width: area.width, height: area.height)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: dockRaw)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: frac)
        .animation(.easeInOut(duration: 0.18), value: dragging)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dock)
    }

    // MARK: المقبض والسحب

    /// شكل المقبض فقط (يحجز مكانه داخل الشريط)
    private func grip(vertical: Bool) -> some View {
        Capsule()
            .fill(theme.secondaryText.opacity(0.55))
            .frame(width: vertical ? 26 : 4, height: vertical ? 4 : 22)
            .frame(width: vertical ? 56 : 26, height: vertical ? 26 : 56)
    }

    /// منطقة اللمس للسحب: طبقة ثابتة فوق الشريط حتى لا ينقطع السحب عند تغيّر شكله.
    private var gripHitArea: some View {
        let v = storedDock.isVertical
        return Color.clear
            .frame(width: v ? 56 : 30, height: v ? 30 : 56)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .accessibilityLabel("تحريك شريط الأدوات")
            .accessibilityIdentifier("toolbarGrip")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("editorArea"))
            .onChanged { value in
                dragLocation = value.location
            }
            .onEnded { value in
                let p = value.location
                let dock = nearestDock(to: p)
                var f = dock.isVertical ? p.y / max(area.height, 1) : p.x / max(area.width, 1)
                f = min(max(f, 0), 1)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                    dockRaw = dock.rawValue
                    frac = Double(f)
                    dragLocation = nil
                }
            }
    }

    private func nearestDock(to p: CGPoint) -> ToolbarDock {
        let candidates: [(ToolbarDock, CGFloat)] = [
            (.top, p.y), (.bottom, area.height - p.y),
            (.leading, p.x), (.trailing, area.width - p.x)
        ]
        return candidates.min { $0.1 < $1.1 }?.0 ?? .top
    }

    private func maxLength(for dock: ToolbarDock, compact: Bool) -> CGFloat {
        switch dock {
        case .top: return max(260, min(compact ? 460 : 440, area.width - 24 - 62 - 300))
        case .bottom: return max(260, min(compact ? 460 : 520, area.width - 24))
        case .leading, .trailing: return max(220, min(compact ? 460 : 520, area.height - 70 - 12 - (dock == .trailing ? 150 : 12)))
        }
    }

    // MARK: مناطق الإفلات (كبسولات خافتة كما في نوتبلتي)

    private func dropZones(highlight: ToolbarDock) -> some View {
        ZStack {
            zone(.top, highlight: highlight)
                .frame(width: min(380, area.width * 0.4), height: 38)
                .position(x: area.width / 2, y: 30)
            zone(.bottom, highlight: highlight)
                .frame(width: min(380, area.width * 0.4), height: 38)
                .position(x: area.width / 2, y: area.height - 30)
            zone(.leading, highlight: highlight)
                .frame(width: 38, height: min(380, area.height * 0.45))
                .position(x: 26, y: area.height / 2)
            zone(.trailing, highlight: highlight)
                .frame(width: 38, height: min(380, area.height * 0.45))
                .position(x: area.width - 26, y: area.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func zone(_ dock: ToolbarDock, highlight: ToolbarDock) -> some View {
        Capsule()
            .fill(Color.white.opacity(highlight == dock ? 0.20 : 0.08))
            .overlay(Capsule().stroke(Color.white.opacity(highlight == dock ? 0.45 : 0.16), lineWidth: 1))
    }
}
