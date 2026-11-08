import SwiftUI

// ==========================================
// СООБЩЕНИЯ: чаты ЭИОС прямо в приложении, без открытия сайта
// ==========================================
@MainActor
struct MessagesScreen: View {
    let isChristmasMode: Bool
    @ObservedObject private var network = NetworkManager.shared
    @ObservedObject private var messenger = Messenger.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: PortalDestination?
    @State private var showInbox = false
    @State private var pickCourse = false
    @State private var path = NavigationPath()
    @State private var showQuestion = false
    @State private var showAllChats = false

    private var accent: Color { Color.themeAccent(isChristmas: isChristmasMode) }

    private enum Route: Hashable {
        case conversation(Int, String)
        case newChat(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SyncStatusView()
                    HStack(spacing: 10) {
                        actionButton("square.and.pencil", "Новое сообщение") { path.append(Route.newChat("")) }
                        actionButton("person.crop.circle.badge.questionmark", "Преподавателю") { pickCourse = true }
                    }

                    HStack {
                        Text("Чаты").font(.title3).bold()
                        if messenger.loading { ProgressView().padding(.leading, 4) }
                        Spacer()
                    }.padding(.top, 6)
                    if let error = messenger.error {
                        Text(error).font(.caption).foregroundColor(.orange)
                        Button("Открыть сообщения на сайте") {
                            page = PortalDestination(title: "Сообщения", url: PortalConfiguration.messagesURL)
                        }.font(.caption)
                    }
                    if messenger.conversations.isEmpty && !messenger.loading && messenger.error == nil {
                        EmptyDataView(symbol: "bubble.left.and.bubble.right", text: "Чатов пока нет. Нажмите «Новое сообщение», чтобы написать преподавателю или одногруппнику.")
                    }
                    // The latest chats first; the rest behind «Показать все».
                    ForEach(showAllChats ? messenger.conversations : Array(messenger.conversations.prefix(5))) { conversation in
                        Button { path.append(Route.conversation(conversation.id, conversation.title)) } label: {
                            ConversationRow(conversation: conversation, myID: messenger.myID, tint: accent)
                        }.buttonStyle(.plain)
                    }

                    if messenger.conversations.count > 5 {
                        Button {
                            withAnimation { showAllChats.toggle() }
                        } label: {
                            Label(showAllChats ? "Свернуть" : "Показать все (\(messenger.conversations.count))",
                                  systemImage: showAllChats ? "chevron.up" : "chevron.down")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                        }.foregroundColor(accent).padding(.vertical, 4)
                    }

                    HStack {
                        Text("Уведомления").font(.title3).bold()
                        if network.unreadNotificationCount > 0 {
                            Text("\(network.unreadNotificationCount)").font(.caption.bold()).foregroundColor(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Color.red, in: Capsule())
                        }
                        Spacer()
                        Button("Все") { showInbox = true }.foregroundColor(accent)
                    }.padding(.top, 8)
                    if network.notifications.isEmpty {
                        Text("Уведомления ещё не загружены. Нажмите «Все».").font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(network.notifications.prefix(3)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(item.isUnread ? accent : Color.clear).frame(width: 8, height: 8).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.message).font(.subheadline).lineLimit(3)
                                Text(item.sourceTimeLabel).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(16)
                    }
                    PortalLinkRow(symbol: "questionmark.bubble.fill", title: "Задать вопрос в деканат",
                                  subtitle: "Официальная форма обращения ЭИОС", tint: .indigo) {
                        showQuestion = true
                    }.padding(.top, 6)
                }.padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Сообщения")
            .refreshable { await messenger.loadConversations() }
            .task { await messenger.loadConversations() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .conversation(let id, let title):
                    ChatScreen(title: title, isChristmasMode: isChristmasMode, conversationID: id)
                        .onDisappear { Task { await messenger.loadConversations() } }
                case .newChat(let query):
                    NewChatScreen(isChristmasMode: isChristmasMode, initialQuery: query)
                }
            }
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
        .sheet(isPresented: $showInbox) { PortalInboxScreen() }
        .sheet(isPresented: $showQuestion) { QuestionScreen(isChristmasMode: isChristmasMode) }
        .sheet(isPresented: $pickCourse) {
            CoursePickerScreen(isChristmasMode: isChristmasMode) { course in
                // The teacher's name from the course title pre-fills the people search.
                path.append(Route.newChat(CourseTitle(course.title).teacher ?? ""))
            }
        }
    }

    private func actionButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: { AppHapticManager.shared.impact(style: .light); action() }) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundColor(accent).frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.cardBackground(for: colorScheme)).cornerRadius(16)
        }.buttonStyle(.plain)
    }
}

// ==========================================
// ЭИОС: новости, дедлайны и все разделы портала
// ==========================================
@MainActor
struct ServicesScreen: View {
    let isChristmasMode: Bool
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: PortalDestination?
    @State private var nativePage: PortalPageKind?
    @State private var showNews = false
    @State private var showDeadlines = false
    @State private var showOverdue = false
    @State private var showQuestion = false
    @State private var showInquiry = false

