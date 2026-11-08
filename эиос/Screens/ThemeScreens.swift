import SwiftUI
import Combine

// ==========================================
// ОФОРМЛЕНИЕ: свои цвета, новогодний режим зимой, заметки
// ==========================================

/// User colours stored as hex in UserDefaults. Read through Color.themeAccent / cardBackground /
/// appBackground, so every screen follows them; nil means the built-in default.
enum AppTheme {
    static let accentKey = "theme.accent"
    static let cardKey = "theme.card"
    static let backgroundKey = "theme.background"
    static let studentTopKey = "theme.studentTop"
    static let studentBottomKey = "theme.studentBottom"
    static let allKeys = [accentKey, cardKey, backgroundKey, studentTopKey, studentBottomKey]
    /// Set when a theme is applied: Settings confirms it after the screens are redrawn.
    static let appliedNoticeKey = "theme.appliedNotice"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Color] = [:]

    static func color(_ key: String) -> Color? {
        guard let hex = UserDefaults.standard.string(forKey: key) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[hex] { return cached }
        let parsed = Color(hex: hex)
        cache[hex] = parsed
        return parsed
    }

    static func set(_ color: Color?, for key: String) {
        if let hex = color?.hexString { UserDefaults.standard.set(hex, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    struct Preset: Identifiable {
        let id: String
        let accent: Color
        var card: Color? = nil
        var background: Color? = nil
    }

    static let presets: [Preset] = [
        Preset(id: "Синий", accent: Color(red: 0.0, green: 0.48, blue: 1.0)),
        Preset(id: "Фиолетовый", accent: Color(red: 0.56, green: 0.33, blue: 0.95)),
        Preset(id: "Розовый", accent: Color(red: 1.0, green: 0.3, blue: 0.6)),
        Preset(id: "Красный", accent: Color(red: 0.92, green: 0.2, blue: 0.2)),
        Preset(id: "Оранжевый", accent: Color(red: 1.0, green: 0.55, blue: 0.0)),
        Preset(id: "Жёлтый", accent: Color(red: 0.95, green: 0.75, blue: 0.0)),
        Preset(id: "Зелёный", accent: Color(red: 0.15, green: 0.72, blue: 0.35)),
        Preset(id: "Бирюзовый", accent: Color(red: 0.0, green: 0.7, blue: 0.75)),
        Preset(id: "Полночь", accent: Color(red: 0.45, green: 0.6, blue: 1.0),
               card: Color(red: 0.1, green: 0.12, blue: 0.22), background: Color(red: 0.04, green: 0.05, blue: 0.12)),
        Preset(id: "Лес", accent: Color(red: 0.4, green: 0.85, blue: 0.5),
               card: Color(red: 0.08, green: 0.16, blue: 0.11), background: Color(red: 0.03, green: 0.08, blue: 0.05)),
    ]
}

/// Bumped when the theme changes; the root view uses it to redraw everything once.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published private(set) var revision = 0
    func apply() { revision += 1 }
}

extension Color {
    init?(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 8, Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        self.init(.sRGB, red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
                  blue: Double((value >> 8) & 0xFF) / 255, opacity: Double(value & 0xFF) / 255)
    }

    var hexString: String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X%02X", clamp(red), clamp(green), clamp(blue), clamp(alpha))
    }

    /// Screen background; the user's colour when set.
    static var appBackground: Color { AppTheme.color(AppTheme.backgroundKey) ?? Color(UIColor.systemGroupedBackground) }
}

/// «Авто»: on from 1 December to the end of February, unless switched on/off in Settings.
enum ChristmasMode: String, CaseIterable {
    case auto, on, off
    static let settingKey = "christmasModeSetting"
    static let effectiveKey = "isChristmasMode"

    var title: String {
        switch self {
        case .auto: return "Авто (зимой)"
        case .on: return "Всегда"
        case .off: return "Выключен"
        }
    }

    static var setting: ChristmasMode {
        ChristmasMode(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "") ?? .auto
    }

    static func isWinter(_ date: Date = Date()) -> Bool {
        [12, 1, 2].contains(CampusDate.calendar.component(.month, from: date))
    }

    /// Writes the effective flag that all screens read through @AppStorage("isChristmasMode").
    static func refresh() {
        let enabled: Bool
        switch setting {
        case .auto: enabled = isWinter()
        case .on: enabled = true
        case .off: enabled = false
        }
        if UserDefaults.standard.bool(forKey: effectiveKey) != enabled { UserDefaults.standard.set(enabled, forKey: effectiveKey) }
    }
}

/// A string of blinking lights under the header in the festive mode.
@MainActor
struct ChristmasGarland: View {
    private let colors: [Color] = [.red, .yellow, .green, .blue, .orange, .pink]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.7)) { timeline in
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 0.7)
            Canvas { context, size in
                let count = max(Int(size.width / 22), 1)
                var wire = Path()
                for index in 0...count {
                    let x = CGFloat(index) * size.width / CGFloat(count)
                    let point = CGPoint(x: x, y: index.isMultiple(of: 2) ? 4 : 9)
                    index == 0 ? wire.move(to: point) : wire.addLine(to: point)
                }
                context.stroke(wire, with: .color(.green.opacity(0.6)), lineWidth: 1.2)
                for index in 0..<count {
                    let x = (CGFloat(index) + 0.5) * size.width / CGFloat(count)
                    let lit = (index + tick).isMultiple(of: 2)
                    let color = colors[index % colors.count]
                    let bulb = CGRect(x: x - 3.5, y: 8, width: 7, height: 10)
                    if lit { context.fill(Path(ellipseIn: bulb.insetBy(dx: -4, dy: -4)), with: .color(color.opacity(0.25))) }
                    context.fill(Path(ellipseIn: bulb), with: .color(lit ? color : color.opacity(0.35)))
                }
            }
        }
        .frame(height: 22).allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor
