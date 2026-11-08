import Foundation

/// One weekly slot of a two-week plan. Same JSON fields as the Android
/// manual_schedule.json, so one file serves both apps.
struct LessonTemplate: Codable, Equatable, Sendable {
    let weekday: Int // Monday = 1
    let number: Int
    let subject: String
    let type: String
    let teacher: String
    let place: String
    var requiresConfirmation: Bool = false

    enum CodingKeys: String, CodingKey { case weekday, number, subject, type, teacher, place, requiresConfirmation }
    init(weekday: Int, number: Int, subject: String, type: String, teacher: String, place: String, requiresConfirmation: Bool = false) {
        self.weekday = weekday; self.number = number; self.subject = subject; self.type = type
        self.teacher = teacher; self.place = place; self.requiresConfirmation = requiresConfirmation
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekday = try c.decode(Int.self, forKey: .weekday)
        number = try c.decode(Int.self, forKey: .number)
        subject = try c.decode(String.self, forKey: .subject)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        teacher = try c.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
        requiresConfirmation = try c.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
    }
}

/// A semester plan. The required fields match Android's ManualPlan; the optional ones
/// let a new semester change lesson times, notes and cancellations without an app update.
struct ManualPlan: Codable, Equatable, Sendable {
    let group: String
    let firstDay: String   // yyyy-MM-dd
    let lastDay: String
    let revisionDay: String // from this day the revised weeks apply; use lastDay+1 if unused
    let weekOne: [LessonTemplate]
    let weekTwo: [LessonTemplate]
    let revisedWeekOne: [LessonTemplate]
    let revisedWeekTwo: [LessonTemplate]
    var firstWeekNumber: Int? = nil        // week number of firstDay's week (1 or 2); default 2
    var times: [String: [String]]? = nil   // "1": ["08:00", "09:20"]
    var dayNotes: [String: String]? = nil
    var cancelledDays: [String]? = nil

    /// Rejects files that would produce a broken or absurd calendar.
    @discardableResult
    func validated() throws -> ManualPlan {
        let formatter = CampusDate.formatter("yyyy-MM-dd")
        func date(_ value: String) throws -> Date {
            guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value else {
                throw PortalFailure.unrecognized("дата «\(value)» в плане")
            }
            return parsed
        }
        let first = try date(firstDay), last = try date(lastDay)
        _ = try date(revisionDay)
        guard !group.trimmingCharacters(in: .whitespaces).isEmpty, first <= last,
              last.timeIntervalSince(first) <= 400 * 86_400 else { throw PortalFailure.unrecognized("период плана") }
        guard firstWeekNumber.map({ [1, 2].contains($0) }) ?? true else { throw PortalFailure.unrecognized("номер первой недели") }
        let lessons = weekOne + weekTwo + revisedWeekOne + revisedWeekTwo
        guard lessons.count <= 800, lessons.allSatisfy({ (1...7).contains($0.weekday) && (1...12).contains($0.number)
                                                        && !$0.subject.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw PortalFailure.unrecognized("занятия плана")
        }
        for (key, pair) in times ?? [:] {
            guard let number = Int(key), (1...12).contains(number), pair.count == 2,
                  pair.allSatisfy({ $0.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil }),
                  pair[0] < pair[1] else { throw PortalFailure.unrecognized("время пары \(key)") }
        }
        for day in (dayNotes.map { Array($0.keys) } ?? []) + (cancelledDays ?? []) { _ = try date(day) }
        return self
    }
}

// ИС-О-25/1: screenshots, Неделя 1,2.xlsx and the user's subsequent corrections.
// The user anchored 21 September to week 2 and limited repetition to 31 December.
// This built-in plan is only the fallback: a plan imported in Settings replaces it
// without reinstalling the app (see ManualPlanStore).
enum ManualSchedule {
    static let builtinPlan = ManualPlan(
        group: "ИС-О-25/1", firstDay: "2026-09-21", lastDay: "2026-12-31",
        // Updated screenshots received 3 October. Apply from the next Monday;
        // keep the September plan available as history.
        revisionDay: "2026-10-05",
        weekOne: weekOne, weekTwo: weekTwo, revisedWeekOne: revisedWeekOne, revisedWeekTwo: revisedWeekTwo,
        firstWeekNumber: 2, times: nil,
        dayNotes: ["2026-09-25": "Занятия отменены. Плановые пары сохранены для истории."],
        cancelledDays: ["2026-09-25"])

