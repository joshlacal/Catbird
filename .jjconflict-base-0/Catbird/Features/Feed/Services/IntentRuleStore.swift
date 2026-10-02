//
//  IntentRuleStore.swift
//  Catbird
//
//  Created for Catbird on-device intent controls.
//

import Foundation

/// Manages local storage of IntentRules for the user's accounts.
public actor IntentRuleStore {
    public static let shared = IntentRuleStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func rules(for accountDID: String) -> [IntentRule] {
        guard let data = defaults.data(forKey: storageKey(accountDID)),
              let rules = try? decoder.decode([IntentRule].self, from: data) else {
            return []
        }
        return rules
    }

    public func save(_ rule: IntentRule) async throws {
        var accountRules = rules(for: rule.accountDID)
        accountRules.removeAll { $0.id == rule.id }
        accountRules.append(rule)
        defaults.set(try encoder.encode(accountRules), forKey: storageKey(rule.accountDID))
        await IntentVerdictCache.shared.clear()
        NotificationCenter.default.post(name: .intentRulesDidChange, object: rule.accountDID)
    }

    public func remove(id: UUID, accountDID: String) async throws {
        var accountRules = rules(for: accountDID)
        accountRules.removeAll { $0.id == id }
        defaults.set(try encoder.encode(accountRules), forKey: storageKey(accountDID))
        await IntentVerdictCache.shared.clear()
        NotificationCenter.default.post(name: .intentRulesDidChange, object: accountDID)
    }

    public func toggle(id: UUID, accountDID: String, isEnabled: Bool) async throws {
        var accountRules = rules(for: accountDID)
        guard let index = accountRules.firstIndex(where: { $0.id == id }) else { return }
        accountRules[index].isEnabled = isEnabled
        defaults.set(try encoder.encode(accountRules), forKey: storageKey(accountDID))
        await IntentVerdictCache.shared.clear()
        NotificationCenter.default.post(name: .intentRulesDidChange, object: accountDID)
    }

    private func storageKey(_ accountDID: String) -> String {
        "intentRules.v1.\(accountDID)"
    }
}

extension Notification.Name {
    public static let intentRulesDidChange = Notification.Name("IntentRulesDidChange")
}
