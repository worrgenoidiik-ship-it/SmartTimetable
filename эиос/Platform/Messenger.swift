import Foundation
import Combine

/// State of the native messenger. Conversations are kept in memory only: messages are
/// personal and always re-read from the portal, so nothing is written to the cache.
@MainActor
final class Messenger: ObservableObject {
    static let shared = Messenger()
    @Published private(set) var conversations: [ChatConversation] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var myID: Int?

    private let network = NetworkManager.shared
    /// Bumped by reset(): a load started for the previous account must not fill the new one.
    private var generation = 0
    var unreadTotal: Int { conversations.reduce(0) { $0 + $1.unread } }

    func loadConversations() async {
        guard !loading else { return }
        let token = generation
        loading = true
        defer { if token == generation { loading = false } }
        do {
            let me = try await network.moodleUserID()
            guard token == generation else { return }
            myID = me
            let data = try await network.portalAJAX("core_message_get_conversations", [
                "userid": me, "limitfrom": 0, "limitnum": 50, "mergeself": true,
            ])
            let values = try MessagingParser.conversations(data)
                .sorted { ($0.lastMessage?.time ?? .distantPast) > ($1.lastMessage?.time ?? .distantPast) }
            guard token == generation else { return }
            conversations = values
            error = nil
        } catch {
            if token == generation { self.error = network.message(for: error) }
        }
    }

    func messages(in conversationID: Int) async throws -> (messages: [ChatMessage], members: [ChatUser]) {
        let me = try await network.moodleUserID()
        myID = me
        let data = try await network.portalAJAX("core_message_get_conversation_messages", [
            "currentuserid": me, "convid": conversationID, "limitfrom": 0, "limitnum": 100, "newest": true,
        ])
        return try MessagingParser.conversationMessages(data)
    }

    /// Existing conversation with a person, if there is one (for «написать преподавателю»).
    func conversationID(with user: ChatUser) async -> Int? {
        if let known = conversations.first(where: { !$0.isGroup && $0.members.contains { $0.id == user.id } }) { return known.id }
        guard let me = try? await network.moodleUserID(),
              let data = try? await network.portalAJAX("core_message_get_conversation_between_users", [
                  "userid": me, "otheruserid": user.id, "includecontactrequests": false, "includeprivacyinfo": false,
              ]) as? [String: Any] else { return nil }
        return (data["id"] as? NSNumber)?.intValue
    }

    func send(_ text: String, to conversationID: Int) async throws -> [ChatMessage] {
        let data = try await network.portalAJAX("core_message_send_messages_to_conversation", [
            "conversationid": conversationID, "messages": [["text": text]],
        ])
        return try MessagingParser.sentMessages(data)
    }

    /// First message to a person; returns the new conversation's ID.
    func sendFirst(_ text: String, to user: ChatUser) async throws -> (conversationID: Int?, messages: [ChatMessage]) {
        let data = try await network.portalAJAX("core_message_send_instant_messages", [
            "messages": [["touserid": user.id, "text": text]],
        ])
        let conversation = (data as? [[String: Any]])?.first.flatMap { ($0["conversationid"] as? NSNumber)?.intValue }
        return (conversation, try MessagingParser.sentMessages(data))
    }

    func searchUsers(_ query: String) async throws -> [ChatUser] {
        let me = try await network.moodleUserID()
        let data = try await network.portalAJAX("core_message_message_search_users", [
            "userid": me, "search": query, "limitfrom": 0, "limitnum": 30,
        ])
        return MessagingParser.searchResults(data).filter { $0.id != me }
    }

    func markRead(_ conversationID: Int) async {
        guard let me = try? await network.moodleUserID() else { return }
        _ = try? await network.portalAJAX("core_message_mark_all_conversation_messages_as_read", [
            "userid": me, "conversationid": conversationID,
        ])
        if let index = conversations.firstIndex(where: { $0.id == conversationID }), conversations[index].unread > 0 {
            let old = conversations[index]
            conversations[index] = ChatConversation(id: old.id, name: old.name, subtitle: old.subtitle, members: old.members,
                                                    lastMessage: old.lastMessage, unread: 0, isGroup: old.isGroup, isSelf: old.isSelf)
        }
    }

    func reset() { generation += 1; conversations = []; myID = nil; error = nil; loading = false }
}
