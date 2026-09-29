import SwiftUI

/// دائرة ألوان دقيقة (Hue/Saturation) مع شريط سطوع وحقل HEX.
/// - اسحب داخل الدائرة لاختيار الصبغة والتشبّع.
/// - الشريط يتحكم بالسطوع، والحقل يقبل إدخال لون بصيغة #RRGGBB بدقة تامة.
struct ColorWheelPicker: View {
    @Binding var hex: String
    var wheelSize: CGFloat = 220

    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 1
    @State private var hexField: String = ""
    @State private var lastEmitted: String = ""

    private var currentColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var body: some View {
        VStack(spacing: 16) {
            wheel
            brightnessSlider
            hexRow
        }
        .environment(\.layoutDirection, .leftToRight)
        .onAppear { load(from: hex) }
        .onChange(of: hex) { _, newValue in
            if newValue.uppercased() != lastEmitted.uppercased() {
                load(from: newValue)
            }
        }
    }

    // MARK: الدائرة

    private var wheel: some View {
        let radius = wheelSize / 2
        let angle = hue * 2 * .pi
        let thumbX = radius + CGFloat(cos(angle) * saturation) * radius
        let thumbY = radius + CGFloat(sin(angle) * saturation) * radius

        return ZStack {
            Circle()
                .fill(AngularGradient(gradient: Gradient(colors: Self.hueStops), center: .center))
            Circle()
                .fill(RadialGradient(gradient: Gradient(colors: [.white, .white.opacity(0)]),
                                     center: .center, startRadius: 0, endRadius: radius))
            Circle()
                .fill(Color.black.opacity(1 - brightness))
            Circle()
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            Circle()
                .fill(currentColor)
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .position(x: thumbX, y: thumbY)
        }
        .frame(width: wheelSize, height: wheelSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in pick(at: value.location, radius: radius) }
        )
        .accessibilityLabel("دائرة الألوان")
    }

    private static let hueStops: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }

    private func pick(at location: CGPoint, radius: CGFloat) {
        let dx = Double(location.x - radius)
        let dy = Double(location.y - radius)
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        hue = angle / (2 * .pi)
        saturation = min(1, sqrt(dx * dx + dy * dy) / Double(radius))
        if brightness < 0.05 { brightness = 1 }
        emit()
    }

    // MARK: السطوع

    private var brightnessSlider: some View {
        let binding = Binding<Double>(
            get: { brightness },
            set: { brightness = $0; emit() }
        )
        return HStack(spacing: 10) {
            Image(systemName: "sun.min").foregroundStyle(.secondary)
            Slider(value: binding, in: 0...1)
                .tint(Color(hue: hue, saturation: saturation, brightness: 1))
            Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
        }
        .frame(width: max(wheelSize, 240))
    }

    // MARK: HEX

    private var hexRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(currentColor)
                .frame(width: 44, height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.2), lineWidth: 1))
            TextField("#RRGGBB", text: $hexField)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit(applyHexField)
            ColorPicker("", selection: systemPickerBinding, supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel("منتقي الألوان الكامل مع القطّارة")
        }
    }

    private var systemPickerBinding: Binding<Color> {
        Binding(
            get: { Color(hex: hex) },
            set: { newColor in
                let newHex = UIColor(newColor).hexString
                lastEmitted = ""
                hex = newHex
            }
        )
    }

    private func applyHexField() {
        guard let normalized = HexColor.normalized(hexField) else {
            hexField = hex
            return
        }
        load(from: normalized)
        lastEmitted = normalized
        hex = normalized
    }

    private func load(from value: String) {
        let color = UIColor(hex: value)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h)
        saturation = Double(s)
        brightness = Double(b)
        hexField = HexColor.normalized(value) ?? value
        lastEmitted = hexField
    }

    private func emit() {
        let newHex = UIColor(hue: CGFloat(hue), saturation: CGFloat(saturation),
                             brightness: CGFloat(brightness), alpha: 1).hexString
        lastEmitted = newHex
        hexField = newHex
        if newHex != hex { hex = newHex }
    }
}

/// لوحة ألوان كاملة: ألوان جاهزة + آخر المستخدم + دائرة الألوان.
struct ColorPaletteView: View {
    @Binding var hex: String
    var title: String = "لون الحبر"
    var presets: [String] = ColorPresets.ink

    @State private var recent: [String] = RecentColors.all

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 10), count: 7)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.headline)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(presets, id: \.self) { swatch($0) }
                }

                if !recent.isEmpty {
                    Text("المستخدمة مؤخراً").font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(recent, id: \.self) { swatch($0) }
                    }
                }

                Divider()
                Text("لون مخصّص").font(.subheadline).foregroundStyle(.secondary)
                ColorWheelPicker(hex: $hex)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("colorPalette")
        .onDisappear {
            if !presets.contains(hex.uppercased()) {
                RecentColors.add(hex)
            }
        }
    }

    private func swatch(_ value: String) -> some View {
        let selected = value.uppercased() == hex.uppercased()
        return Button {
            hex = value
        } label: {
            Circle()
                .fill(Color(hex: value))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                .overlay(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 36, height: 36)
                        .opacity(selected ? 1 : 0)
                )
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value)
        .accessibilityIdentifier("swatch.\(value)")
    }
}
