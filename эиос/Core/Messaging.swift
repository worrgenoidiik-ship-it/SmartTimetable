import Foundation

// Native messenger on top of Moodle 3.7's own messaging web services (the ones the
// site's message drawer calls through lib/ajax/service.php):
//   core_message_get_conversations, core_message_get_conversation_messages,
//   core_message_send_messages_to_conversation, core_message_send_instant_messages,
//   core_message_message_search_users, core_message_get_conversation_between_users,
//   core_message_mark_all_conversation_messages_as_read.

struct ChatUser: Identifiable, Hashable, Sendable {
    let id: Int
    let fullname: String
    let imageURL: URL?
    var isOnline: Bool? = nil

    var initials: String {
        let parts = fullname.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: Int
    let fromUserID: Int
    let text: String
    let time: Date
}

struct ChatConversation: Identifiable, Sendable {
    let id: Int
    let name: String
    let subtitle: String
    let members: [ChatUser]
    let lastMessage: ChatMessage?
    let unread: Int
    let isGroup: Bool
    let isSelf: Bool

    var title: String {
        if !name.isEmpty { return name }
        if isSelf { return "Личные заметки" }
        return members.first?.fullname ?? "Диалог"
    }
}

enum MessagingParser {
    static func user(_ object: [String: Any]) -> ChatUser? {
        guard let id = (object["id"] as? NSNumber)?.intValue else { return nil }
        let image = (object["profileimageurl"] as? String).flatMap(URL.init(string:))
            .flatMap { PortalConfiguration.allowsDataURL($0) ? $0 : nil }
        let online = (object["showonlinestatus"] as? Bool) == true ? object["isonline"] as? Bool : nil
        return ChatUser(id: id, fullname: PortalParser.clean(object["fullname"] as? String ?? ""), imageURL: image, isOnline: online)
    }

    static func message(_ object: [String: Any]) -> ChatMessage? {
        guard let id = (object["id"] as? NSNumber)?.intValue ?? (object["msgid"] as? NSNumber)?.intValue, id > 0,
              let from = (object["useridfrom"] as? NSNumber)?.intValue,
              let created = (object["timecreated"] as? NSNumber)?.doubleValue else { return nil }
        return ChatMessage(id: id, fromUserID: from, text: PortalParser.plainText(fromHTML: object["text"] as? String ?? ""),
                           time: Date(timeIntervalSince1970: created))
    }

    static func conversations(_ data: Any) throws -> [ChatConversation] {
        guard let root = data as? [String: Any], let list = root["conversations"] as? [[String: Any]] else {
            throw PortalFailure.unrecognized("список чатов")
        }
        return list.compactMap { item in
            guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
            let type = (item["type"] as? NSNumber)?.intValue ?? 1
            let messages = (item["messages"] as? [[String: Any]] ?? []).compactMap(message)
            return ChatConversation(
                id: id, name: PortalParser.clean(item["name"] as? String ?? ""),
                subtitle: PortalParser.clean(item["subname"] as? String ?? ""),
                members: (item["members"] as? [[String: Any]] ?? []).compactMap(user),
                lastMessage: messages.max { $0.time < $1.time },
                unread: (item["unreadcount"] as? NSNumber)?.intValue ?? 0,
                isGroup: type == 2, isSelf: type == 3)
        }
    }

    /// Messages oldest first, plus the members for names in group chats.
    static func conversationMessages(_ data: Any) throws -> (messages: [ChatMessage], members: [ChatUser]) {
        guard let root = data as? [String: Any], let list = root["messages"] as? [[String: Any]] else {
            throw PortalFailure.unrecognized("сообщения чата")
        }
        let members = (root["members"] as? [[String: Any]] ?? []).compactMap(user)
        return (list.compactMap(message).sorted { ($0.time, $0.id) < ($1.time, $1.id) }, members)
    }

    static func sentMessages(_ data: Any) throws -> [ChatMessage] {
        guard let list = data as? [[String: Any]] else { throw PortalFailure.unrecognized("ответ на отправку") }
        if let error = list.compactMap({ $0["errormessage"] as? String }).first(where: { !$0.isEmpty }) {
            throw PortalFailure.unrecognized(error)
        }
        return list.compactMap(message)
    }

    static func searchResults(_ data: Any) -> [ChatUser] {
        guard let root = data as? [String: Any] else { return [] }
        let contacts = (root["contacts"] as? [[String: Any]] ?? []).compactMap(user)
        let others = (root["noncontacts"] as? [[String: Any]] ?? []).compactMap(user)
        var seen = Set<Int>()
        return (contacts + others).filter { seen.insert($0.id).inserted }
    }
}

/// Course titles on the portal pack everything into one string, e.g.
/// «Базы данных ИС-О-25/1 (3 семестр, Комарова Юлиана Егоровна)». Split it so lists
/// can show the subject large and the group / semester / teacher underneath.
struct CourseTitle: Equatable {
    let subject: String
    let details: [String]
    let teacher: String?

    init(_ raw: String) {
        var name = PortalParser.clean(raw)
        var details: [String] = []
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            let inner = name[open.upperBound..<name.index(before: name.endIndex)]
            details = inner.split(separator: ",").map { PortalParser.clean(String($0)) }.filter { !$0.isEmpty }
            name = String(name[..<open.lowerBound])
        }
        if let group = name.firstMatch(of: #/\s+([А-ЯЁA-Z][А-ЯЁа-яёA-Za-z]{0,7}-[А-ЯЁA-Z][А-ЯЁа-яёA-Za-z]{0,3}-\d{2}(?:/\d+)?)$/#) {
            details.insert(String(group.1), at: 0)
            name = String(name[..<group.range.lowerBound])
        }
        subject = name.isEmpty ? PortalParser.clean(raw) : name
        self.details = details
        // «Фамилия Имя Отчество» or «И. О. Фамилия» — the part that names a person.
        teacher = details.last { detail in
            detail.range(of: #"^[А-ЯЁ][а-яё-]+ [А-ЯЁ][а-яё-]+ [А-ЯЁ][а-яё-]+$"#, options: .regularExpression) != nil
                || detail.range(of: #"^[А-ЯЁ]\. ?[А-ЯЁ]\. [А-ЯЁ][а-яё-]+$"#, options: .regularExpression) != nil
        }
    }

    var detailLine: String { details.joined(separator: " · ") }
}
