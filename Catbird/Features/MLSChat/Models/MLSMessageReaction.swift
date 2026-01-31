import Foundation
import CatbirdMLSService

/// Represents a reaction on an MLS message
struct MLSMessageReaction: Identifiable, Equatable, Hashable {
    /// Unique identifier (combined messageId + reaction + did)
    var id: String { "\(messageId)_\(reaction)_\(senderDID)" }
    
    /// The message this reaction is on
    let messageId: String
    
    /// The reaction emoji or short code
    let reaction: String
    
    /// DID of the user who reacted
    let senderDID: String
    
    /// When the reaction was added
    let reactedAt: Date?
    
    init(messageId: String, reaction: String, senderDID: String, reactedAt: Date? = nil) {
        self.messageId = messageId
        self.reaction = reaction
        self.senderDID = senderDID
        self.reactedAt = reactedAt
    }
}

/// Aggregated reaction count for display
struct MLSReactionSummary: Identifiable, Equatable {
    var id: String { reaction }
    
    /// The reaction emoji
    let reaction: String
    
    /// Number of users who added this reaction
    let count: Int
    
    /// DIDs of users who reacted (for tooltip/detail)
    let reactors: [String]
    
    /// Whether the current user has added this reaction
    let isReactedByCurrentUser: Bool
}

extension Array where Element == MLSMessageReaction {
    /// Group reactions by emoji and create summaries
    func summarize(currentUserDID: String?) -> [MLSReactionSummary] {
        let grouped = Dictionary(grouping: self) { $0.reaction }
        
        return grouped.map { emoji, reactions in
            MLSReactionSummary(
                reaction: emoji,
                count: reactions.count,
                reactors: reactions.map { $0.senderDID },
                isReactedByCurrentUser: reactions.contains { $0.senderDID == currentUserDID }
            )
        }
        .sorted { $0.count > $1.count }
    }
}