    private var accent: Color { Color.themeAccent(isChristmas: isChristmasMode) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SyncStatusView()
                    deadlinesCard
                    overdueCard
                    newsCard

                    group("Учёба")
                    native(.attestation, tint: .green)
                    native(.debts, tint: .red)
                    native(.studyPlan, tint: .indigo)
                    link("chart.bar.doc.horizontal.fill", "Оценки по курсам", "Итоговые баллы по каждому курсу", .mint,
                         "Оценки", PortalConfiguration.gradeOverviewURL)
                    link("calendar", "Календарь", "Все события курсов по месяцам", .red,
                         "Календарь", PortalConfiguration.calendarURL)
                    link("graduationcap.fill", "Мои курсы", "Главная страница ЭИОС с карточками курсов", .blue,
                         "Мои курсы", PortalConfiguration.coursesURL)

                    group("Заявления и связь")
                    PortalLinkRow(symbol: "doc.badge.plus", title: "Заказ справок",
                                  subtitle: "Справка об обучении, о стипендии, 2-НДФЛ и другие", tint: .orange) { showInquiry = true }
                    PortalLinkRow(symbol: "questionmark.bubble.fill", title: "Задать вопрос",
                                  subtitle: "Обращение в деканат и службы университета", tint: .indigo) { showQuestion = true }
                    native(.notificationCenter, tint: .teal)

                    group("Выбор и анкеты")
                    link("square.stack.3d.up.fill", "Курсы по выбору", "Запись на университетские курсы по выбору", .orange,
                         "Курсы по выбору", PortalConfiguration.electiveCoursesURL)
                    link("globe", "Открытые онлайн-курсы", "Массовые открытые онлайн-курсы", .teal,
                         "Открытые курсы", PortalConfiguration.openCoursesURL)
                    link("text.bubble.fill", "Анкеты", "Опросы и анкетирование студентов", .pink,
                         "Анкеты", PortalConfiguration.questionnairesURL)

                    group("Прочее")
                    link("doc.text.fill", "Работа с ВКР", "Выпускная квалификационная работа", .brown,
                         "ВКР", PortalConfiguration.thesisURL)
                    link("briefcase.fill", "Портфолио", "Резюме и артефакты портфолио", .purple,
                         "Портфолио", PortalConfiguration.portfolioURL)
                    link("brain.head.profile", "Психологический профиль", "Тестирование психологической службы", .cyan,
                         "Психологический профиль", PortalConfiguration.psychologyURL)
                    link("books.vertical.fill", "Доступ к ЭИ", "Электронные библиотеки и ресурсы", .brown,
                         "Доступ к ЭИ", PortalConfiguration.libraryAccessURL)
                    link("folder.fill", "Личные файлы", "Файлы, загруженные в ЭИОС", .gray,
                         "Личные файлы", PortalConfiguration.personalFilesURL)
                    link("person.text.rectangle.fill", "Профиль ЭИОС", "Личные данные на портале", .gray,
                         "Профиль", PortalConfiguration.profileURL)
                }.padding()
            }
            .background(Color.appBackground)
            .refreshable { _ = await network.refresh(force: true) }
            .navigationTitle("ЭИОС")
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
        .sheet(item: $nativePage) { PortalDocumentScreen(kind: $0) }
        .sheet(isPresented: $showNews) { NewsScreen() }
        .sheet(isPresented: $showDeadlines) { DeadlinesScreen() }
        .sheet(isPresented: $showOverdue) { DeadlinesScreen(overdue: true) }
        .sheet(isPresented: $showQuestion) { QuestionScreen(isChristmasMode: isChristmasMode) }
        .sheet(isPresented: $showInquiry) { InquiryScreen(isChristmasMode: isChristmasMode) }
    }

    private var deadlinesCard: some View {
        card(title: "Ближайшие сроки", symbol: "clock.badge.exclamationmark.fill", tint: .orange, action: { showDeadlines = true }) {
            let items = network.upcomingDeadlines.prefix(3)
            if items.isEmpty {
                Text(network.snapshot.deadlines == nil ? "Нажмите, чтобы загрузить календарь." : "Сроков в ближайшее время нет.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(items)) { DeadlineRow(item: $0) }
        }
    }

    /// Past-due labs, assignments and tests that are still not submitted.
    private var overdueCard: some View {
        card(title: network.overdue.isEmpty ? "Просроченные работы" : "Просроченные работы · \(network.overdue.count)",
             symbol: "exclamationmark.circle.fill", tint: .red, action: { showOverdue = true }) {
            if network.overdue.isEmpty {
                Text(network.snapshot.overdue == nil ? "Появятся после обновления данных." : "Всё сдано — просроченных работ нет.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(network.overdue.prefix(3))) { DeadlineRow(item: $0) }
        }
    }

    private var newsCard: some View {
        card(title: "Новости УлГУ", symbol: "newspaper.fill", tint: accent, action: { showNews = true }) {
            if network.news.isEmpty {
                Text("Объявления появятся после обновления данных.").font(.caption).foregroundColor(.secondary)
            }
            ForEach(network.news.prefix(3)) { NewsRow(item: $0) }
        }
    }

    private func card<Content: View>(title: String, symbol: String, tint: Color, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(title, systemImage: symbol).font(.headline).foregroundColor(tint)
                    Spacer()
                    Text("Все").font(.subheadline).foregroundColor(tint)
                }
                content()
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground(for: colorScheme)).cornerRadius(18)
        }.buttonStyle(.plain)
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.bold()).foregroundColor(.secondary).padding(.top, 8)
    }

    private func native(_ kind: PortalPageKind, tint: Color) -> some View {
        PortalLinkRow(symbol: kind.symbol, title: kind.title, subtitle: kind.subtitle, tint: tint) { nativePage = kind }
    }

    private func link(_ symbol: String, _ title: String, _ subtitle: String, _ tint: Color,
                      _ pageTitle: String, _ url: URL) -> some View {
        PortalLinkRow(symbol: symbol, title: title, subtitle: subtitle, tint: tint) {
            page = PortalDestination(title: pageTitle, url: url)
        }
    }
}
