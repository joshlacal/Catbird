//
//  IntentRuleModels.swift
//  Catbird
//
//  Created for Catbird on-device intent controls.
//

import Foundation

/// Action taken when a post matches an intent rule.
public enum IntentRuleAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case hide = "hide"
    case demote = "demote"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hide:
            return String(localized: "Hide", comment: "Timeline intent rule action that hides matching posts")
        case .demote:
            return String(localized: "Demote", comment: "Timeline intent rule action that moves matching posts lower")
        }
    }

    public var systemImage: String {
        switch self {
        case .hide: return "eye.slash"
        case .demote: return "arrow.down.circle"
        }
    }

    public var explanation: String {
        switch self {
        case .hide:
            return String(
                localized: "Collapses matching posts into a placeholder with tap-to-reveal.",
                comment: "Explanation of the Hide timeline intent rule action"
            )
        case .demote:
            return String(
                localized: "Moves matching posts toward the bottom of the loaded timeline page.",
                comment: "Explanation of the Demote timeline intent rule action"
            )
        }
    }
}

/// A natural-language intent rule evaluated on-device against timeline posts.
public struct IntentRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var action: IntentRuleAction
    public var isEnabled: Bool
    public let createdAt: Date
    public let accountDID: String

    public init(
        id: UUID = UUID(),
        text: String,
        action: IntentRuleAction = .hide,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        accountDID: String
    ) {
        self.id = id
        self.text = text
        self.action = action
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.accountDID = accountDID
    }
}
