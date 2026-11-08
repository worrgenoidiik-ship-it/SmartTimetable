import SwiftUI

// ==========================================
// ТЕСТ внутри приложения: вопросы нативно, ответы уходят в ЭИОС теми же запросами,
// что и с кнопок сайта. «Завершить тест» — только после подтверждения.
// ==========================================
@MainActor
struct QuizScreen: View {
    let title: String
    let url: URL
    let isChristmasMode: Bool

    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var content: QuizContent?
    @State private var values: [String: String] = [:]
    @State private var checked: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmFinish = false
    @State private var browser: PortalDestination?
    @State private var deadline: Date?

    private var accent: Color { Color.themeAccent(isChristmas: isChristmasMode) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear.frame(height: 0).id("top")
                        if let error = error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundColor(.orange)
                        }
                        switch content {
                        case .none: HStack { ProgressView(); Text("Загружаем тест…") }.padding(.top, 40)
                        case .start(let start)?: startView(start)
                        case .attempt(let page)?: attemptView(page)
                        case .summary(let summary)?: summaryView(summary)
                        case .review(let reviewTitle, let rows, let reviewURL)?: reviewView(reviewTitle, rows, reviewURL)
                        case .unknown(let text)?: unknownView(text)
                        }
                    }
                    .padding()
                }
                .onChange(of: content) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
            }
            .background(Color.appBackground)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Закрыть") { dismiss() } }
                if let deadline = deadline {
                    ToolbarItem(placement: .navigationBarTrailing) { timerView(deadline) }
                }
            }
            .task { if content == nil { await load(url) } }
            .alert("Завершить тест?", isPresented: $confirmFinish) {
                Button("Отмена", role: .cancel) {}
                Button("Отправить всё", role: .destructive) { Task { await finish() } }
            } message: { Text("После отправки изменить ответы будет нельзя. ЭИОС сразу посчитает результат.") }
        }
        .interactiveDismissDisabled(true)
        .sheet(item: $browser) { PortalBrowserScreen(title: $0.title, url: $0.url) }
    }

    // MARK: Stages

    private func startView(_ start: QuizStart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(start.title).font(.title3.bold())
            ForEach(start.info, id: \.self) { Text($0).font(.callout).foregroundColor(.secondary) }
            ForEach(Array(start.attempts.enumerated()), id: \.offset) { _, table in PortalTableView(table: table) }
            if let action = start.action {
                Button { Task { await submit(action, start.fields) } } label: {
                    Text(start.buttonTitle).bold().frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(accent).disabled(busy)
            }
        }
    }

    private func attemptView(_ page: QuizAttemptPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Страница \(page.pageNumber + 1)").font(.caption.bold()).foregroundColor(.secondary)
            if page.hasUnsupported {
                VStack(alignment: .leading, spacing: 6) {
                    Text("На этой странице есть вопрос, который удобнее ответить в окне ЭИОС.").font(.callout)
                    Button("Открыть эту страницу") { browser = PortalDestination(title: "Тест", url: page.url) }
                }
                .padding().background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(page.questions) { question in questionCard(question) }
            HStack(spacing: 12) {
                if let previous = page.previous {
                    Button { Task { await go(page, button: previous) } } label: {
                        Label("Назад", systemImage: "chevron.left").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.bordered)
                }
                if let next = page.next {
                    Button { Task { await go(page, button: next) } } label: {
                        HStack { Text(nextTitle(next.value)).bold(); Image(systemName: "chevron.right") }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent)
                }
            }
            .tint(accent).disabled(busy)
            if busy { HStack { ProgressView(); Text("Сохраняем ответы в ЭИОС…").font(.caption) } }
            Text("Ответы сохраняются в ЭИОС при переходе на другую страницу, как на сайте.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func nextTitle(_ site: String) -> String {
        let value = PortalParser.normalized(site)
        return value.contains("закончить") || value.contains("finish") ? "К итогам" : "Далее"
    }

    private func questionCard(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Вопрос \(question.number)").font(.caption.bold()).foregroundColor(accent)
                Spacer()
                Text(question.grade).font(.caption2).foregroundColor(.secondary)
            }
            if !question.text.isEmpty { Text(question.text).font(.body.weight(.medium)).textSelection(.enabled) }
            ForEach(question.images, id: \.self) { image in
                AsyncImage(url: image) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxHeight: 260).cornerRadius(10)
            }
            if !question.prompt.isEmpty { Text(question.prompt).font(.caption).foregroundColor(.secondary) }
            answerView(question)
        }
        .padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(18)
    }

    @ViewBuilder private func answerView(_ question: QuizQuestion) -> some View {
        switch question.answer {
        case .single(let name, let options):
            ForEach(options) { option in
                optionRow(option.label, selected: values[name] == option.value, multiple: false) {
                    values[name] = values[name] == option.value ? nil : option.value
                }
            }
        case .multiple(let options):
            ForEach(options) { option in
                optionRow(option.label, selected: checked.contains(option.id), multiple: true) {
                    if checked.contains(option.id) { checked.remove(option.id) } else { checked.insert(option.id) }
                }
            }
        case .text(let name, let multiline):
            TextField(multiline ? "Ваш ответ" : "Ответ", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }),
                      axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 4...14 : 1...1)
                .padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        case .selects(let selects):
            ForEach(selects) { select in
                VStack(alignment: .leading, spacing: 4) {
                    if !select.prompt.isEmpty { Text(select.prompt).font(.callout) }
                    Picker(select.prompt.isEmpty ? "Ответ" : select.prompt,
                           selection: Binding(get: { values[select.name] ?? "" }, set: { values[select.name] = $0 })) {
                        ForEach(select.options, id: \.value) { Text($0.title.isEmpty ? "Выбрать…" : $0.title).tag($0.value) }
                    }.pickerStyle(.menu)
                }
            }
        case .unsupported:
            Text("Этот тип вопроса отвечается в окне ЭИОС (кнопка выше).").font(.caption).foregroundColor(.orange)
        }
    }

    private func optionRow(_ label: String, selected: Bool, multiple: Bool, action: @escaping () -> Void) -> some View {
        Button {
            AppHapticManager.shared.impact(style: .light)
            action()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square")
                                           : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundColor(selected ? accent : .secondary).font(.title3)
                Text(label).foregroundColor(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected ? accent.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
    }

    private func summaryView(_ summary: QuizSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Итог попытки").font(.title3.bold())
            ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text("Вопрос \(row.question)")
                    Spacer()
                    Text(row.status).font(.callout)
                        .foregroundColor(PortalParser.normalized(row.status).contains("нет ответа") ? .orange : .secondary)
                }
                .padding(12).background(Color.cardBackground(for: colorScheme)).cornerRadius(12)
            }
            if let back = summary.returnURL {
                Button { Task { await load(back) } } label: {
                    Label("Вернуться к вопросам", systemImage: "arrow.uturn.left").frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.bordered).tint(accent)
            }
            if summary.finishAction != nil {
                Button { confirmFinish = true } label: {
                    Text("Отправить всё и завершить тест").bold().frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).tint(accent)
            }
        }.disabled(busy)
    }

    private func reviewView(_ reviewTitle: String, _ rows: [(String, String)], _ reviewURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Тест завершён", systemImage: "checkmark.seal.fill").font(.title3.bold()).foregroundColor(.green)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundColor(.secondary)
                    Spacer()
                    Text(row.1).bold().multilineTextAlignment(.trailing)
                }
                .padding(12).background(Color.cardBackground(for: colorScheme)).cornerRadius(12)
            }
            Button("Посмотреть разбор ответов") { browser = PortalDestination(title: "Разбор", url: reviewURL) }
            Button("Готово") { dismiss() }.buttonStyle(.borderedProminent).tint(accent)
        }
    }

    private func unknownView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.callout)
            Button("Открыть тест в окне ЭИОС") { browser = PortalDestination(title: title, url: url) }
                .buttonStyle(.borderedProminent).tint(accent)
        }
    }

    private func timerView(_ deadline: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(deadline.timeIntervalSince(context.date)))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.subheadline.monospacedDigit().bold())
                .foregroundColor(left < 60 ? .red : .primary)
                .onChange(of: left == 0) { _, finished in if finished { Task { await timeUp() } } }
        }
    }

    // MARK: Actions

    private func show(_ next: QuizContent) {
        content = next
        error = nil
        switch next {
        case .attempt(let page):
            let state = page.initialState
            values = state.values; checked = state.checked
            deadline = page.timeLeft.map { Date().addingTimeInterval($0) }
        case .summary(let summary):
            deadline = summary.timeLeft.map { Date().addingTimeInterval($0) }
        default:
            deadline = nil
        }
    }

    private func load(_ target: URL) async {
        busy = true
        defer { busy = false }
        do { show(try await network.quizPage(target)) } catch { self.error = network.message(for: error) }
    }

    private func submit(_ action: URL, _ items: [URLQueryItem]) async {
        busy = true
        defer { busy = false }
        do { show(try await network.quizSubmit(action, items: items)) }
        catch { self.error = "Не отправлено: " + network.message(for: error) + " Ответы остались на экране." }
    }

    private func go(_ page: QuizAttemptPage, button: (name: String, value: String)) async {
        await submit(page.action, page.payload(values: values, checked: checked, button: button))
    }

    private func finish() async {
        guard case .summary(let summary)? = content, let action = summary.finishAction else { return }
        await submit(action, summary.finishFields)
    }

    /// Exactly what the site's own timer does: send the current page with timeup=1.
    private func timeUp() async {
        guard !busy else { return }
        if case .attempt(let page)? = content {
            await submit(page.action, page.payload(values: values, checked: checked, button: page.next, timeUp: true))
        }
    }
}
