import SwiftUI

/// لوحة اختيار خلفية الصفحة: نوع الورقة، سبورات جاهزة، ألوان حرة بدائرة ألوان، وتباعد الخطوط.
struct BackgroundPickerView: View {
    @ObservedObject var controller: EditorController

    @State private var template: PageTemplate
    @State private var colorTarget: ColorTarget = .background

    enum ColorTarget: String, CaseIterable, Identifiable {
        case background
        case lines
        var id: String { rawValue }
        var title: String { self == .background ? "لون الخلفية" : "لون الخطوط" }
    }

    init(controller: EditorController) {
        self.controller = controller
        _template = State(initialValue: controller.currentTemplate)
    }

    private let kindColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("نوع الورقة") {
                    LazyVGrid(columns: kindColumns, spacing: 12) {
                        ForEach(BackgroundKind.allCases) { kind in
                            kindTile(kind)
                        }
                    }
                }

                section("سبورات وألوان جاهزة") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(BoardPreset.all) { preset in
                                presetTile(preset)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                section("لون مخصّص") {
                    Picker("", selection: $colorTarget) {
                        ForEach(ColorTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)

                    ColorWheelPicker(hex: colorBinding, wheelSize: 200)
                        .frame(maxWidth: .infinity)
                }

                if template.kind != .blank {
                    section("تباعد الخطوط: \(Int(template.spacing))") {
                        Slider(value: $template.spacing, in: 16...64, step: 1)
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        controller.applyBackground(template, toAllPages: true)
                    } label: {
                        Label("تطبيق على كل صفحات المذكرة", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        controller.makeDefault(template)
                    } label: {
                        Label("اجعلها الخلفية الافتراضية للصفحات الجديدة", systemImage: "star")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backgroundPicker")
        .onChange(of: template) { _, newValue in
            controller.applyBackground(newValue, toAllPages: false)
        }
    }

    private var colorBinding: Binding<String> {
        Binding(
            get: { colorTarget == .background ? template.backgroundHex : template.lineHex },
            set: { newValue in
                if colorTarget == .background {
                    template.backgroundHex = newValue
                } else {
                    template.lineHex = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func kindTile(_ kind: BackgroundKind) -> some View {
        let selected = template.kind == kind
        let config = PageBackgroundConfig(kind: kind,
                                          backgroundHex: template.backgroundHex,
                                          lineHex: template.lineHex,
                                          spacing: CGFloat(template.spacing),
                                          pageSize: DataStore.standardPageSize)
            .themed(dark: controller.contentDark, theme: controller.theme)
        return Button {
            template.kind = kind
        } label: {
            VStack(spacing: 6) {
                Image(uiImage: PageRenderer.backgroundPreview(config, width: 90))
                    .resizable()
                    .aspectRatio(DataStore.standardPageSize.width / DataStore.standardPageSize.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: selected ? 3 : 1)
                    )
                Text(kind.title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bg.\(kind.rawValue)")
    }

    private func presetTile(_ preset: BoardPreset) -> some View {
        let selected = preset.backgroundHex == template.backgroundHex && preset.lineHex == template.lineHex
        return Button {
            template.backgroundHex = preset.backgroundHex
            template.lineHex = preset.lineHex
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: preset.backgroundHex))
                    .frame(width: 64, height: 46)
                    .overlay(
                        VStack(spacing: 7) {
                            ForEach(0..<3, id: \.self) { _ in
                                Rectangle().fill(Color(hex: preset.lineHex)).frame(height: 1)
                            }
                        }
                        .padding(.horizontal, 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: selected ? 3 : 1)
                    )
                Text(preset.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 70)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("board.\(BoardPreset.all.firstIndex(of: preset) ?? 0)")
    }
}
