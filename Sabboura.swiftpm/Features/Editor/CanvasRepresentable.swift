import SwiftUI

/// جسر بين SwiftUI ولوحة PencilKit (UIKit).
struct CanvasRepresentable: UIViewRepresentable {
    @ObservedObject var controller: EditorController
    var topInset: CGFloat
    var bottomInset: CGFloat

    func makeUIView(context: Context) -> PageCanvasContainerView {
        let view = PageCanvasContainerView(frame: .zero)
        view.topInset = topInset
        view.bottomInset = bottomInset
        controller.setAppearance(dark: context.environment.contentDark, theme: context.environment.appTheme)
        controller.attach(view)
        return view
    }

    func updateUIView(_ view: PageCanvasContainerView, context: Context) {
        view.topInset = topInset
        view.bottomInset = bottomInset
        controller.setAppearance(dark: context.environment.contentDark, theme: context.environment.appTheme)
        // يُطبَّق فقط عند تغيّر الأداة فعلاً (المقارنة داخل apply)
        view.apply(controller.canvasToolState)
    }
}
