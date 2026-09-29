import SwiftUI

/// على الآيباد: نافذة منبثقة بحجم ثابت. على الآيفون: ورقة سفلية قابلة للسحب مع زر «تم» واضح.
struct AdaptivePanelModifier: ViewModifier {
    let width: CGFloat
    let height: CGFloat?

    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    func body(content: Content) -> some View {
        if AppEnvironment.isPad {
            content
                .frame(width: width, height: height)
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Spacer()
                        Button("تم") { dismiss() }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("panelDone")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemBackground))
                    .overlay(alignment: .bottom) { Divider() }
                    .environment(\.layoutDirection, .rightToLeft)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func adaptivePanel(width: CGFloat, height: CGFloat? = nil) -> some View {
        modifier(AdaptivePanelModifier(width: width, height: height))
    }
}
