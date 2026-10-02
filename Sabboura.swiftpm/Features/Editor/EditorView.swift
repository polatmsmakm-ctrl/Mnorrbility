import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// شاشة الكتابة بملء الشاشة مع شريط عائم.
struct EditorView: View {
    @ObservedObject var note: CDNote
    @StateObject private var controller: EditorController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    /// ماذا نفعل بالملفات المختارة من تطبيق الملفات
    private enum FileImportMode { case pdfPages, attachment, images }

    @State private var showFileImporter = false
    @State private var fileImportMode: FileImportMode = .attachment
    @State private var pendingFiles: [ImportedFile] = []
    @State private var showImportChoice = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showAttachments = false
    @State private var showPages = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDeletePage = false
    @State private var showStudy = false

    init(note: CDNote) {
        self.note = note
        _controller = StateObject(wrappedValue: EditorController(note: note))
    }

    private var isPad: Bool { AppEnvironment.isPad }
    private var toolbarHeight: CGFloat { isPad ? 118 : 156 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                CanvasRepresentable(controller: controller,
                                    topInset: toolbarHeight + proxy.safeAreaInsets.top,
                                    bottomInset: 20 + proxy.safeAreaInsets.bottom)
                    .environment(\.layoutDirection, .leftToRight)
                    .ignoresSafeArea()

                // شريط رفيع خلف منطقة الساعة حتى لا تظهر الكتابة تحتها عند التمرير
                theme.desk
                    .frame(height: proxy.safeAreaInsets.top)
                    .offset(y: -proxy.safeAreaInsets.top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                chrome
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VerticalPageNavigator(controller: controller, onShowPages: { showPages = true })
                .padding(.trailing, 14)
                .padding(.bottom, 22)
                .environment(\.layoutDirection, .leftToRight)
        }
        .overlay { busyOverlay }
        .background(theme.desk.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: allowedImportTypes,
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 10,
                      matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        datas.append(data)
                    }
                }
                await MainActor.run {
                    controller.insertImages(datas)
                    photoItems = []
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(onImage: { image in
                if let data = image.jpegData(compressionQuality: 0.9) {
                    // بعد إغلاق الكاميرا حتى يُحسب وسط الصفحة الظاهر بشكل صحيح
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        controller.insertImages([data])
                    }
                }
            }, onClose: { showCamera = false })
            .ignoresSafeArea()
        }
        .confirmationDialog("كيف تريد إدراج الملف؟", isPresented: $showImportChoice, titleVisibility: .visible) {
            if pendingFiles.contains(where: { $0.isImage }) {
                Button("كصورة داخل الصفحة") {
                    let images = pendingFiles.filter { $0.isImage }
                    let others = pendingFiles.filter { !$0.isImage }
                    controller.insertImages(images.map(\.data))
                    if !others.isEmpty { controller.importFiles(others, asPages: true) }
                    pendingFiles = []
                    contentImported()
                }
            }
            Button("كصفحات يمكن الكتابة فوقها") {
                controller.importFiles(pendingFiles, asPages: true)
                pendingFiles = []
                contentImported()
            }
            Button("كمرفق فقط") {
                controller.importFiles(pendingFiles, asPages: false)
                pendingFiles = []
            }
            Button("إلغاء", role: .cancel) { pendingFiles = [] }
        } message: {
            Text("يمكن تحويل ملفات PDF والصور إلى صفحات تكتب عليها مباشرة.")
        }
        .confirmationDialog("مسح كل ما في هذه الصفحة؟",
                            isPresented: $controller.showClearConfirmation,
                            titleVisibility: .visible) {
            Button("مسح الصفحة", role: .destructive) { controller.clearPage() }
        } message: {
            Text("يمكنك التراجع عن المسح بزر التراجع.")
        }
        .confirmationDialog("حذف هذه الصفحة؟", isPresented: $confirmDeletePage, titleVisibility: .visible) {
            Button("حذف الصفحة نهائياً", role: .destructive) {
                controller.deletePage(at: controller.currentIndex)
            }
        }
        .alert("إعادة تسمية المذكرة", isPresented: $showRename) {
            TextField("العنوان", text: $renameText)
            Button("حفظ") { rename() }
            Button("إلغاء", role: .cancel) {}
        }
        .sheet(isPresented: $showAttachments) {
            AttachmentsView(note: note, controller: controller)
        }
        .sheet(isPresented: $showPages) {
            PagesOverviewView(controller: controller)
        }
        .sheet(item: $controller.editingItem) { target in
            ItemEditorSheet(target: target, controller: controller)
        }
        .sheet(isPresented: $showStudy) {
            NoteStudyView(note: note)
        }
        .onAppear {
            appState.noteDebug("editor appear")
            appState.hideStatusBar = !controller.showStatusBar
            DispatchQueue.main.async {
                controller.didAppear()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                controller.runTestImportIfNeeded()
            }
        }
        .onDisappear {
            appState.noteDebug("editor disappear")
            appState.hideStatusBar = false
            controller.stopRecordingIfNeeded()
            controller.flush()
            // المذكرة تغيّرت؟ نجهّز بطاقات الحفظ والكويز في الخلفية
            StudyService.shared.noteDidChange(note)
        }
        .onChange(of: controller.showStatusBar) { _, show in
            appState.hideStatusBar = !show
        }
    }

    // MARK: الأزرار العائمة

    @ViewBuilder
    private var chrome: some View {
        if isPad {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    backButton
                    Spacer(minLength: 8)
                    FloatingToolbar(controller: controller,
                                    onInsertImage: { showPhotoPicker = true },
                                    onTakePhoto: { takePhoto() },
                                    onImageFromFiles: { imageFromFiles() },
                                    onImportPDF: { importPDF() },
                                    onImportFile: { importFile() })
                        .frame(maxWidth: 560)
                    Spacer(minLength: 8)
                    actionCluster
                }
                toastView
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .environment(\.layoutDirection, .leftToRight)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    backButton
                    Text(note.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    actionCluster
                }
                FloatingToolbar(controller: controller,
                                onInsertImage: { showPhotoPicker = true },
                                onTakePhoto: { takePhoto() },
                                onImageFromFiles: { imageFromFiles() },
                                onImportPDF: { importPDF() },
                                onImportFile: { importFile() })
                toastView
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var backButton: some View {
        Button {
            controller.flush()
            dismiss()
        } label: {
            Image(systemName: "arrow.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 46, height: 46)
                .background(theme.toolbar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("رجوع")
        .accessibilityIdentifier("editorBack")
    }

    private var actionCluster: some View {
        HStack(spacing: 0) {
            clusterButton("arrow.uturn.backward", label: "تراجع", id: "undo", enabled: controller.canUndo) {
                controller.undo()
            }
            clusterButton("arrow.uturn.forward", label: "إعادة", id: "redo", enabled: controller.canRedo) {
                controller.redo()
            }
            clusterButton("rectangle.on.rectangle.angled", label: "مراجعة: بطاقات وكويز", id: "studyButton") {
                controller.flush()
                showStudy = true
            }
            shareMenu
            moreMenu
            if isPad {
                clusterButton("doc.badge.plus", label: "صفحة جديدة", id: "addPage") {
                    controller.addPage()
                }
                clusterButton("square.on.square", label: "كل الصفحات", id: "pagesButton") {
                    showPages = true
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 46)
        .background(theme.toolbar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.border, lineWidth: 1))
        .popover(isPresented: controller.popoverBinding(.viewSettings)) {
            ViewSettingsView(controller: controller)
                .environmentObject(ThemeSettings.shared)
                .adaptivePanel(width: 340, height: 330)
        }
    }

    private func clusterButton(_ symbol: String, label: String, id: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? theme.primaryText : theme.secondaryText.opacity(0.5))
                .frame(width: isPad ? 40 : 36, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var shareMenu: some View {
        Menu {
            Button {
                controller.exportNoteAsPDF()
            } label: {
                Label("المذكرة كاملة PDF", systemImage: "doc.richtext")
            }
            Button {
                controller.exportCurrentPageAsPDF()
            } label: {
                Label("الصفحة الحالية PDF", systemImage: "doc")
            }
            Button {
                controller.exportCurrentPageAsImage()
            } label: {
                Label("الصفحة الحالية صورة PNG", systemImage: "photo")
            }
            if note.attachmentCount > 0 {
                Divider()
                Button {
                    controller.shareAttachments(note.sortedAttachments)
                } label: {
                    Label("الملفات المرفقة والتسجيلات", systemImage: "paperclip")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .frame(width: isPad ? 40 : 36, height: 40)
        }
        .accessibilityLabel("مشاركة وتصدير")
        .accessibilityIdentifier("exportMenu")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                controller.activePopover = .background
            } label: {
                Label("قالب الصفحة", systemImage: "doc.text.image")
            }
            Button {
                controller.activePopover = .viewSettings
            } label: {
                Label("إعدادات العرض", systemImage: "rectangle.split.1x2")
            }
            Divider()
            Button {
                controller.toggleFavorite()
            } label: {
                Label(note.isFavorite ? "إزالة من المفضلة" : "إضافة للمفضلة",
                      systemImage: note.isFavorite ? "star.slash" : "star")
            }
            Button {
                renameText = note.titleText
                showRename = true
            } label: {
                Label("إعادة تسمية", systemImage: "pencil")
            }
            Button {
                showAttachments = true
            } label: {
                Label("المرفقات والتسجيلات (\(note.attachmentCount))", systemImage: "paperclip")
            }
            Button {
                appState.showStudySetup = true
            } label: {
                Label("جلسة مذاكرة", systemImage: "timer")
            }
            if !isPad {
                Divider()
                Button {
                    controller.addPage()
                } label: {
                    Label("صفحة جديدة", systemImage: "doc.badge.plus")
                }
                Button {
                    showPages = true
                } label: {
                    Label("كل الصفحات", systemImage: "square.on.square")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmDeletePage = true
            } label: {
                Label("حذف الصفحة الحالية", systemImage: "doc.badge.ellipsis")
            }
            Button(role: .destructive) {
                controller.showClearConfirmation = true
            } label: {
                Label("مسح الصفحة", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .frame(width: isPad ? 40 : 36, height: 40)
        }
        .accessibilityLabel("المزيد")
        .accessibilityIdentifier("moreMenu")
        .popover(isPresented: controller.popoverBinding(.background)) {
            BackgroundPickerView(controller: controller)
                .adaptivePanel(width: 380, height: 660)
        }
    }

    // MARK: عناصر عائمة

    @ViewBuilder
    private var toastView: some View {
        VStack(spacing: 8) {
            if controller.isRecording, let start = controller.recordingStart {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(start))
                    Label("جارٍ التسجيل \(seconds / 60):\(String(format: "%02d", seconds % 60))", systemImage: "record.circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red, in: Capsule())
                }
                .accessibilityIdentifier("recordingPill")
            }
            if let message = controller.toast {
                Text(message)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.toolbar, in: Capsule())
                    .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .accessibilityIdentifier("toast")
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.35), value: controller.toast)
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if controller.isBusy {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView("جارٍ تجهيز الملف…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: إجراءات

    private var allowedImportTypes: [UTType] {
        switch fileImportMode {
        case .pdfPages: return [.pdf, .image]
        case .attachment: return [.item]
        case .images: return [.image]
        }
    }

    private func importPDF() {
        fileImportMode = .pdfPages
        showFileImporter = true
    }

    private func importFile() {
        fileImportMode = .attachment
        showFileImporter = true
    }

    private func imageFromFiles() {
        fileImportMode = .images
        showFileImporter = true
    }

    private func takePhoto() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            controller.showToast("الكاميرا غير متاحة على هذا الجهاز")
            return
        }
        showCamera = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let files = FileImportReader.read(result)
        guard !files.isEmpty else { return }
        if fileImportMode == .images {
            controller.insertImages(files.map(\.data))
            contentImported()
        } else if fileImportMode == .pdfPages {
            controller.importFiles(files, asPages: true)
            contentImported()
        } else if files.contains(where: { $0.isPDF || $0.isImage }) {
            pendingFiles = files
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showImportChoice = true
            }
        } else {
            controller.importFiles(files, asPages: false)
        }
    }

    /// ملف أو صور جديدة في المذكرة: نجهّز المراجعة في الخلفية.
    private func contentImported() {
        StudyService.shared.noteDidChange(note, delay: 2.5)
    }

    private func rename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, note.isAlive else { return }
        note.title = trimmed
        note.updatedAt = Date()
        controller.flush()
    }
}

// MARK: - تعديل نص أو صورة

struct ItemEditorSheet: View {
    @State var target: ItemEditTarget
    @ObservedObject var controller: EditorController
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(target: ItemEditTarget, controller: EditorController) {
        _target = State(initialValue: target)
        self.controller = controller
    }

    var body: some View {
        NavigationStack {
            Form {
                if target.item.kind == .text {
                    Section("النص") {
                        TextEditor(text: $target.item.text)
                            .frame(minHeight: 140)
                            .focused($focused)
                            .accessibilityIdentifier("itemText")
                    }
                    Section("الحجم") {
                        Slider(value: $target.item.fontSize, in: 10...96, step: 1)
                        Toggle("خط عريض", isOn: $target.item.isBold)
                    }
                    Section("اللون") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                            ForEach(controller.tools.swatches, id: \.self) { hex in
                                Button {
                                    target.item.colorHex = hex
                                } label: {
                                    Circle()
                                        .fill(controller.displayColor(hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(Circle().stroke(Color.accentColor, lineWidth: target.item.colorHex == hex ? 3 : 0).padding(-3))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section("الحجم") {
                        Slider(value: Binding(
                            get: { target.item.width },
                            set: { newWidth in
                                let ratio = target.item.height / max(target.item.width, 1)
                                target.item.width = newWidth
                                target.item.height = newWidth * ratio
                            }
                        ), in: 80...800)
                    }
                }
                if !target.isNew {
                    Section {
                        Button(role: .destructive) {
                            controller.deleteItem(target)
                            dismiss()
                        } label: {
                            Label(target.item.kind == .text ? "حذف النص" : "حذف الصورة", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(target.item.kind == .text ? (target.isNew ? "نص جديد" : "تعديل النص") : "الصورة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") {
                        controller.saveItem(target)
                        dismiss()
                    }
                    .accessibilityIdentifier("itemDone")
                }
            }
            .onAppear {
                if target.item.kind == .text { focused = true }
            }
        }
        .presentationDetents([.medium, .large])
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - الكاميرا

/// التقاط صورة بالكاميرا لإدراجها في الصفحة.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.onClose()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onClose()
        }
    }
}
