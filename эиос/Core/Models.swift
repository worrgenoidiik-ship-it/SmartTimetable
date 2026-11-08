import Foundation
import CryptoKit

struct StudentProfile: Codable, Equatable, Sendable {
    let accountKey: String
    let name: String
    let identityUsesName: Bool
}

struct GradeItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let subject: String
    let type: String
    let grade: String
    let date: String
    let teacher: String
    let semester: String
    var retake: String? = nil

    var teacherNames: [String] {
        teacher.split(separator: "\n").map(String.init)
    }
}

struct ScheduleItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let day: String // yyyy-MM-dd in Europe/Samara, never an alternating-week template.
    let timeStart: String
    let timeEnd: String
    let type: String
    let subject: String
    let teacher: String
    let place: String
    let subgroup: String
    var lessonNumber: Int? = nil // Manual slots retain their real number, including gaps.
    var requiresConfirmation: Bool? = nil // A known conflict is shown, but must not trigger a reminder.
}

struct Course: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let teacher: String
    let url: URL
    // When the dashboard last showed this course; older ones move to «Прошлые курсы».
    var lastSeen: Date? = nil
}

struct PortalNotification: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let message: String
    // The supplied page exposes a relative label, not an absolute timestamp.
    let sourceTimeLabel: String
    let isUnread: Bool
    var observedAt: Date = Date()
}

// MARK: - Generic portal pages (attestation, debts, study plan…)

/// One table as shown on a portal page. Headers may be empty when the site has none.
struct PortalTable: Codable, Equatable, Sendable {
    let caption: String
    let headers: [String]
    let rows: [[String]]
}

struct PortalLink: Codable, Equatable, Sendable, Identifiable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
}

/// The readable content of a portal page's main region, kept for offline viewing.
struct PortalDocument: Codable, Equatable, Sendable {
    let title: String
    let tables: [PortalTable]
    let paragraphs: [String]
    let links: [PortalLink]
}

/// «Последние объявления» from the dashboard news block.
struct NewsItem: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let author: String
    let dateLabel: String
    let url: URL
}

/// One event from calendar/view.php?view=upcoming (quiz closing, assignment due…).
struct DeadlineItem: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let course: String
    let kind: String     // Moodle component, e.g. mod_quiz, mod_assign
    let whenLabel: String // as written on the site
    let due: Date?       // exact time when the site exposes it
    let url: URL?

    var kindLabel: String {
        switch kind {
        case "mod_quiz": return QuizKind.label(for: title)
        case "mod_assign": return "Задание"
        case "mod_forum": return "Форум"
        case "mod_lesson": return "Лекция"
        case "mod_workshop": return "Семинар"
        case "mod_feedback", "mod_questionnaire": return "Анкета"
        case "": return "Событие"
        default: return "Событие курса"
        }
    }
}

/// Many «тесты» in ЭИОС are really «Самостоятельная работа»; the label follows the name.
enum QuizKind {
    static func label(for name: String) -> String {
        PortalParser.normalized(name).contains("самостоят") ? "Самостоятельная работа" : "Тест"
    }
}

/// Course page structure: sections with activities (tests, assignments, files…).
struct CourseActivity: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: String // Moodle module name: quiz, assign, resource, url, forum, page, folder…
    let info: String // dates / restrictions shown under the activity
    let url: URL?

    var kindLabel: String {
        switch kind {
        case "quiz": return QuizKind.label(for: name)
        case "assign": return "Задание"
        case "resource": return "Файл"
        case "folder": return "Папка"
        case "url": return "Ссылка"
        case "page", "book": return "Материал"
        case "forum": return "Форум"
        case "label": return "Пояснение"
        case "lesson": return "Лекция"
        case "feedback", "questionnaire", "choice": return "Опрос"
        default: return "Элемент курса"
        }
    }

    var symbol: String {
        switch kind {
        case "quiz": return "checklist"
        case "assign": return "paperclip"
        case "resource": return "doc.fill"
        case "folder": return "folder.fill"
        case "url": return "link"
        case "page", "book", "lesson": return "text.book.closed.fill"
        case "forum": return "bubble.left.and.bubble.right.fill"
        case "feedback", "questionnaire", "choice": return "list.bullet.clipboard"
        default: return "square.grid.2x2"
        }
    }
}

struct CourseSection: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let activities: [CourseActivity]
}

struct CachedSection<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value
    let fetchedAt: Date
    let sources: [URL]
}

enum ScheduleOrigin: String, Codable, Equatable, Sendable {
    case portal, manual
}

struct ScheduleWindow: Codable, Equatable, Sendable {
    // Explicit dates from the selected source; no implied repeating or missing days.
    // Keep the Codable fields unchanged so existing snapshots remain readable.
    let days: [String]
    let items: [ScheduleItem]
    // Optional additions keep pre-manual cache files readable.
    var origin: ScheduleOrigin? = nil
    var dayNotes: [String: String]? = nil
    var cancelledDays: [String]? = nil

    var notificationItems: [ScheduleItem] {
        items.filter { !(cancelledDays ?? []).contains($0.day) && $0.requiresConfirmation != true }
    }
}

