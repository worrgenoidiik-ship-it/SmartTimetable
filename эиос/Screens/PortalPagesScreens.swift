import SwiftUI

// ==========================================
// Нативный просмотр страниц ЭИОС: аттестация, задолженности, учебный план…
// Данные берутся парсером со страницы сайта и сохраняются для работы без сети.
// ==========================================

/// Содержимое страницы без собственной навигации — встраивается и в экран, и в профиль.
@MainActor
struct PortalDocumentContent: View {
    let kind: PortalPageKind
    var maxRows = Int.max
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: PortalDestination?
    @State private var selectedTable: Int?

    private var section: CachedSection<PortalDocument>? { network.page(kind) }

    /// «N семестр» matching the current semester (from the group's enrolment year), else the last.
    private func defaultTable(_ captions: [String]) -> Int {
        if let current = StudentGroup.currentSemester(group: network.studentGroup),
           let index = captions.firstIndex(where: { $0.hasPrefix("\(current) ") }) { return index }
        return max(captions.count - 1, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if network.isLoading(kind.errorKey) {
                HStack { ProgressView(); Text("Загружаем из ЭИОС…").font(.caption) }
            }
            if let document = section?.value {
                let captions = document.tables.map(\.caption)
                if document.tables.count > 1 && !captions.contains("") {
                    // One semester at a time; the current one is chosen first.
                    let index = min(selectedTable ?? defaultTable(captions), document.tables.count - 1)
                    Picker("Семестр", selection: Binding(get: { index }, set: { selectedTable = $0 })) {
                        ForEach(Array(captions.enumerated()), id: \.offset) { offset, caption in Text(caption).tag(offset) }
                    }.pickerStyle(.menu)
                    PortalTableView(table: document.tables[index], maxRows: maxRows, showsCaption: false)
                } else {
                    ForEach(Array(document.tables.enumerated()), id: \.offset) { _, table in
                        PortalTableView(table: table, maxRows: maxRows)
                    }
                }
                if document.tables.isEmpty && document.paragraphs.count <= 2 {
                    // A short notice such as «Текущая успеваемость не найдена!» — not an error.
                    EmptyDataView(symbol: "tray", text: document.paragraphs.joined(separator: "\n"))
                } else {
                    ForEach(Array(document.paragraphs.prefix(maxRows == .max ? 200 : 6).enumerated()), id: \.offset) { _, text in
                        Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if maxRows == .max && !document.links.isEmpty {
                    Text("Ссылки на странице").font(.headline).padding(.top, 6)
                    ForEach(document.links.prefix(40)) { link in
                        Button { page = PortalDestination(title: link.title, url: link.url) } label: {
                            Label(link.title, systemImage: "arrow.up.right.square").font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else if !network.isLoading(kind.errorKey) && network.errors[kind.errorKey] == nil {
                Text("Данные ещё не загружены.").foregroundColor(.secondary)
            }
            if let error = network.errors[kind.errorKey] {
                Text(error).font(.caption).foregroundColor(.orange)
                Text("Нажмите «Открыть на сайте»: после загрузки страницы приложение само заберёт из неё данные и покажет их здесь.")
                    .font(.caption).foregroundColor(.secondary)
            }
            UpdatedText(date: section?.fetchedAt)
            Button("Открыть «\(kind.title)» на сайте") { page = PortalDestination(title: kind.title, url: kind.url) }
                .font(.callout)
        }
        .task {
            // Сначала показывается кэш; свежие данные подгружаются, если им больше 30 минут.
            if (section?.fetchedAt ?? .distantPast) < Date().addingTimeInterval(-1_800) { await network.loadPage(kind) }
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
    }
}

@MainActor
struct PortalDocumentScreen: View {
    let kind: PortalPageKind
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind.subtitle).font(.caption).foregroundColor(.secondary)
                    PortalDocumentContent(kind: kind)
                }.padding()
            }
            .background(Color.appBackground)
            .refreshable { await network.loadPage(kind) }
            .navigationTitle(network.page(kind)?.value.title.isEmpty == false ? network.page(kind)!.value.title : kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

/// Таблица сайта в виде карточек: первая колонка — заголовок, остальные — «поле: значение».
@MainActor
struct PortalTableView: View {
    let table: PortalTable
    var maxRows = Int.max
    var showsCaption = true
    @Environment(\.colorScheme) private var colorScheme

    /// The column that names the row: «Наименование дисциплины», «Дисциплина»… else the first
    /// column that is not just a running number.
    private var titleColumn: Int {
        let names = table.headers.map(PortalParser.normalized)
        if let index = names.firstIndex(where: { name in ["наименование", "дисциплин", "предмет", "название"].contains { name.contains($0) } }) {
            return index
        }
        let width = table.rows.map(\.count).max() ?? 0
        return (0..<width).first { column in
            !table.rows.allSatisfy { row in column >= row.count || row[column].allSatisfy(\.isNumber) }
        } ?? 0
    }

    private func hidden(_ column: Int) -> Bool {
        guard column < table.headers.count else { return false }
        let name = PortalParser.normalized(table.headers[column])
        return name == "№" || name == "№ п/п" || name == "n" || name == "файлы"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsCaption && !table.caption.isEmpty { Text(table.caption).font(.headline) }
            ForEach(Array(table.rows.prefix(maxRows).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    let pairs = fields(row)
                    if let first = pairs.first {
                        Text(first.value).font(.subheadline.weight(.semibold))
                    }
                    ForEach(Array(pairs.dropFirst().enumerated()), id: \.offset) { _, pair in
                        if pair.label.isEmpty {
                            Text(pair.value).font(.caption).foregroundColor(.secondary)
                        } else {
                            HStack(alignment: .top) {
                                Text(pair.label).font(.caption).foregroundColor(.secondary)
                                Spacer(minLength: 8)
                                Text(pair.value).font(.caption.weight(.medium)).multilineTextAlignment(.trailing)
                                    .foregroundColor(GradeStatus.of(pair.value) == .failed ? .red : .primary)
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBackground(for: colorScheme)).cornerRadius(14)
            }
            if table.rows.count > maxRows {
                Text("Ещё строк: \(table.rows.count - maxRows)").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func fields(_ row: [String]) -> [(label: String, value: String)] {
        let title = titleColumn
        let ordered = [title] + row.indices.filter { $0 != title }
        return ordered.compactMap { index in
            guard index < row.count, !row[index].isEmpty, !hidden(index) else { return nil }
            let label = index < table.headers.count ? table.headers[index] : ""
            return (label, row[index])
        }
    }
}

// ==========================================
// НОВОСТИ (блок «Последние объявления» на главной ЭИОС)
// ==========================================
@MainActor
struct NewsScreen: View {
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var page: PortalDestination?

    var body: some View {
        NavigationStack {
            List {
                if network.news.isEmpty {
                    Text("Объявления ещё не загружены. Потяните вниз, чтобы обновить.").foregroundColor(.secondary)
                }
                ForEach(network.news) { item in
                    Button { page = PortalDestination(title: "Объявление", url: item.url) } label: {
                        NewsRow(item: item)
                    }.buttonStyle(.plain)
                }
                Section {
                    UpdatedText(date: network.snapshot.news?.fetchedAt)
                    Button("Все объявления на сайте") { page = PortalDestination(title: "Новости", url: PortalConfiguration.newsForumURL) }
                }
            }
            .refreshable { _ = await network.refresh(force: true) }
            .navigationTitle("Новости УлГУ")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
    }
}

@MainActor
struct NewsRow: View {
    let item: NewsItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
            Text([item.dateLabel, item.author].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }
}

// ==========================================
// ДЕДЛАЙНЫ (календарь ЭИОС: предстоящие события)
// ==========================================
@MainActor
struct DeadlinesScreen: View {
    /// true: «Просроченные работы» — past due and still not submitted.
    var overdue = false
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var page: PortalDestination?
    private var items: [DeadlineItem] { overdue ? network.overdue : network.deadlines }
    @State private var quiz: PortalDestination?

    var body: some View {
        NavigationStack {
            List {
                if network.isLoading("deadlines") { HStack { ProgressView(); Text("Загружаем календарь…") } }
                if items.isEmpty && !network.isLoading("deadlines") {
                    Text(overdue ? (network.snapshot.overdue == nil ? "Данные ещё не загружены." : "Просроченных работ нет — всё сдано 🎉")
                                 : (network.snapshot.deadlines == nil ? "Календарь ещё не загружен." : "Ближайших сроков нет."))
                        .foregroundColor(.secondary)
                }
                if overdue && !items.isEmpty {
                    Text("Срок прошёл, а работа ещё не сдана. Многие преподаватели принимают и после срока — уточни в курсе.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(items) { item in
                    Button {
                        if item.kind == "mod_quiz", let url = item.url { quiz = PortalDestination(title: item.title, url: url) }
                        else { page = PortalDestination(title: item.kindLabel, url: item.url ?? PortalConfiguration.calendarURL) }
                    } label: { DeadlineRow(item: item) }.buttonStyle(.plain)
                }
                Section {
                    if let error = network.errors[overdue ? "overdue" : "deadlines"] { Text(error).font(.caption).foregroundColor(.orange) }
                    UpdatedText(date: overdue ? network.snapshot.overdue?.fetchedAt : network.snapshot.deadlines?.fetchedAt)
                    Text("Напоминания приходят за сутки и за 3 часа до срока, если включены в настройках.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Календарь на сайте") { page = PortalDestination(title: "Календарь", url: PortalConfiguration.calendarURL) }
                }
            }
            .refreshable { await network.loadDeadlines() }
            .task { await network.loadDeadlines() }
            .navigationTitle(overdue ? "Просроченные работы" : "Дедлайны")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
        .fullScreenCover(item: $quiz) { QuizScreen(title: $0.title, url: $0.url, isChristmasMode: false) }
    }
}

@MainActor
struct DeadlineRow: View {
    let item: DeadlineItem
    private var urgent: Bool { (item.due ?? .distantFuture) < Date().addingTimeInterval(86_400) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == "mod_quiz" ? "checklist" : (item.kind == "mod_assign" ? "paperclip" : "calendar"))
                .foregroundColor(urgent ? .red : .orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                if !item.course.isEmpty { Text(item.course).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                HStack(spacing: 6) {
                    Text(item.kindLabel).font(.caption2.bold()).foregroundColor(.orange)
                    if let due = item.due {
                        Text(CampusDate.formatter("d MMM, HH:mm").string(from: due)).font(.caption2)
                        if due < Date() {
                            Text("просрочено").font(.caption2.bold()).foregroundColor(.red)
                        } else {
                            Text(due, style: .relative).font(.caption2).foregroundColor(urgent ? .red : .secondary)
                        }
                    } else if !item.whenLabel.isEmpty {
                        Text(item.whenLabel).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4)
    }
}

// ==========================================
// ЗАДАТЬ ВОПРОС — нативная форма вместо страницы CDO/questionizer.php
// ==========================================
@MainActor
struct QuestionScreen: View {
    let isChristmasMode: Bool
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var form: QuestionForm?
    @State private var category = ""
    @State private var subject = ""
    @State private var message = ""
    @State private var email = ""
    @State private var error: String?
    @State private var sending = false
    @State private var sent = false
    @State private var page: PortalDestination?

    private var canSend: Bool {
        !sending && !category.isEmpty && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && email.contains("@")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let form = form {
                    Section("Раздел") {
                        Picker("Раздел", selection: $category) {
                            ForEach(form.categories) { Text($0.title).tag($0.id) }
                        }.pickerStyle(.inline).labelsHidden()
                    }
                    Section("Тема") { TextField("Коротко о чём вопрос", text: $subject) }
                    Section("Вопрос") {
                        TextField("Опишите вопрос подробно", text: $message, axis: .vertical).lineLimit(5...14)
                    }
                    Section(header: Text("Куда ответить"), footer: Text("Ответ придёт на эту почту. Вопрос уходит в ЭИОС так же, как с кнопки «Отправить» на сайте.")) {
                        TextField("Email", text: $email).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section {
                        Button {
                            Task { await send() }
                        } label: {
                            HStack { Spacer(); if sending { ProgressView() } else { Text("Отправить").bold() }; Spacer() }
                        }
                        .disabled(!canSend)
                    }
                } else if error == nil {
                    HStack { ProgressView(); Text("Загружаем форму ЭИОС…") }
                }
                if let error = error {
                    Section {
                        Text(error).foregroundColor(.orange)
                        Button("Открыть форму на сайте") {
                            page = PortalDestination(title: "Задать вопрос", url: PortalConfiguration.questionURL)
                        }
                    }
                }
            }
            .tint(Color.themeAccent(isChristmas: isChristmasMode))
            .navigationTitle("Задать вопрос").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Закрыть") { dismiss() } } }
            .task {
                guard form == nil else { return }
                do {
                    let loaded = try await network.questionForm()
                    form = loaded
                    category = loaded.categories.first?.id ?? ""
                    if email.isEmpty { email = loaded.email }
                } catch { self.error = network.message(for: error) }
            }
            .alert("Вопрос отправлен", isPresented: $sent) {
                Button("Готово") { dismiss() }
            } message: { Text("Ответ придёт на \(email).") }
        }
        .interactiveDismissDisabled(!message.isEmpty)
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await network.sendQuestion(category: category, subject: subject.trimmingCharacters(in: .whitespaces),
                                           message: message.trimmingCharacters(in: .whitespacesAndNewlines), email: email)
            error = nil
            sent = true
            AppHapticManager.shared.notification(type: .success)
        } catch {
            // The text stays in the form; nothing is re-sent automatically.
            self.error = "Не отправлено: " + network.message(for: error)
        }
    }
}

// ==========================================
// ЗАКАЗ СПРАВОК — форма сайта, показанная нативно (вид справки → поля → отправка)
// ==========================================
@MainActor
struct InquiryScreen: View {
    let isChristmasMode: Bool
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chooser: PortalForm?
    @State private var kind = ""
    @State private var request: PortalForm?
    @State private var values: [String: String] = [:]
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?
    @State private var result: String?
    @State private var page: PortalDestination?

    private var kindField: PortalForm.Field? { chooser?.fields.first { $0.name == "form_type" } }

    var body: some View {
        NavigationStack {
            Form {
                if loading { HStack { ProgressView(); Text("Загружаем форму ЭИОС…") } }
                if let field = kindField {
                    Section("Вид справки") {
                        Picker("Вид справки", selection: $kind) {
                            ForEach(field.options.filter { !$0.value.isEmpty }, id: \.value) { Text($0.title).tag($0.value) }
                        }
                        .pickerStyle(.navigationLink)
                        .onChange(of: kind) { _, _ in request = nil; values = [:]; Task { await openRequest() } }
                    }
                }
                if let request = request {
                    Section("Данные для справки") {
                        ForEach(request.visibleFields) { field in fieldView(field) }
                    }
                    Section {
                        Button { Task { await send(request) } } label: {
                            HStack { Spacer(); if sending { ProgressView() } else { Text(request.submit?.value ?? "Отправить запрос").bold() }; Spacer() }
                        }.disabled(sending)
                    }
                }
                if let error = error {
                    Section {
                        Text(error).foregroundColor(.orange)
                        Button("Открыть на сайте") { page = PortalDestination(title: "Заказ справок", url: PortalConfiguration.inquiryURL) }
                    }
                }
            }
            .tint(Color.themeAccent(isChristmas: isChristmasMode))
            .navigationTitle("Заказ справок").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Закрыть") { dismiss() } } }
            .task { if chooser == nil { await loadChooser() } }
            .alert("Ответ ЭИОС", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
                Button("Готово") { result = nil }
            } message: { Text(result ?? "") }
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
    }

    @ViewBuilder private func fieldView(_ field: PortalForm.Field) -> some View {
        let binding = Binding(get: { values[field.name] ?? field.value }, set: { values[field.name] = $0 })
        let title = field.label.isEmpty ? field.name : field.label
        switch field.kind {
        case .select:
            Picker(title, selection: binding) { ForEach(field.options, id: \.value) { Text($0.title).tag($0.value) } }
        case .textarea:
            TextField(title, text: binding, axis: .vertical).lineLimit(3...8)
        case .checkbox:
            Toggle(title, isOn: Binding(get: { values[field.name] == "1" }, set: { values[field.name] = $0 ? "1" : "0" }))
        default:
            TextField(title, text: binding)
                .keyboardType(title.lowercased().contains("телефон") ? .phonePad : .default)
        }
    }

    private func loadChooser() async {
        loading = true
        defer { loading = false }
        do {
            let loaded = try await network.loadForms(at: PortalConfiguration.inquiryURL)
            chooser = loaded.forms.first { form in form.fields.contains { $0.name == "form_type" } }
            if chooser == nil { error = "Форма заказа справок не распознана." }
        } catch { self.error = network.message(for: error) }
    }

    private func openRequest() async {
        guard let chooser = chooser, !kind.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let opened = try await network.openForm(chooser, values: ["form_type": kind])
            request = opened.forms.first { $0.isPost && !$0.fields.contains { $0.name == "form_type" } }
            error = request == nil ? (PortalParser.notices(html: opened.page.html, source: opened.page.url)?.text
                                      ?? "Для этой справки ЭИОС не показала форму.") : nil
        } catch { self.error = network.message(for: error) }
    }

    private func send(_ form: PortalForm) async {
        sending = true
        defer { sending = false }
        do {
            let page = try await network.submitForm(form, values: values)
            let notice = PortalParser.notices(html: page.html, source: page.url)
            if notice?.isError == true { error = notice?.text } else {
                result = notice?.text ?? "Запрос отправлен. Статус справки можно посмотреть на этой же странице ЭИОС."
                request = nil; kind = ""; values = [:]
                AppHapticManager.shared.notification(type: .success)
            }
        } catch {
            // Sent at most once; the values stay in the form.
            self.error = "Не отправлено: " + network.message(for: error)
        }
    }
}
