import Foundation

/// Who an encrypted chat-list row is with.
///
/// A row's people used to come only from whoever had sent one of its recent messages. A
/// conversation where the other person had not written yet (a request just sent or just
/// accepted) therefore had nobody but you, and the row fell back to "Secure Chat". The
/// group's own member list comes first; recent senders follow for anyone that list does
/// not carry, such as someone who has since left.
enum MLSConversationListMembers {
  /// Member DIDs in display order, each once. DIDs that differ only in letter case are
  /// the same person; the first spelling seen is kept.
  static func memberDIDs(groupMembers: [String], recentSenders: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for did in groupMembers + recentSenders where seen.insert(did.lowercased()).inserted {
      result.append(did)
    }
    return result
  }
}
