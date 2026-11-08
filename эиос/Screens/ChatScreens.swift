import SwiftUI

// ==========================================
// ПЕРЕПИСКА внутри приложения: чаты ЭИОС без открытия сайта
// ==========================================

@MainActor
struct ChatAvatar: View {
    let user: ChatUser?
    var fallback = "?"
    var size: CGFloat = 44
    var tint: Color = .blue

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: user?.imageURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else {
                    ZStack {
                        Circle().fill(tint.opacity(0.18))
                        Text(user?.initials.isEmpty == false ? user!.initials : fallback)
                            .font(.system(size: size * 0.36, weight: .bold)).foregroundColor(tint)
                    }
                }
            }
            .frame(width: size, height: size).clipShape(Circle())
            if user?.isOnline == true {
                Circle().fill(Color.green).frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct ConversationRow: View {
    let conversation: ChatConversation
    let myID: Int?
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(user: conversation.isGroup ? nil : conversation.members.first,
                       fallback: String(conversation.title.prefix(1)), tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title).font(.headline).foregroundColor(.primary).lineLimit(1)
                    Spacer(minLength: 6)
                    if let time = conversation.lastMessage?.time {
                        Text(ChatFormat.listTime(time)).font(.caption).foregroundColor(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(preview).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                    Spacer(minLength: 6)
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)").font(.caption.bold()).foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(tint, in: Capsule())
                    }
                }
            }
        }
        .padding(12).background(Color.cardBackground(for: colorScheme)).cornerRadius(18)
    }

    private var preview: String {
        guard let last = conversation.lastMessage else { return conversation.subtitle.isEmpty ? "Нет сообщений" : conversation.subtitle }
        return (last.fromUserID == myID ? "Вы: " : "") + last.text
    }
}

enum ChatFormat {
    static func listTime(_ date: Date) -> String {
        let calendar = CampusDate.calendar
        if calendar.isDateInToday(date) { return CampusDate.formatter("HH:mm").string(from: date) }
        if calendar.isDateInYesterday(date) { return "вчера" }
        return CampusDate.formatter("d MMM").string(from: date)
    }
    static func dayHeader(_ date: Date) -> String {
        let calendar = CampusDate.calendar
        if calendar.isDateInToday(date) { return "Сегодня" }
        if calendar.isDateInYesterday(date) { return "Вчера" }
        return CampusDate.formatter("d MMMM yyyy").string(from: date)
    }
}

/// One conversation: bubbles, day separators, a growing input field and a send button.
/// Either an existing conversation, or a new one with a person (first message creates it).
@MainActor
struct ChatScreen: View {
    let title: String
    let isChristmasMode: Bool
    @State var conversationID: Int?
    var partner: ChatUser? = nil

    @ObservedObject private var messenger = Messenger.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var messages: [ChatMessage] = []
    @State private var members: [ChatUser] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var loading = true
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    private var accent: Color { Color.themeAccent(isChristmas: isChristmasMode) }
    private var isGroup: Bool { members.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if loading && messages.isEmpty { ProgressView().padding(.top, 40) }
                        if !loading && messages.isEmpty && error == nil {
                            Text(partner == nil ? "Сообщений пока нет." : "Напишите первое сообщение — оно уйдёт через ЭИОС.")
                                .font(.callout).foregroundColor(.secondary).padding(.top, 40)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !CampusDate.calendar.isDate(messages[index - 1].time, inSameDayAs: message.time) {
                                Text(ChatFormat.dayHeader(message.time)).font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary).padding(.vertical, 8)
                            }
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.id) { _, id in
                    if let id = id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            if let error = error {
                Text(error).font(.caption).foregroundColor(.orange).padding(.horizontal).padding(.vertical, 4)
            }
            inputBar
        }
        .background(Color.appBackground)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task {
            if conversationID == nil, let partner = partner {
                conversationID = await messenger.conversationID(with: partner)
            }
            // Poll while the chat is open; the portal has no push for this app.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.fromUserID == messenger.myID
        let author = isGroup && !mine ? members.first { $0.id == message.fromUserID }?.fullname : nil
        return HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if let author = author { Text(author).font(.caption2.bold()).foregroundColor(accent) }
                Text(message.text).font(.body).foregroundColor(mine ? .white : .primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(CampusDate.formatter("HH:mm").string(from: message.time)).font(.caption2)
                    .foregroundColor(mine ? .white.opacity(0.75) : .secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? accent : Color.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 18))
            if !mine { Spacer(minLength: 48) }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Сообщение", text: $draft, axis: .vertical)
                .lineLimit(1...6).focused($inputFocused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 20))
            Button { Task { await send() } } label: {
                Image(systemName: sending ? "hourglass" : "arrow.up.circle.fill").font(.system(size: 32))
                    .foregroundColor(canSend ? accent : .gray)
            }
            .disabled(!canSend).accessibilityLabel("Отправить")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func reload() async {
        guard let id = conversationID else { loading = false; return }
        do {
            let loaded = try await messenger.messages(in: id)
            if loaded.messages != messages { messages = loaded.messages }
            members = loaded.members
            error = nil
            await messenger.markRead(id)
        } catch {
            self.error = NetworkManager.shared.message(for: error)
        }
        loading = false
    }

