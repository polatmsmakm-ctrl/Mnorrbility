import UIKit
import XCTest

/// اختبارات واجهة شاملة: تُشغَّل على محاكي آيباد ومحاكي آيفون وتلتقط صوراً لكل خطوة.
final class SabbouraUITests: XCTestCase {
    private var app: XCUIApplication!
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private let folderName = "الرياضيات"

    /// بداية منطقة الكتابة (الشريط العائم يغطي أعلى الشاشة)
    private var rowBase: CGFloat { isPad ? 0.22 : 0.34 }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
    }

    // MARK: - الاختبارات

    /// المسار الكامل بالثيم الداكن: مجلد ← مذكرة ← كتابة ← أدوات ← نص ← قالب ← صفحات ← تصدير ← مفضلة ← حذف واسترجاع.
    func test1_FullFlow() {
        launch(reset: true, extra: ["-uitest-dark"])
        snap("01-library")

        openFolder()
        snap("02-folder")
        newNote()
        let canvas = canvasElement()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "لوحة الكتابة لم تظهر")
        sleep(1)
        snap("03-editor-empty")

        drawZigzag(on: canvas, row: rowBase)
        drawZigzag(on: canvas, row: rowBase + 0.06)
        XCTAssertTrue(app.buttons["undo"].waitForEnabled(timeout: 12), "زر التراجع لم يتفعّل بعد الكتابة")

        tap(app.buttons["tool.pencil"], "tool.pencil")
        drawZigzag(on: canvas, row: rowBase + 0.12)
        tap(app.buttons["tool.marker"], "tool.marker")
        drawLine(on: canvas, from: CGVector(dx: 0.15, dy: rowBase), to: CGVector(dx: 0.8, dy: rowBase))
        tap(app.buttons["tool.pen"], "tool.pen")
        tap(app.buttons["swatch.1"], "swatch blue")
        drawZigzag(on: canvas, row: rowBase + 0.18)
        tap(app.buttons["swatch.3"], "swatch red")
        drawZigzag(on: canvas, row: rowBase + 0.24)
        snap("04-drawn")

        // خيارات القلم والسماكة
        tap(app.buttons["tool.pen"], "tool.pen options")
        let options = app.descendants(matching: .any)["toolOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 4), "خيارات الأداة لم تظهر")
        snap("05-tool-options")
        dismissPanel(checking: options)
        tap(app.buttons["sizeButton"], "sizeButton")
        let sizePicker = app.descendants(matching: .any)["sizePicker"]
        XCTAssertTrue(sizePicker.waitForExistence(timeout: 4), "لوحة السماكة لم تظهر")
        dismissPanel(checking: sizePicker)

        // الممحاة: كلمة كاملة ثم تحديد ومسح
        tap(app.buttons["tool.eraser"], "tool.eraser")
        tap(app.buttons["tool.eraser"], "eraser options")
        if options.waitForExistence(timeout: 4) {
            tap(app.buttons["كلمة كاملة"], "stroke eraser mode")
            dismissPanel(checking: options)
        }
        drawLine(on: canvas, from: CGVector(dx: 0.5, dy: rowBase + 0.16), to: CGVector(dx: 0.5, dy: rowBase + 0.21))
        snap("06-erased")
        tap(app.buttons["undo"], "undo")
        tap(app.buttons["redo"], "redo")

        // مربع نص
        tap(app.buttons["tool.text"], "tool.text")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: rowBase + 0.34)).tap()
        let textField = app.textViews["itemText"]
        if textField.waitForExistence(timeout: 5) {
            textField.tap()
            textField.typeText("Hello notes")
            tap(app.buttons["itemDone"], "itemDone")
        } else {
            XCTFail("نافذة النص لم تظهر")
        }
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["textItem"].waitForExistence(timeout: 4), "النص لم يُضف")
        snap("07-text")
        tap(app.buttons["tool.pen"], "tool.pen back")

        // قالب الصفحة
        openMore("قالب الصفحة")
        let picker = app.descendants(matching: .any)["backgroundPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 4), "لوحة القوالب لم تظهر")
        tap(app.buttons["bg.grid"], "bg.grid")
        snap("08-template-picker")
        dismissPanel(checking: picker)

        // إعدادات العرض: صفحة واحدة ثم متصل
        openMore("إعدادات العرض")
        let viewSettings = app.descendants(matching: .any)["viewSettings"]
        XCTAssertTrue(viewSettings.waitForExistence(timeout: 4), "إعدادات العرض لم تظهر")
        snap("09-view-settings")
        tap(app.buttons["viewSingle"], "viewSingle")
        tap(app.buttons["viewSeamless"], "viewSeamless")
        dismissPanel(checking: viewSettings)

        // صفحة جديدة + تنقل
        addPage()
        XCTAssertTrue(waitForLabel(app.buttons["pageCounter"], contains: "2 / 2"), "الصفحة الجديدة لم تُضف")
        sleep(1)
        drawZigzag(on: canvas, row: rowBase + 0.1)
        snap("10-page-2")
        tap(app.buttons["prevPage"], "prevPage")
        XCTAssertTrue(waitForLabel(app.buttons["pageCounter"], contains: "1 / 2"), "لم يتم الرجوع للصفحة الأولى")
        sleep(1)
        snap("11-seamless")

        // كل الصفحات
        tap(app.buttons["pageCounter"], "pageCounter")
        let done = app.buttons["pagesDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "شاشة الصفحات لم تظهر")
        sleep(1)
        snap("12-pages-overview")
        done.tap()

        // التكبير
        canvas.pinch(withScale: 1.8, velocity: 2)
        sleep(1)
        snap("13-zoomed")
        canvas.pinch(withScale: 0.6, velocity: -2)

        // التصدير PDF
        tap(app.buttons["exportMenu"], "exportMenu")
        tap(app.buttons["المذكرة كاملة PDF"], "export pdf")
        waitForShareSheet()
        snap("14-share-pdf")
        dismissShareSheet()

        // الرجوع للملاحظات
        tap(app.buttons["editorBack"], "editorBack")
        sleep(2)
        snap("15-folder-with-note")

        // مفضلة + تكرار + حذف من القائمة المختصرة
        let card = app.buttons.matching(identifier: "noteCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "بطاقة المذكرة غير موجودة")
        card.press(forDuration: 1.3)
        tap(app.buttons["إضافة للمفضلة"], "favorite")
        sleep(1)
        app.buttons.matching(identifier: "noteCard").firstMatch.press(forDuration: 1.3)
        tap(app.buttons["تكرار"], "duplicate")
        sleep(1)
        XCTAssertEqual(app.buttons.matching(identifier: "noteCard").count, 2, "التكرار لم ينجح")
        app.buttons.matching(identifier: "noteCard").firstMatch.press(forDuration: 1.3)
        tap(app.buttons["حذف"], "delete from context menu")
        tap(app.buttons["حذف"], "confirm delete")
        sleep(2)
        XCTAssertEqual(app.buttons.matching(identifier: "noteCard").count, 1, "الحذف لم ينجح")

        // تبويبات الملاحظات والمفضلة
        goToSidebar()
        tap(app.buttons["nav.notes"], "nav.notes")
        tap(app.buttons["tab.favorites"], "tab.favorites")
        sleep(1)
        snap("16-favorites")
        tap(app.buttons["tab.all"], "tab.all")

        // الإعدادات ← المحذوفة مؤخراً ← استرجاع
        goToSidebar()
        tap(app.buttons["settingsButton"], "settingsButton")
        tap(app.buttons["settings.trash"], "settings.trash", fallbackStaticText: "المحذوفة مؤخراً")
        let restore = app.buttons["restoreNote"].firstMatch
        if restore.waitForExistence(timeout: 5) {
            snap("17-trash")
            restore.tap()
        } else {
            XCTFail("المذكرة المحذوفة غير موجودة في السلة")
        }
        closeSettings()
        assertAppAlive("نهاية المسار الكامل")
    }

    /// الثيمات: من الفاتح إلى الأسود الفاحم، والمحتوى يطابق الثيم.
    func test2_Themes() {
        launch(reset: true)
        sleep(1)
        snap("20-light-library")
        openFolder()
        newNote()
        let canvas = canvasElement()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        drawZigzag(on: canvas, row: rowBase)
        tap(app.buttons["tool.text"], "tool.text")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: rowBase + 0.12)).tap()
        if app.textViews["itemText"].waitForExistence(timeout: 5) {
            app.textViews["itemText"].tap()
            app.textViews["itemText"].typeText("Light and dark")
            tap(app.buttons["itemDone"], "itemDone")
        }
        tap(app.buttons["tool.pen"], "tool.pen")
        sleep(3)
        snap("21-light-editor")
        tap(app.buttons["editorBack"], "editorBack")
        sleep(1)

        goToSidebar()
        tap(app.buttons["settingsButton"], "settingsButton")
        tap(app.buttons["settings.appearance"], "settings.appearance", fallbackStaticText: "المظهر", optional: isPad)
        let match = app.switches["matchSystem"].firstMatch
        if match.waitForExistence(timeout: 5) {
            for offset in [0.08, 0.92, 0.5] where (match.value as? String) == "1" {
                match.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)).tap()
                sleep(1)
            }
        } else {
            XCTFail("إعداد مطابقة المظهر غير موجود")
        }
        sleep(1)
        tap(app.buttons["theme.jetBlack"], "theme.jetBlack")
        sleep(1)
        snap("22-appearance")
        closeSettings()
        sleep(1)
        snap("23-dark-library")

        openFolder()
        let card = app.buttons.matching(identifier: "noteCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(canvasElement().waitForExistence(timeout: 10))
        sleep(2)
        snap("24-dark-editor")
        assertAppAlive("الثيمات")
    }

    /// استيراد PDF كصفحات للكتابة عليها (وضع داكن مع عكس ألوان PDF) + المرفقات + المعرض.
    func test3_PDFImport() {
        launch(reset: true, extra: ["-uitest-import-pdf", "-uitest-insert-image", "-uitest-dark", "-uitest-theme", "darkBlue"])
        openFolder()
        newNote()
        let canvas = canvasElement()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(app.buttons["pageCounter"], contains: "/ 3", timeout: 12), "صفحات PDF لم تُستورد")
        // صورة داخل صفحة الـPDF
        XCTAssertTrue(app.descendants(matching: .any)["imageItem"].firstMatch.waitForExistence(timeout: 8),
                      "الصورة لم تُدرج في صفحة PDF")
        sleep(5)
        snap("30-pdf-dark")
        tap(app.buttons["tool.pen"], "tool.pen")
        drawZigzag(on: canvas, row: rowBase + 0.3)
        tap(app.buttons["tool.marker"], "marker")
        drawLine(on: canvas, from: CGVector(dx: 0.15, dy: rowBase + 0.1), to: CGVector(dx: 0.7, dy: rowBase + 0.1))
        snap("31-pdf-annotated")

        openMore("المرفقات والتسجيلات", prefix: true)
        let doneButton = app.buttons["attachmentsDone"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "المرفقات لم تظهر")
        sleep(1)
        snap("32-attachments")
        doneButton.tap()

        tap(app.buttons["exportMenu"], "exportMenu")
        tap(app.buttons["الصفحة الحالية صورة PNG"], "export png")
        waitForShareSheet()
        snap("33-share-png")
        dismissShareSheet()

        // المراجعة من ملف PDF مستورد (صفحة إنجليزية وصفحة عربية)
        tap(app.buttons["studyButton"], "studyButton (pdf)")
        let pdfCard = app.descendants(matching: .any)["flashcard"].firstMatch
        XCTAssertTrue(pdfCard.waitForExistence(timeout: 90), "بطاقات المراجعة لم تُجهَّز من ملف PDF")
        sleep(1)
        snap("35-review-pdf")
        tap(app.buttons["studyTab.quiz"], "studyTab.quiz (pdf)")
        sleep(1)
        snap("36-review-pdf-quiz")
        tap(app.buttons["studyTab.summary"], "studyTab.summary (pdf)")
        sleep(1)
        snap("37-review-pdf-summary")
        let arabicPoint = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'الخلية' OR label CONTAINS 'النواة' OR label CONTAINS 'الميتوكوندريا'")).firstMatch
        XCTAssertTrue(arabicPoint.waitForExistence(timeout: 4), "النص العربي في ملف PDF لم يُقرأ بشكل صحيح")
        tap(app.buttons["studyClose"], "studyClose (pdf)")
        sleep(1)

        tap(app.buttons["editorBack"], "editorBack")
        sleep(1)
        goToSidebar()
        tap(app.buttons["nav.gallery"], "nav.gallery")
        sleep(2)
        snap("34-gallery")
        assertAppAlive("استيراد PDF")
    }

    /// الحفظ التلقائي: الكتابة ثم إغلاق التطبيق وإعادة فتحه.
    func test4_Persistence() {
        launch(reset: true, extra: ["-uitest-dark"])
        openFolder()
        newNote()
        let canvas = canvasElement()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        drawZigzag(on: canvas, row: rowBase)
        drawZigzag(on: canvas, row: rowBase + 0.08)
        addPage()
        sleep(1)
        drawZigzag(on: canvas, row: rowBase + 0.1)
        sleep(2)
        app.terminate()

        launch(reset: false, extra: ["-uitest-dark"])
        openFolder()
        let card = app.buttons.matching(identifier: "noteCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "المذكرة لم تُحفظ بعد إعادة التشغيل")
        sleep(1)
        snap("40-after-relaunch")
        card.tap()
        XCTAssertTrue(canvasElement().waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(app.buttons["pageCounter"], contains: "/ 2", timeout: 6), "عدد الصفحات لم يُحفظ")
        sleep(1)
        snap("41-restored-drawing")
        assertAppAlive("الحفظ التلقائي")
    }

    /// الرئيسية وجلسات المذاكرة.
    func test5_HomeAndStudy() {
        launch(reset: true, extra: ["-uitest-dark"])
        goToSidebar()
        tap(app.buttons["nav.home"], "nav.home")
        sleep(1)
        snap("50-home")
        tap(app.buttons["home.study"], "home.study")
        XCTAssertTrue(app.buttons["startStudy"].waitForExistence(timeout: 5), "شاشة جلسات المذاكرة لم تظهر")
        tap(app.buttons["study.30"], "study 30")
        tap(app.buttons["rest.5"], "rest 5")
        tap(app.buttons["total.2"], "total 2")
        snap("51-study-setup")
        tap(app.buttons["startStudy"], "startStudy")
        let pill = app.descendants(matching: .any)["studyPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "مؤقت المذاكرة لم يظهر")
        sleep(2)
        snap("52-study-running")
        tap(app.buttons["studyPause"], "studyPause")
        tap(app.buttons["studyStop"], "studyStop")
        assertAppAlive("جلسات المذاكرة")
    }

    /// الأشكال الذكية (ارسم وثبّت) وترتيب الخط.
    func test6_SmartInk() {
        launch(reset: true, extra: ["-uitest-dark"])
        openFolder()
        newNote()
        let canvas = canvasElement()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        sleep(1)

        // خط مائل قليلاً مع تثبيت القلم في النهاية ← يصبح خطاً مستقيماً مضبوطاً
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: rowBase + 0.02))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: rowBase + 0.035))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.9)
        let toast = app.staticTexts["toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 4) && toast.label.contains("shape-snapped"),
                      "الخط لم يتحول لشكل مضبوط")
        snap("60-smart-line")

        // سطران من «كلمات» مكتوبة على خط مائل وبمسافات غير متساوية، ثم «ترتيب كل كتابة هذه الصفحة»
        for row in [0.14, 0.26] {
            for (step, x) in [0.14, 0.25, 0.4, 0.48, 0.63].enumerated() {
                let baseline = rowBase + row + CGFloat(step) * 0.012
                drawLine(on: canvas, from: CGVector(dx: x, dy: baseline), to: CGVector(dx: x + 0.035, dy: baseline - 0.025))
                drawLine(on: canvas, from: CGVector(dx: x + 0.035, dy: baseline - 0.025), to: CGVector(dx: x + 0.07, dy: baseline))
            }
        }
        sleep(1)
        snap("61-before-tidy")
        tap(app.buttons["tool.tidy"], "tool.tidy")
        sleep(3)
        tap(app.buttons["tool.tidy"], "tidy options")
        let options = app.descendants(matching: .any)["toolOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 4), "خيارات ترتيب الخط لم تظهر")
        snap("62-tidy-options")
        tap(app.buttons["tidyPage"], "tidyPage")
        let result = app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND (label CONTAINS 'ترتيب' OR label CONTAINS 'مرتبة')")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 6), "ترتيب الخط لم يعمل")
        sleep(1)
        snap("63-after-tidy")
        tap(app.buttons["undo"], "undo tidy")
        tap(app.buttons["tool.pen"], "tool.pen")
        assertAppAlive("الأشكال الذكية وترتيب الخط")
    }

    /// الصور داخل المذكرة: إدراج، تكبير بالمقبض، تحريك، تراجع، حذف، كتابة فوقها، وتصدير.
    func test7_Images() {
        launch(reset: true, extra: ["-uitest-dark", "-uitest-insert-image"])
        openFolder()
        newNote()
        let image = app.descendants(matching: .any)["imageItem"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), "الصورة لم تُدرج")
        sleep(2)
        snap("70-image-inserted")

        let handle = app.descendants(matching: .any)["resizeHandle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 4), "مقبض تغيير الحجم لم يظهر")
        let before = image.frame
        let grab = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.2, thenDragTo: grab.withOffset(CGVector(dx: before.width * 0.3, dy: before.height * 0.3)))
        sleep(1)
        let resized = image.frame
        XCTAssertGreaterThan(resized.width, before.width + 10, "تغيير حجم الصورة لم ينجح")
        snap("71-image-resized")

        let middle = image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.2, thenDragTo: middle.withOffset(CGVector(dx: -30, dy: 90)))
        sleep(1)
        XCTAssertGreaterThan(image.frame.minY, resized.minY + 40, "تحريك الصورة لم ينجح")
        snap("72-image-moved")

        tap(app.buttons["undo"], "undo move")
        sleep(1)
        XCTAssertEqual(image.frame.minY, resized.minY, accuracy: 8, "التراجع عن تحريك الصورة لم ينجح")

        tap(app.buttons["deleteItem"], "deleteItem")
        XCTAssertTrue(image.waitForNonExistence(timeout: 4), "حذف الصورة لم ينجح")
        tap(app.buttons["undo"], "undo delete")
        XCTAssertTrue(app.descendants(matching: .any)["imageItem"].firstMatch.waitForExistence(timeout: 4),
                      "التراجع عن حذف الصورة لم ينجح")

        tap(app.buttons["tool.pen"], "tool.pen")
        drawZigzag(on: canvasElement(), row: rowBase + 0.12)
        sleep(1)
        snap("73-image-annotated")

        tap(app.buttons["exportMenu"], "exportMenu")
        tap(app.buttons["المذكرة كاملة PDF"], "export pdf")
        waitForShareSheet()
        dismissShareSheet()
        assertAppAlive("الصور")
    }

    /// المراجعة الذكية: بطاقات حفظ وكويز وملخص تتولد من كلام المذكرة.
    func test8_Review() {
        launch(reset: true, extra: ["-uitest-dark"])
        openFolder()
        newNote()
        let canvas = canvasElement()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        tap(app.buttons["tool.text"], "tool.text")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: rowBase + 0.05)).tap()
        let field = app.textViews["itemText"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("Photosynthesis is the process plants use to make food from sunlight. "
                           + "Chlorophyll is the green pigment that absorbs light. "
                           + "The mitochondria is the powerhouse of the cell. "
                           + "Osmosis is the movement of water across a membrane. "
                           + "The nucleus contains the genetic material of the cell. "
                           + "Respiration releases energy from glucose in every living cell.")
            tap(app.buttons["itemDone"], "itemDone")
        } else {
            XCTFail("نافذة النص لم تظهر")
        }
        tap(app.buttons["tool.pen"], "tool.pen")
        sleep(1)

        tap(app.buttons["studyButton"], "studyButton")
        let card = app.descendants(matching: .any)["flashcard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "بطاقات المراجعة لم تُجهَّز")
        sleep(1)
        snap("80-review-card")
        card.tap()
        sleep(1)
        snap("81-review-card-back")
        tap(app.buttons["cardKnown"], "cardKnown")
        tap(app.buttons["cardUnknown"], "cardUnknown")

        tap(app.buttons["studyTab.quiz"], "studyTab.quiz")
        tap(app.buttons["quizOption.0"], "quizOption.0")
        XCTAssertTrue(app.descendants(matching: .any)["quizFeedback"].waitForExistence(timeout: 4), "الكويز لم يُظهر الإجابة")
        snap("82-review-quiz")
        tap(app.buttons["quizNext"], "quizNext")

        tap(app.buttons["studyTab.summary"], "studyTab.summary")
        XCTAssertTrue(app.descendants(matching: .any)["studyEngine"].waitForExistence(timeout: 4), "الملخص لم يظهر")
        let fullPoint = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sunlight' OR label CONTAINS 'glucose' OR label CONTAINS 'genetic material'")).firstMatch
        XCTAssertTrue(fullPoint.waitForExistence(timeout: 4), "أهم النقاط ما ظهرت بجمل كاملة")
        sleep(1)
        snap("83-review-summary")
        tap(app.buttons["studyClose"], "studyClose")
        sleep(1)
        XCTAssertTrue(canvas.exists, "لم يرجع للمذكرة بعد إغلاق المراجعة")

        // من قائمة المذكرة في المجلد
        tap(app.buttons["editorBack"], "editorBack")
        sleep(2)
        let noteCard = app.buttons.matching(identifier: "noteCard").firstMatch
        XCTAssertTrue(noteCard.waitForExistence(timeout: 5))
        noteCard.press(forDuration: 1.3)
        tap(app.buttons["مراجعة: بطاقات وكويز"], "review from context menu")
        XCTAssertTrue(app.descendants(matching: .any)["flashcard"].firstMatch.waitForExistence(timeout: 20),
                      "المراجعة لم تفتح من قائمة المذكرة")
        snap("84-review-from-menu")
        tap(app.buttons["studyClose"], "studyClose")
        sleep(1)

        // إعدادات المراجعة: Gemini المجاني وخانة مفتاحه
        goToSidebar()
        tap(app.buttons["settingsButton"], "settingsButton")
        tap(app.buttons["settings.review"], "settings.review", fallbackStaticText: "المراجعة الذكية")
        tap(app.buttons["provider.gemini"], "provider.gemini")
        XCTAssertTrue(app.secureTextFields["geminiKeyField"].waitForExistence(timeout: 5), "خانة مفتاح Gemini لم تظهر")
        sleep(1)
        snap("85-review-settings-gemini")
        closeSettings()
        assertAppAlive("المراجعة الذكية")
    }

    // MARK: - أدوات مساعدة

    private func launch(reset: Bool, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-uitest"] + (reset ? ["-uitest-reset"] : []) + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "التطبيق لم يعمل")
    }

    private func assertAppAlive(_ step: String) {
        XCTAssertEqual(app.state, .runningForeground, "التطبيق توقف أثناء: \(step)")
    }

    private func canvasElement() -> XCUIElement {
        app.descendants(matching: .any)["canvas"]
    }

    /// على الآيفون: الرجوع إلى القائمة الجانبية.
    private func goToSidebar() {
        guard !isPad else { return }
        for _ in 0..<4 where !app.buttons["settingsButton"].exists {
            goBack()
            sleep(1)
        }
    }

    private func openFolder() {
        goToSidebar()
        let row = app.buttons["folder.\(folderName)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "المجلد \(folderName) غير موجود")
        row.tap()
        XCTAssertTrue(app.buttons["newButton"].waitForExistence(timeout: 8), "شاشة الملاحظات لم تظهر")
    }

    private func newNote() {
        tap(app.buttons["newButton"], "newButton")
        tap(app.buttons["مذكرة جديدة"], "new note item")
        let canvas = canvasElement()
        if canvas.waitForExistence(timeout: 8) { return }
        // تشخيص: سجل التنقّل داخل التطبيق ثم فتح المذكرة من بطاقتها لمتابعة بقية الاختبار
        let log = app.staticTexts["debugLog"].firstMatch
        XCTFail("المذكرة الجديدة لم تُفتح تلقائياً — سجل التنقّل: \(log.exists ? log.label : "غير متاح")")
        snap("missing-editor-after-new")
        let card = app.buttons.matching(identifier: "noteCard").firstMatch
        if card.waitForExistence(timeout: 3) { card.tap() }
    }

    private func addPage() {
        if isPad {
            tap(app.buttons["addPage"], "addPage")
        } else {
            openMore("صفحة جديدة")
        }
    }

    private func openMore(_ item: String, prefix: Bool = false) {
        tap(app.buttons["moreMenu"], "moreMenu")
        let element = prefix
            ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
            : app.buttons[item]
        tap(element, item)
    }

    private func closeSettings() {
        let close = app.buttons["closeSettings"].firstMatch
        if close.waitForExistence(timeout: 3) && close.isHittable {
            close.tap()
        } else {
            let other = app.buttons["إغلاق"].firstMatch
            if other.exists { other.tap() }
        }
        sleep(1)
    }

    private func goBack() {
        let bars = app.navigationBars
        for label in ["BackButton", "Back", "رجوع", "Mnorrbility", folderName, "الملاحظات"] {
            let button = bars.buttons[label].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
        let fallback = bars.firstMatch.buttons.element(boundBy: 0)
        if fallback.exists && fallback.isHittable { fallback.tap() }
    }

    @discardableResult
    private func tap(_ query: XCUIElement, _ what: String, timeout: TimeInterval = 6,
                     fallbackStaticText: String? = nil, optional: Bool = false) -> Bool {
        let element = query.firstMatch
        if element.waitForExistence(timeout: timeout) {
            let window = app.windows.firstMatch.frame
            let onScreen = !window.isEmpty && window.insetBy(dx: -1, dy: -1).contains(element.frame)
            if element.isHittable || !onScreen {
                element.tap()
            } else {
                // العنصر ظاهر لكن XCUITest يظنه مغطّى: نقرة على موضعه مباشرة كما يفعل المستخدم
                print("⚠️ \(what) غير قابل للنقر حسب XCUITest — نقرة بالإحداثيات")
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return true
        }
        if let text = fallbackStaticText {
            let label = app.staticTexts[text].firstMatch
            if label.exists {
                label.tap()
                return true
            }
        }
        if !optional {
            XCTFail("العنصر غير موجود: \(what)")
            snap("missing-\(what.replacingOccurrences(of: " ", with: "_"))")
        }
        return false
    }

    private func waitForLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func dismissPanel(checking element: XCUIElement) {
        let done = app.buttons["panelDone"].firstMatch
        if !isPad {
            for _ in 0..<2 where done.exists {
                done.tap()
                if element.waitForNonExistence(timeout: 3) { return }
            }
        }
        if isPad {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.97)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        if element.waitForNonExistence(timeout: 2) { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end)
        _ = element.waitForNonExistence(timeout: 2)
    }

    private var shareSheet: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
                                                            ["ActivityListView", "UIActivityContentView"])).firstMatch
    }

    private func waitForShareSheet() {
        if !shareSheet.waitForExistence(timeout: 12) {
            XCTFail("قائمة المشاركة لم تظهر")
        }
        sleep(1)
    }

    private func dismissShareSheet() {
        for _ in 0..<3 {
            guard shareSheet.exists else { return }
            let close = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                                                         ["Close", "إغلاق", "Cancel"], ["Close", "xmark"])).firstMatch
            if close.exists && close.isHittable {
                close.tap()
            } else if isPad {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.97)).tap()
            } else {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            _ = shareSheet.waitForNonExistence(timeout: 4)
        }
        if shareSheet.exists { XCTFail("تعذّر إغلاق قائمة المشاركة") }
    }

    // MARK: الرسم

    private func drawLine(on element: XCUIElement, from: CGVector, to: CGVector) {
        let start = element.coordinate(withNormalizedOffset: from)
        let end = element.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    private func drawZigzag(on element: XCUIElement, row: CGFloat) {
        drawLine(on: element, from: CGVector(dx: 0.12, dy: row), to: CGVector(dx: 0.35, dy: row + 0.03))
        drawLine(on: element, from: CGVector(dx: 0.38, dy: row + 0.03), to: CGVector(dx: 0.6, dy: row))
        drawLine(on: element, from: CGVector(dx: 0.63, dy: row), to: CGVector(dx: 0.85, dy: row + 0.03))
    }

    // MARK: الصور

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["SCREENSHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}

private extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
