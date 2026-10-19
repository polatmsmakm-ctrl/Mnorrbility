import SwiftUI

/// أين يلتصق شريط الأدوات (مثل نوتبلتي: أعلى / أسفل / يسار / يمين).
enum ToolbarDock: String {
    case top, bottom, leading, trailing

    var isVertical: Bool { self == .leading || self == .trailing }
}

/// طبقة تحرّك شريط الأدوات بحرية: يُسحب من المقبض، تظهر مناطق الإفلات، ويلتصق بأقرب حافة
/// ويمكن وضعه في أي مكان على طول تلك الحافة. المكان يُحفظ.
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
    @State private var grab: CGSize = .zero
    @State private var measured = CGSize(width: 480, height: 110)

    @Environment(\.appTheme) private var theme

    private let edge: CGFloat = 12
    private let topRowHeight: CGFloat = 66      // صف زر الرجوع وأزرار الإجراءات
    private let clusterWidth: CGFloat = 300     // عرض مجموعة الأزرار في الأعلى
    private let backWidth: CGFloat = 62
    private let navigatorReserve: CGFloat = 150 // مكان مؤشر الصفحات أسفل اليمين

    private var storedDock: ToolbarDock { ToolbarDock(rawValue: dockRaw) ?? .top }

    /// الحافة المعروضة الآن: أثناء السحب أقرب حافة للإصبع.
    private var shownDock: ToolbarDock {
        if let p = dragLocation { return nearestDock(to: p) }
        return storedDock
    }

    var body: some View {
        let dock = shownDock
        let vertical = dock.isVertical
        ZStack {
            if dragLocation != nil {
                dropZones(highlight: dock)
                    .transition(.opacity)
            }
            FloatingToolbar(controller: controller,
                            onInsertImage: onInsertImage,
                            onTakePhoto: onTakePhoto,
                            onImageFromFiles: onImageFromFiles,
                            onImportPDF: onImportPDF,
                            onImportFile: onImportFile,
                            vertical: vertical,
                            maxLength: maxLength(for: dock),
                            grip: AnyView(grip(vertical: vertical)))
                .fixedSize(horizontal: false, vertical: false)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { measured = geo.size }
                        .onChange(of: geo.size) { _, new in measured = new }
                })
                .position(center(for: dock))
                .animation(dragLocation == nil ? .spring(response: 0.32, dampingFraction: 0.82) : nil, value: dockRaw)
                .animation(dragLocation == nil ? .spring(response: 0.32, dampingFraction: 0.82) : nil, value: frac)
        }
        .frame(width: area.width, height: area.height)
        .animation(.easeInOut(duration: 0.15), value: dragLocation != nil)
    }

    // MARK: المقبض والسحب

    private func grip(vertical: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(theme.secondaryText.opacity(0.7))
            .frame(width: vertical ? 24 : 4, height: vertical ? 4 : 24)
            .frame(width: vertical ? 56 : 28, height: vertical ? 28 : 56)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .accessibilityLabel("تحريك شريط الأدوات")
            .accessibilityIdentifier("toolbarGrip")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("editorArea"))
            .onChanged { value in
                if dragLocation == nil {
                    let c = center(for: storedDock)
                    grab = CGSize(width: c.x - value.startLocation.x, height: c.y - value.startLocation.y)
                }
                dragLocation = CGPoint(x: value.location.x + grab.width, y: value.location.y + grab.height)
            }
            .onEnded { value in
                let p = CGPoint(x: value.location.x + grab.width, y: value.location.y + grab.height)
                let dock = nearestDock(to: p)
                dockRaw = dock.rawValue
                frac = dock.isVertical ? Double(p.y / max(area.height, 1)) : Double(p.x / max(area.width, 1))
                frac = min(max(frac, 0), 1)
                dragLocation = nil
            }
    }

    private func nearestDock(to p: CGPoint) -> ToolbarDock {
        let candidates: [(ToolbarDock, CGFloat)] = [
            (.top, p.y), (.bottom, area.height - p.y),
            (.leading, p.x), (.trailing, area.width - p.x)
        ]
        return candidates.min { $0.1 < $1.1 }?.0 ?? .top
    }

    // MARK: المكان

    private func maxLength(for dock: ToolbarDock) -> CGFloat {
        switch dock {
        case .top: return max(260, min(560, area.width - 2 * edge - backWidth - clusterWidth))
        case .bottom: return max(260, min(640, area.width - 2 * edge))
        case .leading, .trailing: return max(220, min(540, area.height - topRowHeight - edge - (dock == .trailing ? navigatorReserve : edge)))
        }
    }

    /// مركز الشريط حين يكون ملتصقاً بالحافة المحددة.
    private func center(for dock: ToolbarDock) -> CGPoint {
        if let p = dragLocation { return p }
        let w = measured.width, h = measured.height
        switch dock {
        case .top, .bottom:
            let lo = edge + (dock == .top ? backWidth : 0) + w / 2
            let hi = area.width - edge - (dock == .top ? clusterWidth : 0) - w / 2
            let x = hi >= lo ? min(max(CGFloat(frac) * area.width, lo), hi) : area.width / 2
            let y = dock == .top ? 8 + h / 2 : area.height - edge - h / 2
            return CGPoint(x: x, y: y)
        case .leading, .trailing:
            let lo = topRowHeight + h / 2
            let hi = area.height - (dock == .trailing ? navigatorReserve : edge) - h / 2
            let y = hi >= lo ? min(max(CGFloat(frac) * area.height, lo), hi) : area.height / 2
            let x = dock == .leading ? edge + w / 2 : area.width - edge - w / 2
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: مناطق الإفلات (كالكبسولات الرمادية في نوتبلتي)

    private func dropZones(highlight: ToolbarDock) -> some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().allowsHitTesting(false)
            zone(.top, highlight: highlight)
                .frame(width: min(380, area.width * 0.5), height: 38)
                .position(x: area.width / 2, y: 30)
            zone(.bottom, highlight: highlight)
                .frame(width: min(380, area.width * 0.5), height: 38)
                .position(x: area.width / 2, y: area.height - 30)
            zone(.leading, highlight: highlight)
                .frame(width: 38, height: min(380, area.height * 0.5))
                .position(x: 26, y: area.height / 2)
            zone(.trailing, highlight: highlight)
                .frame(width: 38, height: min(380, area.height * 0.5))
                .position(x: area.width - 26, y: area.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func zone(_ dock: ToolbarDock, highlight: ToolbarDock) -> some View {
        Capsule()
            .fill(highlight == dock ? theme.accent.opacity(0.35) : Color.white.opacity(theme.isDark ? 0.10 : 0.55))
            .overlay(Capsule().stroke(highlight == dock ? theme.accent : theme.border, lineWidth: 1.5))
    }
}
