import Foundation

// academic_progress.php and its semester/teacher markup were checked against
// the supplied grades.html. Live networking and /my/ still need device validation.
enum PortalConfiguration {
    static let baseURL = URL(string: "https://portal.ulsu.ru")!
    static let loginURL = baseURL.appendingPathComponent("login/index.php")
    static let dashboardURL = baseURL.appendingPathComponent("my/")
    static let coursesURL = dashboardURL
    // Linked by the notification menu in the supplied grades.html.
    static let notificationsURL = baseURL.appendingPathComponent("message/output/popup/notifications.php")
    static let gradesURL = baseURL.appendingPathComponent("blocks/buttons/academic_progress.php")
    static let sessionProbeURL = gradesURL
    static let gradesTable = GradeTableMapping(selector: "table.academic-table")
    // The dashboard widget returns its available dates in one GET, with no parameters.
    static let scheduleURL = baseURL.appendingPathComponent("blocks/schedule/ajax_schedule.php")
    // Like the Android version, the source is a user setting. The manual plan stays the
    // default; the portal history is always fetched and stored separately, so switching
    // never loses either source.
    static let scheduleSourceKey = "smarttable.scheduleSource"
    static let portalScheduleKey = "smarttable.portalSchedule" // 1.1 on/off switch, read once for migration
    static var scheduleMode: ScheduleMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: scheduleSourceKey), let mode = ScheduleMode(rawValue: raw) { return mode }
        if defaults.object(forKey: portalScheduleKey) as? Bool == true { return .portal }
        // Auto: the group's plan while it lasts, then the portal — a new semester needs no update.
        return .auto
    }

    // Standard Moodle pages linked from the portal menu in version2.html / grades.html.
    // They open in the in-app browser with the shared session; nothing is posted natively.
    static let messagesURL = baseURL.appendingPathComponent("message/index.php")
    static let calendarURL = moodleURL("calendar/view.php", ["view": "upcoming"])
    static let gradeOverviewURL = baseURL.appendingPathComponent("grade/report/overview/index.php")
    static let questionnairesURL = baseURL.appendingPathComponent("blocks/questionnaire/user_questionnaires.php")
    static let electiveCoursesURL = baseURL.appendingPathComponent("blocks/elective_courses/list_elective_courses.php")
    static let openCoursesURL = baseURL.appendingPathComponent("blocks/online_eduv2/list_open_courses.php")
    static let profileURL = baseURL.appendingPathComponent("user/profile.php")
    // Further items of the portal menu found in version2.html (01.11.2026).
    static let newsForumURL = moodleURL("mod/forum/view.php", ["f": "65"])
    static let inquiryURL = baseURL.appendingPathComponent("CDO/inquiry/index.php")         // Заказ справок
    static let questionURL = baseURL.appendingPathComponent("CDO/questionizer.php")         // Задать вопрос
    static let thesisURL = baseURL.appendingPathComponent("local/cdo_vkr/index.php")        // Работа с ВКР
    static let portfolioURL = moodleURL("blocks/exaport/resume.php", ["courseid": "1"])     // Портфолио
    static let psychologyURL = baseURL.appendingPathComponent("ulsu/psychpic/rules.php")    // Психологический профиль
    static let personalFilesURL = baseURL.appendingPathComponent("user/files.php")
    static let libraryAccessURL = baseURL.appendingPathComponent("blocks/ulsu_redact/ei.php") // Доступ к ЭИ

    // Core Moodle course indexes: every quiz/assignment of one course, its grades and participants.
    static func courseQuizzesURL(_ courseID: String) -> URL { moodleURL("mod/quiz/index.php", ["id": courseID]) }
    static func courseAssignmentsURL(_ courseID: String) -> URL { moodleURL("mod/assign/index.php", ["id": courseID]) }
    static func courseGradesURL(_ courseID: String) -> URL { moodleURL("grade/report/user/index.php", ["id": courseID]) }
    static func courseParticipantsURL(_ courseID: String) -> URL { moodleURL("user/index.php", ["id": courseID]) }

    private static func moodleURL(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    // A separate attestation source has not been supplied yet.
    static let attestationURL: URL? = nil
    static let attestationTable: GradeTableMapping? = nil

    static let refreshIdentifier = "ru.smarttable.portal.refresh"
    static let keepAliveIdentifier = "ru.smarttable.portal.keepalive"
    static let autoRefreshKey = "smarttable.autoRefresh"
    static let nextRefreshKey = "smarttable.nextRefresh"

    static func randomRefreshDelay() -> TimeInterval { TimeInterval(Int.random(in: 30...60) * 60) }

    static func allowsDataURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "portal.ulsu.ru"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func allowsBrowserURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil else { return false }
        return (host == "ulsu.ru" || host.hasSuffix(".ulsu.ru")) && [443, 8443].contains(url.port ?? 443)
    }

    static func isUniversityCookieDomain(_ domain: String) -> Bool {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "ulsu.ru" || host.hasSuffix(".ulsu.ru")
    }

    static func isAuthenticationURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return url.host?.lowercased() != baseURL.host || path.contains("/login/")
            || path.hasSuffix("/wait.php") || path.contains("/login-actions/")
    }
}

