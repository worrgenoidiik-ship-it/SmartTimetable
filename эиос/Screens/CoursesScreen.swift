import SwiftUI

// ==========================================
// КУРСЫ: список курсов и действия внутри курса (материалы, тесты, задания)
// ==========================================
@MainActor
struct CoursesTab: View {
    let isChristmasMode: Bool
    var isActive = true
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var network = NetworkManager.shared
    @State private var page: PortalDestination?
    @State private var selectedCourse: Course?
    @State private var showCourseImport = false
    @State private var requestedInitialImport = false
    @State private var showArchive = false

    /// Courses the dashboard showed in its latest import; the rest are from earlier semesters.
    private var split: (current: [Course], archived: [Course]) {
        guard let newest = network.courses.compactMap(\.lastSeen).max() else { return (network.courses, []) }
        let cutoff = newest.addingTimeInterval(-3 * 86_400)
        let current = network.courses.filter { ($0.lastSeen ?? .distantPast) >= cutoff }
        return (current, network.courses.filter { ($0.lastSeen ?? .distantPast) < cutoff })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 15) {
                SyncStatusView()
                Text("Нажмите на курс, чтобы открыть материалы, пройти тест, сдать задание или написать преподавателю.")
                    .font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Загрузить курсы") { showCourseImport = true }.buttonStyle(.bordered)
                    Button("Все курсы в ЭИОС") { page = PortalDestination(title: "Мои курсы", url: PortalConfiguration.coursesURL) }
                        .buttonStyle(.bordered)
                }.tint(Color.themeAccent(isChristmas: isChristmasMode))
                if network.courses.isEmpty {
                    if network.isLoading {
                        ProgressView("Загружаем курсы…")
                    } else {
                        EmptyDataView(symbol: "books.vertical", text: "Список курсов ещё не загружен. Нажмите «Загрузить курсы» или потяните вниз.")
                    }
                }
                ForEach(split.current) { courseRow($0) }
                if !split.archived.isEmpty {
                    DisclosureGroup("Прошлые курсы (\(split.archived.count))", isExpanded: $showArchive) {
                        ForEach(split.archived) { courseRow($0).opacity(0.75) }
                    }.accentColor(.gray).padding(.top, 6)
                }
                if let error = network.errors["courses"] { Text(error).font(.caption).foregroundColor(.orange) }
                UpdatedText(date: network.snapshot.courses?.fetchedAt)
            }.padding()
        }
        .refreshable { showCourseImport = true }
        .sheet(item: $selectedCourse) { CourseDetailScreen(course: $0, isChristmasMode: isChristmasMode) }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
        .sheet(isPresented: $showCourseImport) { CourseImportScreen() }
        .task(id: isActive) {
            // Автозагрузка только если курсов ещё нет: раньше окно всплывало при каждом первом заходе.
            guard isActive, !requestedInitialImport, network.courses.isEmpty else { return }
            requestedInitialImport = true
            showCourseImport = true
        }
    }

    private func courseRow(_ course: Course) -> some View {
        Button {
            AppHapticManager.shared.impact(style: .light)
            selectedCourse = course
        } label: {
            HStack(spacing: 15) {
                Image(systemName: "book.fill").foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                let title = CourseTitle(course.title)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title.subject).font(.headline).foregroundColor(.primary).multilineTextAlignment(.leading)
                    if !title.detailLine.isEmpty {
                        Text(title.detailLine).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(20)
        }.buttonStyle(.plain)
    }
}

/// Действия внутри одного курса. Все ссылки — стандартные страницы Moodle этого курса,
/// они открываются во встроенном браузере с той же сессией ЭИОС.
@MainActor
struct CourseDetailScreen: View {
    let course: Course
    let isChristmasMode: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var network = NetworkManager.shared
    @State private var page: PortalDestination?
    @State private var quiz: PortalDestination?

