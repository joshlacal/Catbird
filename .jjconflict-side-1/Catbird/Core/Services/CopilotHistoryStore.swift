import Foundation

actor CopilotHistoryStore {
    static let shared = CopilotHistoryStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func conversations(for accountDID: String) throws -> [CopilotConversation] {
        guard let data = defaults.data(forKey: key(accountDID)) else {
            return []
        }
        let conversations = try decoder.decode([CopilotConversation].self, from: data)
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: CopilotConversation) throws {
        var values = try conversations(for: conversation.accountDID)
        values.removeAll { $0.id == conversation.id }
        values.append(conversation)
        defaults.set(try encoder.encode(values), forKey: key(conversation.accountDID))
    }

    func delete(conversationID: UUID, accountDID: String) throws {
        var values = try conversations(for: accountDID)
        values.removeAll { $0.id == conversationID }
        let data = try encoder.encode(values)
        defaults.set(data, forKey: key(accountDID))
    }

    func clear(accountDID: String) {
        defaults.removeObject(forKey: key(accountDID))
    }

    private func key(_ accountDID: String) -> String {
        "copilotHistory.v1.\(accountDID)"
    }
}