    /// The imported plan when present, otherwise the built-in one.
    static var plan: ManualPlan { ManualPlanStore.imported ?? builtinPlan }
    static var isImported: Bool { ManualPlanStore.imported != nil }

    static var group: String { plan.group }
    static var firstDay: String { plan.firstDay }
    static var lastDay: String { plan.lastDay }
    static var revisionDay: String { plan.revisionDay }
    private static var anchor: Date { CampusDate.formatter("yyyy-MM-dd").date(from: plan.firstDay)! }
    private static var end: Date { CampusDate.formatter("yyyy-MM-dd").date(from: plan.lastDay)! }

    static var periodLabel: String {
        let formatter = CampusDate.formatter("d MMMM yyyy")
        return "\(formatter.string(from: anchor)) — \(formatter.string(from: end))"
    }

    private static let cache = WindowCache()
    static var window: ScheduleWindow { cache.window(for: plan) }

    static func build(_ plan: ManualPlan) -> ScheduleWindow {
        let calendar = CampusDate.calendar
        let formatter = CampusDate.formatter("yyyy-MM-dd")
        guard let anchor = formatter.date(from: plan.firstDay), let end = formatter.date(from: plan.lastDay) else {
            return ScheduleWindow(days: [], items: [], origin: .manual)
        }
        let customTimes = (plan.times ?? [:]).reduce(into: [Int: (String, String)]()) { result, entry in
            if let number = Int(entry.key), entry.value.count == 2 { result[number] = (entry.value[0], entry.value[1]) }
        }
        let times = defaultTimes.merging(customTimes) { _, custom in custom }
        var days: [String] = []
        var items: [ScheduleItem] = []
        var date = anchor
        var offset = mondayShift(anchor)
        while date <= end {
            let day = CampusDate.key(date)
            days.append(day)
            let week = weekNumber(offset: offset, first: plan.firstWeekNumber ?? 2)
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7 + 1
            let templates = day < plan.revisionDay ? (week == 1 ? plan.weekOne : plan.weekTwo)
                : (week == 1 ? plan.revisedWeekOne : plan.revisedWeekTwo)
            for lesson in templates.filter({ $0.weekday == weekday }).sorted(by: { $0.number < $1.number }) {
                let time = times[lesson.number] ?? ("", "")
                items.append(ScheduleItem(
                    id: StableID.make(["manual", plan.group, day, String(lesson.number), lesson.subject]),
                    day: day, timeStart: time.0, timeEnd: time.1,
                    type: lesson.type, subject: lesson.subject, teacher: lesson.teacher,
                    place: lesson.place, subgroup: "", lessonNumber: lesson.number,
                    requiresConfirmation: lesson.requiresConfirmation ? true : nil
                ))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
            offset += 1
        }
        return ScheduleWindow(days: days, items: items, origin: .manual,
                              dayNotes: plan.dayNotes ?? [:], cancelledDays: plan.cancelledDays ?? [])
    }

    static func weekNumber(for day: String) -> Int? {
        let formatter = CampusDate.formatter("yyyy-MM-dd")
        guard let date = formatter.date(from: day), formatter.string(from: date) == day,
              date >= anchor, date <= end,
              let offset = CampusDate.calendar.dateComponents([.day], from: anchor, to: date).day else { return nil }
        return weekNumber(offset: offset + mondayShift(anchor), first: plan.firstWeekNumber ?? 2)
    }

    static func weekLabel(for day: String) -> String? {
        guard let week = weekNumber(for: day) else { return nil }
        return "\(week)-я неделя"
    }

    /// Days from the Monday of the first day's week: a study week starts on Monday even when
    /// the semester begins on a Tuesday, so the next Monday already belongs to the next week.
    private static func mondayShift(_ day: Date) -> Int {
        (CampusDate.calendar.component(.weekday, from: day) + 5) % 7
    }

    /// `offset` counts days from the Monday of the first week.
    private static func weekNumber(offset: Int, first: Int) -> Int {
        (offset / 7).isMultiple(of: 2) ? first : 3 - first
    }

    static func applying(to snapshot: PortalSnapshot, at date: Date = Date()) -> PortalSnapshot {
        let current = window
        guard snapshot.schedule?.value != current else { return snapshot }
        var next = snapshot
        next.schedule = CachedSection(value: current, fetchedAt: date, sources: [])
        return next
    }

    private static func lesson(_ weekday: Int, _ number: Int, _ subject: String,
                               type: String, teacher: String, place: String,
                               requiresConfirmation: Bool = false) -> LessonTemplate {
        LessonTemplate(weekday: weekday, number: number, subject: subject, type: type,
                       teacher: teacher, place: place, requiresConfirmation: requiresConfirmation)
    }

    static let defaultTimes: [Int: (String, String)] = [
        1: ("08:00", "09:20"), 2: ("09:30", "10:50"), 3: ("11:00", "12:20"),
        4: ("12:45", "14:05"), 5: ("14:15", "15:35"), 6: ("15:45", "17:05"),
        7: ("17:15", "18:35"),
        // No source has supplied the eighth slot's time. Do not extrapolate it.
    ]

    private static let revisedWeekOne: [LessonTemplate] = {
        var values = weekOne.filter { !($0.weekday == 4 && $0.number == 3) && !($0.weekday == 5 && $0.number == 4) }
        values += [
            lesson(4, 3, "Базы данных", type: "Лабораторная", teacher: "Комарова Юлиана Егоровна", place: "3/118"),
            lesson(4, 4, "Информатизация общества", type: "Лабораторная", teacher: "Беляева Олеся Львовна", place: "3/111"),
            lesson(4, 5, "Психология и педагогика", type: "Семинар", teacher: "Ж. Н. Донилова", place: "3/16"),
            // The screenshot combines slots 2 and 3, then repeats the course in 4.
            lesson(6, 2, "Русский язык как иностранный", type: "", teacher: "А. В. Фёдорова", place: "2/26"),
            lesson(6, 3, "Русский язык как иностранный", type: "", teacher: "А. В. Фёдорова", place: "2/26"),
            lesson(6, 4, "Русский язык как иностранный", type: "", teacher: "А. В. Фёдорова", place: "2/26"),
        ]
        return values.sorted { ($0.weekday, $0.number) < ($1.weekday, $1.number) }
    }()

    private static let revisedWeekTwo: [LessonTemplate] = {
        var values = weekTwo.filter { !($0.weekday == 1 && $0.number == 5) && !($0.weekday == 6) }
        values += [
            lesson(3, 2, "Проектный инженерный интенсив", type: "Интенсив", teacher: "", place: ""),
            lesson(3, 3, "Проектный инженерный интенсив", type: "Интенсив", teacher: "", place: ""),
            lesson(4, 1, "Университетский курс", type: "Университетский курс", teacher: "", place: "", requiresConfirmation: true),
            lesson(5, 5, "Проектный инженерный интенсив", type: "Интенсив", teacher: "", place: ""),
            lesson(5, 6, "Проектный инженерный интенсив", type: "Интенсив", teacher: "", place: ""),
            lesson(6, 2, "Основы военной подготовки", type: "Лекция", teacher: "Медведев Остап Вадимович", place: "Контур Толк · онлайн"),
            lesson(6, 6, "Дифференциальные уравнения", type: "Семинар", teacher: "Зайцева Олеся Денисовна", place: "2/20а"),
            lesson(6, 7, "Дифференциальные уравнения", type: "Семинар", teacher: "Зайцева Олеся Денисовна", place: "2/20а"),
        ]
        return values.sorted { ($0.weekday, $0.number) < ($1.weekday, $1.number) }
    }()

    private static let weekOne: [LessonTemplate] = [
        // Excel: A44
        lesson(1, 2, "Элективные курсы по физической культуре и спорту", type: "Практическое", teacher: "Соколова Олеся Алексеевна", place: ""),
        // Excel: A30
        lesson(1, 3, "Основы научных исследований", type: "Лекция", teacher: "Ершова Нина Остаповна", place: "332"),
        // Excel: A31
        lesson(1, 4, "Основы научных исследований", type: "Семинар", teacher: "Карпов Аркадий Антонович", place: "3/217"),
        // Excel: A32
        lesson(1, 5, "Философия", type: "Семинар", teacher: "Воронов Виктор Андреевич", place: "2/20а"),
        // Excel: A6, A33
        lesson(1, 6, "Графический дизайн и дизайн визуальных коммуникаций", type: "Университетский курс", teacher: "Голубев Артём Остапович", place: "3/111 · корпус 3, наб. р. Свияги"),
        // Excel: A6, A33
        lesson(1, 7, "Графический дизайн и дизайн визуальных коммуникаций", type: "Университетский курс", teacher: "Голубев Артём Остапович", place: "3/111 · корпус 3, наб. р. Свияги"),
        // Excel: A8, A9, A35
        lesson(2, 1, "Изучение английского языка", type: "Университетский курс", teacher: "Орлова Марина Владимировна", place: "2/26 · корпус 2, наб. р. Свияги"),
        // Excel: A8, A9, A35
        lesson(2, 2, "Изучение английского языка", type: "Университетский курс", teacher: "Орлова Марина Владимировна", place: "2/26 · корпус 2, наб. р. Свияги"),
        lesson(2, 3, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 4, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 5, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 6, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 7, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        // Excel: A12
        lesson(3, 4, "Дифференциальные уравнения", type: "Лекция", teacher: "Зайцева Олеся Денисовна", place: "332"),
        // Excel: A38
        lesson(3, 5, "Английский язык", type: "", teacher: "Морозова Инна Руслановна", place: "337"),
        // Excel: A40, A41
        lesson(4, 1, "Инвестируй правильно!", type: "Университетский курс", teacher: "Абрамова Юлиана Вадимовна", place: "303 · ул. Пушкинская, 4а"),
        // Excel: A40, A41
        lesson(4, 2, "Инвестируй правильно!", type: "Университетский курс", teacher: "Абрамова Юлиана Вадимовна", place: "303 · ул. Пушкинская, 4а"),
        // Excel: A42
        lesson(4, 3, "Информатизация общества", type: "Лабораторная", teacher: "Беляева Олеся Львовна", place: "3/111"),
        // Excel: A44
        lesson(5, 1, "Элективные курсы по физической культуре и спорту", type: "Практическое", teacher: "Соколова Олеся Алексеевна", place: ""),
        // Excel: A45
        lesson(5, 3, "Инновационная экономика и технологическое предпринимательство", type: "Семинар", teacher: "Тихонова Софья Юлиановна", place: "2/26"),
        // Excel: A20
        lesson(5, 4, "Базы данных", type: "Лабораторная", teacher: "Комарова Юлиана Егоровна", place: "503"),
        // Excel: A32
        lesson(6, 6, "Философия", type: "Лекция", teacher: "Воронов Виктор Андреевич", place: "Онлайн"),
        lesson(6, 7, "Психология и педагогика", type: "Лекция", teacher: "Ж. Н. Донилова", place: "Онлайн"),
        // Excel: A45
        lesson(6, 8, "Инновационная экономика и технологическое предпринимательство", type: "Лекция", teacher: "Тихонова Софья Юлиановна", place: "Онлайн"),
    ]

    private static let weekTwo: [LessonTemplate] = [
        // Excel: A44
        lesson(1, 2, "Физкультура", type: "Практическое", teacher: "Соколова Олеся Алексеевна", place: ""),
        // Excel: A4
        lesson(1, 3, "Базы данных", type: "Лекция", teacher: "Кудрявцева Софья Владимировна", place: "332"),
        // Excel: A5
        lesson(1, 4, "Основы военной подготовки", type: "Семинар", teacher: "Медведев Остап Вадимович", place: "5/11"),
        // Excel: A6
        lesson(1, 5, "Психология и педагогика", type: "Семинар", teacher: "", place: "3/321"),
        // Excel: A6, A33
        lesson(1, 6, "Графический дизайн и дизайн визуальных коммуникаций", type: "Университетский курс", teacher: "Голубев Артём Остапович", place: "3/111 · корпус 3, наб. р. Свияги"),
        // Excel: A6, A33
        lesson(1, 7, "Графический дизайн и дизайн визуальных коммуникаций", type: "Университетский курс", teacher: "Голубев Артём Остапович", place: "3/111 · корпус 3, наб. р. Свияги"),
        // Excel: A8, A9, A35
        lesson(2, 1, "Изучение английского языка", type: "Университетский курс", teacher: "Орлова Марина Владимировна", place: "2/26 · корпус 2, наб. р. Свияги"),
        // Excel: A8, A9, A35
        lesson(2, 2, "Изучение английского языка", type: "Университетский курс", teacher: "Орлова Марина Владимировна", place: "2/26 · корпус 2, наб. р. Свияги"),
        lesson(2, 3, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 4, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 5, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 6, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        lesson(2, 7, "Ознакомительная практика", type: "Практика", teacher: "", place: ""),
        // Excel: A12
        lesson(3, 4, "Дифференциальные уравнения", type: "Лекция", teacher: "Зайцева Олеся Денисовна", place: "332"),
        // Excel: A13
        lesson(4, 2, "Психологическая защита", type: "Университетский курс", teacher: "Гончаренко Нина Глебовна", place: "2/26 · корпус 2, наб. р. Свияги"),
        // Excel: A14
        lesson(4, 3, "Электроника и схемотехника телекоммуникационных устройств", type: "Лекция", teacher: "Лебедев Остап Юлианович", place: "341"),
        // Excel: A15
        lesson(4, 4, "Электроника и схемотехника телекоммуникационных устройств", type: "Лабораторная", teacher: "Лебедев Остап Юлианович", place: "341"),
        // Excel: A16
        lesson(4, 5, "Информатизация общества", type: "Семинар", teacher: "Беляева Олеся Львовна", place: "2/24а"),
        // Excel: A18
        lesson(5, 2, "Английский язык", type: "", teacher: "Морозова Инна Руслановна", place: "3/316"),
        // Excel: A44
        lesson(5, 3, "Физкультура", type: "Практическое", teacher: "Соколова Олеся Алексеевна", place: ""),
        // Excel: A20
        lesson(5, 4, "Базы данных", type: "Лабораторная", teacher: "Комарова Юлиана Егоровна", place: "503"),
        lesson(6, 2, "Основы военной подготовки", type: "Лекция", teacher: "", place: "Онлайн"),
        // Excel: A22
        lesson(6, 4, "Дифференциальные уравнения", type: "Семинар", teacher: "Зайцева Олеся Денисовна", place: "2/20а"),
        // Excel: A23
        lesson(6, 5, "Дифференциальные уравнения", type: "Семинар", teacher: "Зайцева Олеся Денисовна", place: "2/20а"),
    ]

}

/// Building ~100 days is cheap but runs on every render; remember the last result.
private final class WindowCache: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: ManualPlan?
    private var value: ScheduleWindow?
    func window(for plan: ManualPlan) -> ScheduleWindow {
        lock.lock(); defer { lock.unlock() }
        if let value = value, self.plan == plan { return value }
        let built = ManualSchedule.build(plan)
        self.plan = plan; value = built
        return built
    }
}

/// Imported semester plan, stored next to the cache. Replacing it needs no reinstall.
enum ManualPlanStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var cached: ManualPlan?

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTable", isDirectory: true).appendingPathComponent("manual-plan.json")
    }

    static var imported: ManualPlan? {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loaded = true
            cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ManualPlan.self, from: $0) }
                .flatMap { try? $0.validated() }
        }
        return cached
    }

    /// Validates first; the previous plan stays if the file is wrong.
    @discardableResult
    static func importPlan(_ data: Data) throws -> ManualPlan {
        let plan: ManualPlan
        do { plan = try JSONDecoder().decode(ManualPlan.self, from: data) }
        catch { throw PortalFailure.unrecognized("файл плана (ожидается JSON как manual_schedule.json)") }
        try plan.validated()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: url, options: .atomic)
        lock.lock(); cached = plan; loaded = true; lock.unlock()
        return plan
    }

    static func reset() {
        try? FileManager.default.removeItem(at: url)
        lock.lock(); cached = nil; loaded = true; lock.unlock()
    }

    /// The current plan as a file, a template for the next semester.
    static func exportCurrent() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("manual_schedule.json")
        try encoder.encode(ManualSchedule.plan).write(to: file, options: .atomic)
        return file
    }
}
