import Combine
import SwiftUI
import UserNotifications

/// جلسات المذاكرة (بومودورو): فترات دراسة واستراحة متتالية مع تنبيهات.
final class StudySessionManager: ObservableObject {
    static let shared = StudySessionManager()

    enum Phase: String, Codable {
        case study
        case rest

        var title: String { self == .study ? "دراسة" : "استراحة" }
        var symbol: String { self == .study ? "book.fill" : "cup.and.saucer.fill" }
    }

    struct Running: Codable, Equatable {
        var phase: Phase
        var session: Int          // رقم الجلسة الحالية (يبدأ من 1)
        var endDate: Date?        // nil أثناء الإيقاف المؤقت
        var remaining: TimeInterval
    }

    @Published var studyMinutes: Int { didSet { defaults.set(studyMinutes, forKey: Keys.study) } }
    @Published var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: Keys.rest) } }
    @Published var totalSessions: Int { didSet { defaults.set(totalSessions, forKey: Keys.total) } }
    @Published private(set) var running: Running? { didSet { persist() } }
    @Published private(set) var now = Date()

    private let defaults = UserDefaults.standard
    private var timer: AnyCancellable?

    private enum Keys {
        static let study = "sabboura.study.minutes"
        static let rest = "sabboura.study.break"
        static let total = "sabboura.study.total"
        static let running = "sabboura.study.running"
        static let log = "sabboura.study.log"
    }

    init() {
        studyMinutes = defaults.object(forKey: Keys.study) as? Int ?? 45
        breakMinutes = defaults.object(forKey: Keys.rest) as? Int ?? 15
        totalSessions = defaults.object(forKey: Keys.total) as? Int ?? 4
        if let data = defaults.data(forKey: Keys.running),
           let saved = try? JSONDecoder().decode(Running.self, from: data) {
            running = saved
        }
        startTicking()
    }

    var isActive: Bool { running != nil }
    var isPaused: Bool { running != nil && running?.endDate == nil }

    var remaining: TimeInterval {
        guard let running else { return 0 }
        if let end = running.endDate {
            return max(0, end.timeIntervalSince(now))
        }
        return running.remaining
    }

    var remainingText: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// دقائق الدراسة المكتملة اليوم.
    var minutesToday: Int {
        let log = defaults.dictionary(forKey: Keys.log) as? [String: Int] ?? [:]
        return log[Self.dayKey(Date())] ?? 0
    }

    // MARK: التحكم

    func start() {
        running = Running(phase: .study, session: 1,
                          endDate: Date().addingTimeInterval(TimeInterval(studyMinutes * 60)),
                          remaining: TimeInterval(studyMinutes * 60))
        requestNotificationPermission()
        scheduleNotification()
    }

    func pause() {
        guard var current = running, let end = current.endDate else { return }
        current.remaining = max(0, end.timeIntervalSinceNow)
        current.endDate = nil
        running = current
        cancelNotifications()
    }

    func resume() {
        guard var current = running, current.endDate == nil else { return }
        current.endDate = Date().addingTimeInterval(current.remaining)
        running = current
        scheduleNotification()
    }

    func stop() {
        running = nil
        cancelNotifications()
    }

    func skip() {
        advance()
    }

    /// إعادة الحساب بعد العودة من الخلفية.
    func refresh() {
        now = Date()
        checkPhaseEnd()
    }

    // MARK: داخلي

    private func startTicking() {
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                guard let self, self.running != nil else { return }
                self.now = date
                self.checkPhaseEnd()
            }
    }

    private func checkPhaseEnd() {
        guard let current = running, let end = current.endDate, end <= Date() else { return }
        advance()
    }

    private func advance() {
        guard let current = running else { return }
        if current.phase == .study {
            logStudy(minutes: studyMinutes)
            if current.session >= totalSessions {
                running = nil
                cancelNotifications()
                return
            }
            running = Running(phase: .rest, session: current.session,
                              endDate: Date().addingTimeInterval(TimeInterval(breakMinutes * 60)),
                              remaining: TimeInterval(breakMinutes * 60))
        } else {
            running = Running(phase: .study, session: current.session + 1,
                              endDate: Date().addingTimeInterval(TimeInterval(studyMinutes * 60)),
                              remaining: TimeInterval(studyMinutes * 60))
        }
        scheduleNotification()
    }

    private func logStudy(minutes: Int) {
        var log = defaults.dictionary(forKey: Keys.log) as? [String: Int] ?? [:]
        let key = Self.dayKey(Date())
        log[key, default: 0] += minutes
        defaults.set(log, forKey: Keys.log)
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func persist() {
        if let running, let data = try? JSONEncoder().encode(running) {
            defaults.set(data, forKey: Keys.running)
        } else {
            defaults.removeObject(forKey: Keys.running)
        }
    }

    // MARK: التنبيهات

    private func requestNotificationPermission() {
        guard !AppEnvironment.isUITest else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotification() {
        cancelNotifications()
        guard let current = running, let end = current.endDate else { return }
        let content = UNMutableNotificationContent()
        if current.phase == .study {
            content.title = "انتهت فترة الدراسة"
            content.body = current.session >= totalSessions
                ? "أحسنت! أكملت كل الجلسات."
                : "خذ استراحة \(breakMinutes) دقيقة."
        } else {
            content.title = "انتهت الاستراحة"
            content.body = "حان وقت الجلسة \(current.session + 1) من \(totalSessions)."
        }
        content.sound = .default
        let interval = max(1, end.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: "sabboura.study", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["sabboura.study"])
    }
}

// MARK: - شاشة إعداد الجلسة

struct StudySetupView: View {
    @EnvironmentObject private var study: StudySessionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var customTarget: CustomTarget? = nil
    @State private var customText = ""

    enum CustomTarget: String, Identifiable {
        case study, rest, total
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    optionRow(title: "الدراسة (دقائق)", values: [15, 30, 45, 60],
                              selected: study.studyMinutes, target: .study) { study.studyMinutes = $0 }
                    optionRow(title: "الاستراحة (دقائق)", values: [5, 10, 15, 20, 25],
                              selected: study.breakMinutes, target: .rest) { study.breakMinutes = $0 }
                    optionRow(title: "عدد الجلسات", values: [2, 4, 6, 8, 10],
                              selected: study.totalSessions, target: .total) { study.totalSessions = $0 }

                    if study.minutesToday > 0 {
                        Label("درست اليوم \(study.minutesToday) دقيقة", systemImage: "chart.bar.fill")
                            .foregroundStyle(theme.secondaryText)
                    }

                    Button {
                        study.start()
                        dismiss()
                    } label: {
                        Text(study.isActive ? "إعادة بدء الجلسة" : "ابدأ الجلسة")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("startStudy")

                    if study.isActive {
                        Button(role: .destructive) {
                            study.stop()
                            dismiss()
                        } label: {
                            Text("إنهاء الجلسة الحالية").frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(24)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("جلسات المذاكرة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("closeStudy")
                }
            }
            .alert("قيمة مخصصة", isPresented: Binding(get: { customTarget != nil }, set: { if !$0 { customTarget = nil } })) {
                TextField("العدد", text: $customText)
                    .keyboardType(.numberPad)
                Button("حفظ") { applyCustom() }
                Button("إلغاء", role: .cancel) { customTarget = nil }
            }
        }
        .presentationDetents([.large])
    }

    private func optionRow(title: String, values: [Int], selected: Int, target: CustomTarget,
                           set: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(theme.primaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    chip(label: "+", isSelected: !values.contains(selected)) {
                        customText = values.contains(selected) ? "" : "\(selected)"
                        customTarget = target
                    }
                    ForEach(values, id: \.self) { value in
                        chip(label: "\(value)", isSelected: value == selected) { set(value) }
                            .accessibilityIdentifier("\(target.rawValue).\(value)")
                    }
                    if !values.contains(selected) {
                        chip(label: "\(selected)", isSelected: true) {}
                    }
                }
            }
        }
    }

    private func chip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .frame(minWidth: 64, minHeight: 50)
                .padding(.horizontal, 6)
                .background(Capsule().fill(isSelected ? theme.accent.opacity(0.18) : theme.card))
                .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                .foregroundStyle(isSelected ? theme.accent : theme.primaryText)
        }
        .buttonStyle(.plain)
    }

    private func applyCustom() {
        guard let value = Int(customText.trimmingCharacters(in: .whitespaces)), value > 0 else {
            customTarget = nil
            return
        }
        switch customTarget {
        case .study: study.studyMinutes = min(value, 240)
        case .rest: study.breakMinutes = min(value, 120)
        case .total: study.totalSessions = min(value, 20)
        case .none: break
        }
        customTarget = nil
    }
}

// MARK: - شريط المؤقت العائم

struct StudyTimerPill: View {
    @EnvironmentObject private var study: StudySessionManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let running = study.running {
            HStack(spacing: 10) {
                Image(systemName: running.phase.symbol)
                    .foregroundStyle(running.phase == .study ? theme.accent : .orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(running.phase.title) \(study.remainingText)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("الجلسة \(running.session) من \(study.totalSessions)")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
                Button {
                    study.isPaused ? study.resume() : study.pause()
                } label: {
                    Image(systemName: study.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 30, height: 30)
                }
                .accessibilityIdentifier("studyPause")
                Button {
                    study.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 30, height: 30)
                }
                .accessibilityIdentifier("studyStop")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(theme.toolbar, in: Capsule())
            .overlay(Capsule().stroke(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .onTapGesture { appState.showStudySetup = true }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studyPill")
        }
    }
}
