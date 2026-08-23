import Foundation

actor CopilotHistoryStore {
    static let shared = CopilotHistoryStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func conversations(for accountDID: String) -> [CopilotConversation] {
        guard let data = defaults.data(forKey: key(accountDID)),
              let conversations = try? decoder.decode([CopilotConversation].self, from: data) else {
            return []
        }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: CopilotConversation) throws {
        var values = conversations(for: conversation.accountDID)
        values.removeAll { $0.id == conversation.id }
        values.append(conversation)
        defaults.set(try encoder.encode(values), forKey: key(conversation.accountDID))
    }

    private func key(_ accountDID: String) -> String {
        "copilotHistory.v1.\(accountDID)"
    }
}