    private func send() async {
        let original = draft
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            let sent: [ChatMessage]
            if let id = conversationID {
                sent = try await messenger.send(text, to: id)
            } else if let partner = partner {
                let result = try await messenger.sendFirst(text, to: partner)
                conversationID = result.conversationID
                sent = result.messages
            } else { return }
            // Only the sent text leaves the field, after the portal confirmed it. Anything typed
            // while the request was running stays as the next draft.
            if draft.hasPrefix(original) {
                draft = String(draft.dropFirst(original.count).drop(while: { $0.isWhitespace }))
            }
            messages.append(contentsOf: sent.filter { new in !messages.contains { $0.id == new.id } })
            error = nil
            AppHapticManager.shared.notification(type: .success)
        } catch {
            self.error = "Не отправлено: " + NetworkManager.shared.message(for: error) + " Текст сохранён в поле ввода."
            AppHapticManager.shared.notification(type: .error)
        }
    }
}

/// Find a person by name (teachers, classmates) and open a chat with them.
@MainActor
struct NewChatScreen: View {
    let isChristmasMode: Bool
    var initialQuery = ""
    @ObservedObject private var messenger = Messenger.shared
    @State private var query = ""
    @State private var results: [ChatUser] = []
    @State private var searching = false
    @State private var error: String?
    @State private var started = false

    var body: some View {
        List {
            if searching { HStack { ProgressView(); Text("Ищем в ЭИОС…") } }
            if let error = error { Text(error).font(.caption).foregroundColor(.orange) }
            if !searching && results.isEmpty && query.count >= 3 && error == nil {
                Text("Никого не нашлось. Попробуйте только фамилию.").foregroundColor(.secondary)
            }
            if query.count < 3 && results.isEmpty {
                Text("Введите хотя бы 3 буквы фамилии или имени.").foregroundColor(.secondary)
            }
            ForEach(results) { user in
                NavigationLink {
                    ChatScreen(title: user.fullname, isChristmasMode: isChristmasMode, conversationID: nil, partner: user)
                } label: {
                    HStack(spacing: 12) {
                        ChatAvatar(user: user, size: 38, tint: Color.themeAccent(isChristmas: isChristmasMode))
                        Text(user.fullname)
                    }
                }
            }
        }
        .navigationTitle("Новое сообщение").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Фамилия или имя")
        .task(id: query) {
            if !started { started = true; if query.isEmpty && !initialQuery.isEmpty { query = initialQuery; return } }
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 3 else { results = []; return }
            try? await Task.sleep(nanoseconds: 400_000_000) // debounce typing
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do { results = try await messenger.searchUsers(text); error = nil }
            catch { self.error = NetworkManager.shared.message(for: error) }
        }
    }
}

/// Replaces the cramped action sheet: full readable titles, search, current courses first.
@MainActor
struct CoursePickerScreen: View {
    let isChristmasMode: Bool
    let onPick: (Course) -> Void
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [Course] {
        let text = PortalParser.normalized(query)
        let all = network.courses.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        return text.isEmpty ? all : all.filter { PortalParser.normalized($0.title).contains(text) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { course in
                let title = CourseTitle(course.title)
                Button { onPick(course); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title.subject).font(.headline).foregroundColor(.primary)
                        if !title.detailLine.isEmpty {
                            Text(title.detailLine).font(.caption).foregroundColor(.secondary)
                        }
                    }.padding(.vertical, 2)
                }
            }
            .searchable(text: $query, prompt: "Предмет или преподаватель")
            .navigationTitle("Выберите курс").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Отмена") { dismiss() } } }
            .overlay { if network.courses.isEmpty { Text("Курсы ещё не загружены.").foregroundColor(.secondary) } }
        }
    }
}