enum ScheduleSource {
    /// The window shown for a mode. Auto: days covered by the group's plan come from the plan,
    /// all other days (another semester, holidays after it) come from the portal history.
    /// The group's plan with full teacher names and rooms filled in from courses and the portal.
    static func enrichedPlan(of snapshot: PortalSnapshot) -> CachedSection<ScheduleWindow>? {
        guard let plan = snapshot.schedule else { return nil }
        let enriched = ScheduleEnricher.enrich(plan.value, courses: snapshot.courses?.value ?? [],
                                               portal: snapshot.portalSchedule?.value)
        return CachedSection(value: enriched, fetchedAt: plan.fetchedAt, sources: plan.sources)
    }

    static func window(of snapshot: PortalSnapshot, mode: ScheduleMode) -> CachedSection<ScheduleWindow>? {
        switch mode {
        case .manual: return enrichedPlan(of: snapshot)
        case .portal: return snapshot.portalSchedule
        case .auto:
            // Another group's plan is never shown: those students get the portal schedule.
            guard let manual = enrichedPlan(of: snapshot), StudentGroup.planApplies(to: snapshot) else { return snapshot.portalSchedule }
            guard let portal = snapshot.portalSchedule else { return manual }
            let planned = Set(manual.value.days)
            let days = planned.union(portal.value.days).sorted()
            let items = (manual.value.items + portal.value.items.filter { !planned.contains($0.day) })
                .sorted { ($0.day, $0.timeStart, $0.id) < ($1.day, $1.timeStart, $1.id) }
            let notes = (portal.value.dayNotes ?? [:]).merging(manual.value.dayNotes ?? [:]) { _, plan in plan }
            let window = ScheduleWindow(days: days, items: items, origin: nil, dayNotes: notes,
                                        cancelledDays: manual.value.cancelledDays)
            return CachedSection(value: window, fetchedAt: max(manual.fetchedAt, portal.fetchedAt),
                                 sources: manual.sources + portal.sources)
        }
    }

    /// Whether a given day is shown from the group's plan (for labels in the UI).
    static func isPlanned(_ day: String, in snapshot: PortalSnapshot, mode: ScheduleMode) -> Bool {
        switch mode {
        case .manual: return true
        case .portal: return false
        case .auto: return StudentGroup.planApplies(to: snapshot) && (snapshot.schedule?.value.days.contains(day) ?? false)
        }
    }
}

struct PortalSnapshot: Codable, Sendable {
    var schemaVersion = 1
    var profile: StudentProfile?
    var grades: CachedSection<[GradeItem]>?
    var attestations: CachedSection<[GradeItem]>?
    var schedule: CachedSection<ScheduleWindow>?
    var portalSchedule: CachedSection<ScheduleWindow>? // Observed portal dates, separate from the manual plan.
    var courses: CachedSection<[Course]>?
    var notifications: CachedSection<[PortalNotification]>? // Optional for old cache compatibility.
    // Added in 1.1; all optional so older cache files keep decoding.
    var news: CachedSection<[NewsItem]>?
    var deadlines: CachedSection<[DeadlineItem]>?
    /// Past-due work that still needs an action (Moodle drops submitted items itself).
    var overdue: CachedSection<[DeadlineItem]>?
    var pages: [String: CachedSection<PortalDocument>]?          // keyed by PortalPageKind.rawValue
    var courseContents: [String: CachedSection<[CourseSection]>]? // keyed by course ID
    var nextRefreshAt: Date?
}

enum SessionState: Equatable {
    case unchecked, active, offline, needsLogin
}

enum PortalFailure: LocalizedError {
    case loginRequired
    case httpStatus(Int)
    case unrecognized(String)
    case incompleteSchedule
    case invalidURL
    case invalidResponse
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired: return "Сессия завершена. Войдите в ЭИОС ещё раз. Сохранённые данные доступны."
        case .httpStatus(let code): return "ЭИОС вернула HTTP \(code). Сохранённые данные не изменены."
        case .unrecognized(let section): return "Не удалось надёжно распознать: \(section). Сохранённые данные не изменены."
        case .incompleteSchedule: return "ЭИОС вернула пустое, повреждённое или противоречивое расписание. Предыдущие данные сохранены."
        case .invalidURL: return "Адрес страницы не разрешён в настройках источника."
        case .invalidResponse: return "Вместо страницы ЭИОС получен неподходящий ответ."
        case .storage(let message): return "Не удалось сохранить данные: \(message)"
        }
    }
}

enum StableID {
    static func make(_ parts: [String]) -> String {
        // JSON prevents collisions caused by a separator inside source text.
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CampusDate {
    // Calendar and DateFormatter are expensive to create; screens call these hundreds of
    // times per render, so both are built once. DateFormatter is thread-safe for use.
    static let calendar: Calendar = {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Europe/Samara")!
        result.firstWeekday = 2
        return result
    }()

    private static let formattersLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func formatter(_ format: String) -> DateFormatter {
        formattersLock.lock(); defer { formattersLock.unlock() }
        if let cached = formatters[format] { return cached }
        let result = DateFormatter()
        result.calendar = calendar
        result.timeZone = calendar.timeZone
        result.locale = Locale(identifier: "ru_RU")
        result.dateFormat = format
        result.isLenient = false
        formatters[format] = result
        return result
    }

    static func key(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }

    static func start(of item: ScheduleItem) -> Date? {
        guard item.timeStart.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else { return nil }
        return formatter("yyyy-MM-dd HH:mm").date(from: "\(item.day) \(item.timeStart)")
    }
}
