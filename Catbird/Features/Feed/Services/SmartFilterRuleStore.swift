import Foundation

actor SmartFilterRuleStore {
    static let shared = SmartFilterRuleStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func rules(for accountDID: String) -> [FeedFilterRule] {
        guard let data = defaults.data(forKey: storageKey(accountDID)),
              let rules = try? decoder.decode([FeedFilterRule].self, from: data) else {
            return []
        }
        return rules
    }

    func save(_ rule: FeedFilterRule) throws {
        var accountRules = rules(for: rule.accountDID)
        accountRules.removeAll { $0.id == rule.id }
        accountRules.append(rule)
        defaults.set(try encoder.encode(accountRules), forKey: storageKey(rule.accountDID))
        NotificationCenter.default.post(name: .smartFiltersDidChange, object: rule.accountDID)
    }

    func remove(id: UUID, accountDID: String) throws {
        var accountRules = rules(for: accountDID)
        accountRules.removeAll { $0.id == id }
        defaults.set(try encoder.encode(accountRules), forKey: storageKey(accountDID))
        NotificationCenter.default.post(name: .smartFiltersDidChange, object: accountDID)
    }

    private func storageKey(_ accountDID: String) -> String {
        "smartFilters.v1.\(accountDID)"
    }
}

extension Notification.Name {
    static let smartFiltersDidChange = Notification.Name("SmartFiltersDidChange")
}