/// Read-only portal pages shown natively with the generic document parser.
/// Interactive pages (справки, вопрос) stay in the in-app browser.
enum PortalPageKind: String, CaseIterable, Identifiable, Sendable {
    case attestation, debts, studyPlan, notificationCenter

    var id: String { rawValue }
    var errorKey: String { "page." + rawValue }

    var url: URL {
        let base = PortalConfiguration.baseURL
        switch self {
        case .attestation: return base.appendingPathComponent("CDO/academic_progress_inside.php")
        case .debts: return base.appendingPathComponent("blocks/buttons/debts.php")
        case .studyPlan: return base.appendingPathComponent("CDO/eduplan.php")
        case .notificationCenter: return base.appendingPathComponent("blocks/cdo_notif_center/messages.php")
        }
    }

    var title: String {
        switch self {
        case .attestation: return "Текущая успеваемость"
        case .debts: return "Задолженности"
        case .studyPlan: return "Учебный план"
        case .notificationCenter: return "Мои уведомления"
        }
    }

    var subtitle: String {
        switch self {
        case .attestation: return "Аттестация и текущие баллы семестра"
        case .debts: return "Официальный список задолженностей"
        case .studyPlan: return "Дисциплины, часы и формы контроля по семестрам"
        case .notificationCenter: return "Уведомления от университета"
        }
    }

    var symbol: String {
        switch self {
        case .attestation: return "chart.line.uptrend.xyaxis"
        case .debts: return "exclamationmark.triangle.fill"
        case .studyPlan: return "list.number"
        case .notificationCenter: return "envelope.badge.fill"
        }
    }

    /// Fetched by the regular refresh; the others are loaded when opened.
    var refreshesAutomatically: Bool { self == .attestation || self == .debts }
}

enum ScheduleMode: String, CaseIterable, Equatable, Sendable {
    case auto, manual, portal

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .manual: return "План группы"
        case .portal: return "Из ЭИОС"
        }
    }
}

struct GradeTableMapping: Sendable {
    let selector: String
    var emptySelector: String? = nil // Only a confirmed site marker permits an empty result.
    var subjectHeaders = ["дисциплина", "наименование дисциплины", "предмет"]
    var typeHeaders = ["вид контроля", "форма контроля", "тип контроля"]
    var gradeHeaders = ["отметка", "оценка", "результат", "итоговая оценка"]
    var dateHeaders = ["дата", "дата сдачи", "дата аттестации"]
    var teacherHeaders = ["преподаватель", "фио преподавателя", "экзаменатор"]
    var semesterHeaders = ["семестр", "период"]
    var retakeHeaders = ["пересдача"]
}