    /// Сохранённая ссылка ещё раз проверяется: открываем только /course/view.php?id= этого же курса.
    private var courseURL: URL {
        let id = URLComponents(url: course.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        return PortalConfiguration.allowsDataURL(course.url) && course.url.path == "/course/view.php" && id == course.id
            ? course.url : PortalConfiguration.coursesURL
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    PortalLinkRow(symbol: "books.vertical.fill", title: "Материалы курса",
                                  subtitle: "Лекции, файлы, ссылки и все разделы курса", tint: .blue) {
                        open("Курс", courseURL)
                    }
                    PortalLinkRow(symbol: "checklist", title: "Тесты",
                                  subtitle: "Все тесты курса: пройти, продолжить попытку, посмотреть результат", tint: .orange) {
                        open("Тесты", PortalConfiguration.courseQuizzesURL(course.id))
                    }
                    PortalLinkRow(symbol: "paperclip", title: "Задания",
                                  subtitle: "Сроки сдачи, загрузка файлов и ответов, отзывы преподавателя", tint: .purple) {
                        open("Задания", PortalConfiguration.courseAssignmentsURL(course.id))
                    }
                    PortalLinkRow(symbol: "chart.bar.fill", title: "Оценки по курсу",
                                  subtitle: "Баллы за тесты и задания этого курса", tint: .green) {
                        open("Оценки", PortalConfiguration.courseGradesURL(course.id))
                    }
                    NavigationLink {
                        NewChatScreen(isChristmasMode: isChristmasMode, initialQuery: CourseTitle(course.title).teacher ?? "")
                    } label: {
                        PortalLinkRow(symbol: "bubble.left.and.bubble.right.fill", title: "Написать преподавателю",
                                      subtitle: "Чат прямо в приложении; преподаватель найдётся по названию курса", tint: .teal) {}
                            .allowsHitTesting(false)
                    }.buttonStyle(.plain)
                    Text("Ответы в тестах сохраняет сама ЭИОС при переходе между страницами. Чтобы случайно не закрыть тест, окно закрывается только кнопкой «Закрыть».")
                        .font(.caption).foregroundColor(.secondary).padding(.top, 6)
                    contents
                }.padding()
            }
            .background(Color.appBackground)
            .refreshable { await network.loadContents(of: course) }
            .task {
                if (network.contents(of: course)?.fetchedAt ?? .distantPast) < Date().addingTimeInterval(-1_800) {
                    await network.loadContents(of: course)
                }
            }
            .navigationTitle(CourseTitle(course.title).subject).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
        .fullScreenCover(item: $quiz) { QuizScreen(title: $0.title, url: $0.url, isChristmasMode: isChristmasMode) }
    }

    private func open(_ title: String, _ url: URL) { page = PortalDestination(title: title, url: url) }

    private var errorKey: String { "course.\(course.id)" }

    /// Разделы курса, разобранные со страницы /course/view.php (кэшируются для офлайна).
    @ViewBuilder private var contents: some View {
        Text("Содержание курса").font(.title3).bold().padding(.top, 10)
        if network.isLoading(errorKey) { HStack { ProgressView(); Text("Загружаем курс…").font(.caption) } }
        if let error = network.errors[errorKey] { Text(error).font(.caption).foregroundColor(.orange) }
        if let sections = network.contents(of: course)?.value {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title).font(.headline)
                    if !section.summary.isEmpty {
                        Text(section.summary).font(.caption).foregroundColor(.secondary).lineLimit(4)
                    }
                    ForEach(section.activities) { activity in
                        if activity.kind == "label" {
                            Text(activity.name).font(.caption).foregroundColor(.secondary)
                        } else {
                            Button {
                                if let url = activity.url {
                                    // Tests are answered natively; everything else opens in the clean in-app page.
                                    if activity.kind == "quiz" { quiz = PortalDestination(title: activity.name, url: url) }
                                    else { open(activity.kindLabel, url) }
                                }
                            } label: { ActivityRow(activity: activity) }
                                .buttonStyle(.plain).disabled(activity.url == nil)
                        }
                    }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBackground(for: colorScheme)).cornerRadius(18)
            }
            UpdatedText(date: network.contents(of: course)?.fetchedAt)
        } else if !network.isLoading(errorKey) && network.errors[errorKey] == nil {
            Text("Содержание ещё не загружено. Потяните вниз.").font(.caption).foregroundColor(.secondary)
        }
    }
}

@MainActor
private struct ActivityRow: View {
    let activity: CourseActivity
    private var tint: Color {
        switch activity.kind {
        case "quiz": return .orange
        case "assign": return .purple
        case "resource", "folder": return .blue
        default: return .teal
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activity.symbol).foregroundColor(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.name).font(.subheadline).foregroundColor(.primary).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(activity.kindLabel).font(.caption2.bold()).foregroundColor(tint)
                    if !activity.info.isEmpty { Text(activity.info).font(.caption2).foregroundColor(.secondary).lineLimit(2) }
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 2)
    }
}