struct ThemeSettingsScreen: View {
    @ObservedObject private var dataManager = AppDataManager.shared
    @AppStorage(ChristmasMode.settingKey) private var christmasSetting = ChristmasMode.auto.rawValue
    @State private var accent = AppTheme.color(AppTheme.accentKey) ?? Color(red: 0.0, green: 0.48, blue: 1.0)
    @State private var card = AppTheme.color(AppTheme.cardKey) ?? Color(red: 0.11, green: 0.11, blue: 0.12)
    @State private var background = AppTheme.color(AppTheme.backgroundKey) ?? Color(UIColor.systemGroupedBackground)
    @State private var studentTop = AppTheme.color(AppTheme.studentTopKey) ?? .black
    @State private var studentBottom = AppTheme.color(AppTheme.studentBottomKey) ?? Color(red: 0.0, green: 0.3, blue: 0.8)
    @State private var useCustomCard = AppTheme.color(AppTheme.cardKey) != nil
    @State private var useCustomBackground = AppTheme.color(AppTheme.backgroundKey) != nil
    @State private var useCustomStudent = AppTheme.color(AppTheme.studentTopKey) != nil
    @State private var changed = false

    var body: some View {
        Form {
            Section("Предпросмотр") { preview }
            Section("Готовые цвета") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(AppTheme.presets) { preset in
                            Button { apply(preset) } label: {
                                VStack(spacing: 6) {
                                    Circle().fill(preset.accent).frame(width: 38, height: 38)
                                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                    Text(preset.id).font(.caption2).foregroundColor(.primary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 6)
                }
            }
            Section(header: Text("Каждая деталь"), footer: Text("Палитра позволяет выбрать любой цвет, включая прозрачность.")) {
                ColorPicker("Акцент: кнопки, вкладки, чаты", selection: $accent).onChange(of: accent) { _, _ in changed = true }
                Toggle("Свой цвет карточек", isOn: $useCustomCard).onChange(of: useCustomCard) { _, _ in changed = true }
                if useCustomCard { ColorPicker("Карточки", selection: $card).onChange(of: card) { _, _ in changed = true } }
                Toggle("Свой фон экранов", isOn: $useCustomBackground).onChange(of: useCustomBackground) { _, _ in changed = true }
                if useCustomBackground { ColorPicker("Фон", selection: $background).onChange(of: background) { _, _ in changed = true } }
                Toggle("Свои цвета студенческого", isOn: $useCustomStudent).onChange(of: useCustomStudent) { _, _ in changed = true }
                if useCustomStudent {
                    ColorPicker("Студенческий: верх", selection: $studentTop).onChange(of: studentTop) { _, _ in changed = true }
                    ColorPicker("Студенческий: низ", selection: $studentBottom).onChange(of: studentBottom) { _, _ in changed = true }
                }
            }
            Section(header: Text("Новогодний режим"), footer: Text("«Авто» включает снег, гирлянду и праздничные цвета с 1 декабря по конец февраля.")) {
                Picker("Новогодний режим", selection: $christmasSetting) {
                    ForEach(ChristmasMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: christmasSetting) { _, _ in ChristmasMode.refresh() }
            }
            Section {
                Button("Применить") { save() }.disabled(!changed)
                Button("Вернуть стандартные цвета", role: .destructive) {
                    AppTheme.allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
                    ThemeStore.shared.apply()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Оформление")
        .onDisappear { if changed { save() } }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinearGradient(colors: useCustomStudent ? [studentTop, studentBottom] : Color.gradientColors(index: dataManager.cardColorIndex),
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 56).cornerRadius(14)
                .overlay(Text("Студенческий").font(.caption.bold()).foregroundColor(.white), alignment: .center)
            HStack {
                Text("Карточка").font(.subheadline)
                Spacer()
                Text("Кнопка").font(.subheadline.bold()).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(accent, in: Capsule())
            }
            .padding(12)
            .background(useCustomCard ? card : Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(10)
        .background(useCustomBackground ? background : Color(UIColor.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func apply(_ preset: AppTheme.Preset) {
        accent = preset.accent
        useCustomCard = preset.card != nil
        if let card = preset.card { self.card = card }
        useCustomBackground = preset.background != nil
        if let background = preset.background { self.background = background }
        changed = true
    }

    private func save() {
        AppTheme.set(accent, for: AppTheme.accentKey)
        AppTheme.set(useCustomCard ? card : nil, for: AppTheme.cardKey)
        AppTheme.set(useCustomBackground ? background : nil, for: AppTheme.backgroundKey)
        AppTheme.set(useCustomStudent ? studentTop : nil, for: AppTheme.studentTopKey)
        AppTheme.set(useCustomStudent ? studentBottom : nil, for: AppTheme.studentBottomKey)
        changed = false
        UserDefaults.standard.set(true, forKey: AppTheme.appliedNoticeKey)
        ThemeStore.shared.apply()
    }
}

/// Notes moved out of the profile into Settings.
@MainActor
struct NotesScreen: View {
    @ObservedObject private var dataManager = AppDataManager.shared
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $dataManager.notes)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(Color.appBackground)
            .overlay(alignment: .topLeading) {
                if dataManager.notes.isEmpty {
                    Text("Напиши сюда что-нибудь важное…").foregroundColor(.secondary).padding(20).allowsHitTesting(false)
                }
            }
            .navigationTitle("Личные заметки").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { focused = false } } }
    }
}
