import PhotosUI
import SwiftUI

// MARK: - الشريط العائم في المحرر (الأدوات + صف الألوان)

struct FloatingToolbar: View {
    @ObservedObject var controller: EditorController
    var onInsertImage: () -> Void
    var onImportPDF: () -> Void
    var onImportFile: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            toolsRow
            Rectangle().fill(theme.border).frame(height: 1)
            colorsRow
        }
        .background(theme.toolbar, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.12), radius: 12, y: 4)
        .environment(\.layoutDirection, .leftToRight)
    }

    // صف الأدوات
    private var toolsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ToolIconButton(kind: .pen, symbol: "pencil.tip", controller: controller)
                ToolIconButton(kind: .pencil, symbol: "pencil", controller: controller)
                ToolIconButton(kind: .marker, symbol: "highlighter", controller: controller)
                ToolIconButton(kind: .eraser, symbol: "eraser", controller: controller)
                ToolIconButton(kind: .text, symbol: "textformat", controller: controller)
                ToolIconButton(kind: .lasso, symbol: "lasso", controller: controller)
                ToolIconButton(kind: .tidy, symbol: "wand.and.stars", controller: controller)

                insertMenu
                recordButton

                divider

                if AppEnvironment.isPad {
                    handButton
                }
                moreToolsButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.border).frame(width: 1, height: 26).padding(.horizontal, 4)
    }

    private var insertMenu: some View {
        Menu {
            Button {
                onInsertImage()
            } label: {
                Label("صورة من الصور", systemImage: "photo")
            }
            Button {
                onImportPDF()
            } label: {
                Label("ملف PDF للكتابة عليه", systemImage: "doc.richtext")
            }
            Button {
                onImportFile()
            } label: {
                Label("ملف أو مستند", systemImage: "paperclip")
            }
            Divider()
            Button {
                controller.toolTapped(.text)
            } label: {
                Label("مربع نص", systemImage: "textformat")
            }
            Button {
                controller.addPage()
            } label: {
                Label("صفحة جديدة", systemImage: "doc.badge.plus")
            }
        } label: {
            ChromeIcon(symbol: "plus.circle", active: false)
        }
        .accessibilityLabel("إدراج")
        .accessibilityIdentifier("insertMenu")
    }

    private var recordButton: some View {
        Button {
            controller.toggleRecording()
        } label: {
            ChromeIcon(symbol: controller.isRecording ? "stop.circle.fill" : "mic",
                       active: controller.isRecording,
                       activeColor: .red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isRecording ? "إيقاف التسجيل" : "تسجيل صوتي")
        .accessibilityIdentifier("recordButton")
    }

    private var handButton: some View {
        Button {
            controller.fingerDrawing.toggle()
            controller.showToast(controller.fingerDrawing
                                 ? "الإصبع وكل الأقلام تكتب الآن"
                                 : "قلم أبل فقط — الإصبع للتمرير (رفض راحة اليد)")
        } label: {
            ChromeIcon(symbol: controller.fingerDrawing ? "hand.draw.fill" : "applepencil",
                       active: controller.fingerDrawing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("الكتابة بالإصبع وبأي قلم")
        .accessibilityIdentifier("fingerDrawing")
    }

    private var moreToolsButton: some View {
        Button {
            controller.activePopover = .moreTools
        } label: {
            ChromeIcon(symbol: "chevron.right", active: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("أدوات إضافية")
        .accessibilityIdentifier("moreTools")
        .popover(isPresented: controller.popoverBinding(.moreTools)) {
            MoreToolsView(controller: controller)
                .adaptivePanel(width: 340)
        }
    }

    // صف الألوان
    private var colorsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(controller.tools.swatches.enumerated()), id: \.offset) { index, hex in
                    SwatchButton(index: index, hex: hex, controller: controller)
                }
                Rectangle().fill(theme.border).frame(width: 1, height: 26).padding(.horizontal, 2)
                sizeButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .popover(isPresented: controller.popoverBinding(.color)) {
            ColorPaletteView(hex: Binding(
                get: {
                    if let index = controller.editingSwatchIndex, controller.tools.swatches.indices.contains(index) {
                        return controller.tools.swatches[index]
                    }
                    return controller.currentColorHex
                },
                set: { newValue in
                    if let index = controller.editingSwatchIndex {
                        controller.setSwatch(at: index, to: newValue)
                    } else {
                        controller.currentColorHex = newValue
                    }
                }
            ), title: controller.editingSwatchIndex == nil ? "لون الحبر" : "تخصيص اللون")
            .adaptivePanel(width: 340, height: 600)
            .onDisappear { controller.editingSwatchIndex = nil }
        }
    }

    private var sizeButton: some View {
        let kind = controller.activeInkKind
        let width = controller.width(for: kind)
        let range = kind.widthRange
        let fraction = (width - range.lowerBound) / max(0.01, range.upperBound - range.lowerBound)
        return Button {
            controller.activePopover = .size
        } label: {
            ZStack {
                Circle().fill(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                    .frame(width: 30, height: 30)
                Circle().fill(theme.primaryText)
                    .frame(width: 4 + 14 * fraction, height: 4 + 14 * fraction)
            }
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("سماكة القلم")
        .accessibilityIdentifier("sizeButton")
        .popover(isPresented: controller.popoverBinding(.size)) {
            SizePickerView(controller: controller)
                .adaptivePanel(width: 320)
        }
    }
}

/// أيقونة موحّدة لأزرار الشريط.
struct ChromeIcon: View {
    let symbol: String
    var active: Bool
    var activeColor: Color? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(active ? (activeColor ?? theme.accent) : theme.primaryText)
            .frame(width: 40, height: 36)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? (activeColor ?? theme.accent).opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
    }
}

/// زر أداة؛ الضغط مرة ثانية يفتح خياراتها.
struct ToolIconButton: View {
    let kind: ToolKind
    let symbol: String
    @ObservedObject var controller: EditorController

    @Environment(\.appTheme) private var theme

    var body: some View {
        let selected = controller.tools.kind == kind
        Button {
            controller.toolTapped(kind)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 34, height: 24)
                Capsule()
                    .fill(selected ? (kind.isInk ? controller.displayColor(controller.tools.color(for: kind)) : theme.accent) : Color.clear)
                    .frame(width: 18, height: 3)
            }
            .foregroundStyle(selected ? theme.accent : theme.primaryText)
            .frame(width: 40, height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? theme.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
        .accessibilityIdentifier("tool.\(kind.rawValue)")
        .popover(isPresented: controller.popoverBinding(.tool(kind))) {
            ToolOptionsView(kind: kind, controller: controller)
                .adaptivePanel(width: 340)
        }
    }
}

/// دائرة لون في الصف؛ الضغط المطوّل يخصّص اللون.
struct SwatchButton: View {
    let index: Int
    let hex: String
    @ObservedObject var controller: EditorController

    var body: some View {
        let selected = controller.tools.kind.isInk
            && controller.currentColorHex.uppercased() == hex.uppercased()
        Button {
            controller.selectSwatch(hex)
        } label: {
            ZStack {
                Circle()
                    .fill(controller.displayColor(hex))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                if selected {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .frame(width: 35, height: 35)
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(uiColor: UIColor(hex: hex).isDark && !controller.contentDark ? .white : .black).opacity(0.75))
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            controller.editingSwatchIndex = index
            controller.activePopover = .color
        })
        .accessibilityLabel("لون \(index + 1)")
        .accessibilityIdentifier("swatch.\(index)")
    }
}

// MARK: - لوحات منبثقة

/// اختيار السماكة: ثلاثة أحجام سريعة + شريط دقيق.
struct SizePickerView: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        let kind = controller.activeInkKind
        let range = kind.widthRange
        VStack(alignment: .leading, spacing: 16) {
            Text("السماكة — \(kind.title)").font(.headline)
            HStack(spacing: 18) {
                ForEach([0.08, 0.25, 0.55], id: \.self) { fraction in
                    let value = range.lowerBound + (range.upperBound - range.lowerBound) * fraction
                    Button {
                        controller.setWidth(value, for: kind)
                    } label: {
                        Circle()
                            .fill(controller.displayColor(controller.tools.color(for: kind)))
                            .frame(width: 6 + 34 * fraction, height: 6 + 34 * fraction)
                            .frame(width: 48, height: 48)
                            .background(Circle().stroke(Color.primary.opacity(abs(controller.width(for: kind) - value) < 0.01 ? 0.6 : 0.12), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            Slider(value: Binding(
                get: { controller.width(for: kind) },
                set: { controller.setWidth($0, for: kind) }
            ), in: range)
            .accessibilityIdentifier("widthSlider")
            Text(String(format: "%.1f", controller.width(for: kind)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sizePicker")
    }
}

/// أدوات إضافية: أقلام أخرى، المسطرة، التكبير، والكتابة بالإصبع (للآيفون).
struct MoreToolsView: View {
    @ObservedObject var controller: EditorController

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("أقلام إضافية").font(.headline)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ToolKind.extraInkKinds) { kind in
                        extraToolButton(kind)
                    }
                }

                Toggle(isOn: $controller.isRulerActive) {
                    Label("المسطرة", systemImage: "ruler")
                }
                .accessibilityIdentifier("rulerToggle")

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $controller.smartShapes) {
                        Label("الأشكال الذكية", systemImage: "square.on.circle")
                    }
                    .accessibilityIdentifier("smartShapesToggle")
                    Text("ارسم خطاً أو دائرة أو مربعاً أو مثلثاً وثبّت القلم نصف ثانية قبل ما ترفعه، فيتحول لشكل مضبوط.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if AppEnvironment.isPhone {
                    Toggle(isOn: $controller.fingerDrawing) {
                        Label("الكتابة بالإصبع", systemImage: "hand.draw")
                    }
                }

                Divider()
                Text("التكبير: \(controller.zoomPercent)%").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button {
                        controller.zoomOut()
                    } label: {
                        Image(systemName: "minus.magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("zoomOut")
                    Button {
                        controller.zoomToFit()
                    } label: {
                        Text("ملاءمة").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("zoomFit")
                    Button {
                        controller.zoomIn()
                    } label: {
                        Image(systemName: "plus.magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("zoomIn")
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moreToolsPanel")
    }

    private func extraToolButton(_ kind: ToolKind) -> some View {
        let selected = controller.tools.kind == kind
        return Button {
            controller.toolTapped(kind)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: kind.icon).font(.system(size: 20))
                Text(kind.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool.\(kind.rawValue)")
    }
}

/// خيارات الأداة: السماكة والألوان للأقلام، وأنواع الممحاة، وشرح التحديد الحر.
struct ToolOptionsView: View {
    let kind: ToolKind
    @ObservedObject var controller: EditorController

    @State private var showWheel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(kind.title).font(.headline)

                if kind.isInk {
                    inkOptions
                } else if kind == .eraser {
                    eraserOptions
                } else if kind == .tidy {
                    tidyOptions
                } else {
                    Text("ارسم دائرة حول الكتابة لتحديدها، ثم اسحبها لنقلها، أو المس التحديد لإظهار خيارات النسخ والقص والتكرار والحذف.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolOptions")
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { controller.width(for: kind) },
            set: { controller.setWidth($0, for: kind) }
        )
    }

    private var colorBinding: Binding<String> {
        Binding(
            get: { controller.tools.color(for: kind) },
            set: { controller.setColor($0, for: kind) }
        )
    }

    @ViewBuilder
    private var inkOptions: some View {
        HStack {
            Text("السماكة")
            Spacer()
            Text(String(format: "%.1f", controller.width(for: kind)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        Slider(value: widthBinding, in: kind.widthRange)
            .accessibilityIdentifier("widthSlider")

        RoundedRectangle(cornerRadius: 10)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(height: 56)
            .overlay(
                Capsule()
                    .fill(controller.displayColor(controller.tools.color(for: kind)).opacity(kind == .marker ? 0.6 : 1))
                    .frame(width: 180, height: max(1, min(controller.width(for: kind), 40)))
            )

        DisclosureGroup("دائرة الألوان", isExpanded: $showWheel) {
            ColorWheelPicker(hex: colorBinding, wheelSize: 190)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var tidyOptions: some View {
        Text("ارسم دائرة حول أي كتابة، فتصير أرتب وهي تبقى بخطك: السطر يستقيم وينزل على خط الصفحة، والمسافات بين الكلمات تتساوى، والرجفة الصغيرة تنعّم.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Toggle("تعديل ميلان السطر", isOn: $controller.tidyOptions.straighten)
        Toggle("الإنزال على خطوط الصفحة", isOn: $controller.tidyOptions.snapToLines)
        Toggle("توحيد المسافات بين الكلمات", isOn: $controller.tidyOptions.evenSpacing)
        Toggle("تنعيم الخط", isOn: $controller.tidyOptions.smooth)

        Divider()

        Button {
            controller.tidyCurrentPage()
        } label: {
            Label("ترتيب كل كتابة هذه الصفحة", systemImage: "wand.and.stars")
        }
        .accessibilityIdentifier("tidyPage")
    }

    @ViewBuilder
    private var eraserOptions: some View {
        Picker("نوع الممحاة", selection: $controller.tools.eraserMode) {
            ForEach(EraserMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("eraserMode")

        Text(controller.tools.eraserMode.explanation)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if controller.tools.eraserMode == .pixel {
            HStack {
                Text("حجم الممحاة")
                Spacer()
                Text("\(Int(controller.width(for: .eraser)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: widthBinding, in: ToolKind.eraser.widthRange)
        }

        Divider()

        Button(role: .destructive) {
            controller.closePopover {
                controller.showClearConfirmation = true
            }
        } label: {
            Label("مسح الصفحة بالكامل", systemImage: "trash")
        }
        .accessibilityIdentifier("clearPage")
    }
}

/// إعدادات العرض: متصل أو صفحة واحدة، المحتوى يطابق الثيم، شريط الحالة.
struct ViewSettingsView: View {
    @ObservedObject var controller: EditorController
    @EnvironmentObject private var settings: ThemeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("إعدادات العرض")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            modeRow(title: "متصل", subtitle: "تمرير متواصل بين الصفحات", symbol: "rectangle.split.1x2", seamless: true)
            Divider().padding(.leading, 56)
            modeRow(title: "صفحة واحدة", subtitle: "صفحة في كل مرة", symbol: "rectangle.portrait", seamless: false)
            Divider()
            Toggle(isOn: $settings.contentMatchesTheme) {
                Label("المحتوى يطابق الثيم", systemImage: "moon.stars")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityIdentifier("contentMatchesToggle")
            Divider().padding(.leading, 56)
            Toggle(isOn: $controller.showStatusBar) {
                Label("شريط الحالة", systemImage: "wifi")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Spacer(minLength: 0)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewSettings")
    }

    private func modeRow(title: String, subtitle: String, symbol: String, seamless: Bool) -> some View {
        Button {
            controller.seamless = seamless
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.seamless == seamless {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(seamless ? "viewSeamless" : "viewSingle")
    }
}

// MARK: - مؤشر الصفحات العمودي

struct VerticalPageNavigator: View {
    @ObservedObject var controller: EditorController
    var onShowPages: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Button {
                controller.previousPage()
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 34)
            }
            .disabled(controller.currentIndex == 0)
            .accessibilityLabel("الصفحة السابقة")
            .accessibilityIdentifier("prevPage")

            Button(action: onShowPages) {
                VStack(spacing: 3) {
                    Text("\(controller.currentIndex + 1)")
                    Rectangle().fill(theme.primaryText).frame(width: 10, height: 1.5)
                    Text("\(controller.pageCount)")
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 44, height: 50)
            }
            .accessibilityLabel("\(controller.currentIndex + 1) / \(controller.pageCount)")
            .accessibilityIdentifier("pageCounter")

            Button {
                controller.nextPage()
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 34)
            }
            .disabled(controller.currentIndex + 1 >= controller.pageCount)
            .accessibilityLabel("الصفحة التالية")
            .accessibilityIdentifier("nextPage")
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primaryText)
        .padding(.vertical, 6)
        .background(theme.toolbar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.1), radius: 8, y: 3)
    }
}
