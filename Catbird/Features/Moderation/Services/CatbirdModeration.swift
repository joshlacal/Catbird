import Foundation
import Petrel

/// Catbird's own moderation service: an Ozone instance the operator runs.
///
/// Encrypted chats and Circles are reported here, never to Bluesky. Like
/// Signal, a report carries ids only: who reported, who sent it, which
/// conversation or Circle, which message or post, when, and a reason category.
/// It never carries message text, post text, media or keys, and the report
/// sheets have no free-text box. The operator acts on accounts: a takedown in
/// Ozone locks the account out of encrypted chat (mls-ds) and Circles
/// (circle-appview). Public Bluesky posts keep going to Bluesky's moderation.
enum CatbirdModeration {
  /// DID of Catbird's Ozone service account (did:plc). Set this once the
  /// account exists. While it is nil, encrypted reports say reporting is not
  /// available yet instead of sending anywhere.
  static let serviceDID: String? = nil

  /// Shown at the top of every encrypted chat or Circle report sheet.
  static var whatIsShared: String {
    String(
      localized: "Catbird will see who sent this and when, not what it said. Reports never include message or post content.",
      comment: "Explanation on encrypted chat and Circle report sheets of what a report shares with Catbird."
    )
  }

  static var notConfigured: String {
    String(
      localized: "Reporting isn’t available yet. You can still block this account.",
      comment: "Error on an encrypted chat or Circle report sheet when Catbird's moderation service is not configured."
    )
  }

  static var sent: String {
    String(
      localized: "Report sent to Catbird.",
      comment: "Confirmation after an encrypted chat or Circle report is sent."
    )
  }

  /// One encrypted chat message, or the whole conversation when no message
  /// is named. Ids only, through the chat lexicon's ref types, which Ozone
  /// stores without fetching anything.
  static func chatSubject(
    senderDID: String, conversationID: String, messageID: String?
  ) throws -> ComAtprotoModerationCreateReport.InputSubjectUnion {
    let did = try DID(didString: senderDID)
    if let messageID, !messageID.isEmpty {
      let ref = ChatBskyConvoDefs.MessageRef(did: did, convoId: conversationID, messageId: messageID)
      return .unexpected(.knownType(ref))
    }
    let ref = ChatBskyConvoDefs.ConvoRef(did: did, convoId: conversationID)
    return .unexpected(.knownType(ref))
  }

  /// A Circle post, by URI and CID only.
  static func circlePostSubject(
    uri: ATProtocolURI, cid: CID
  ) -> ComAtprotoModerationCreateReport.InputSubjectUnion {
    .comAtprotoRepoStrongRef(ComAtprotoRepoStrongRef(uri: uri, cid: cid))
  }

  /// The report's `reason` field for a Circle post: which Circle, nothing else.
  static func circleReason(space: String) -> String {
    "Catbird Circle report. Circle: \(space)"
  }

  /// The report's `reason` field for an encrypted chat: a fixed label, nothing else.
  static let chatReason = "Catbird encrypted chat report"

  static func reasonType(for reason: CircleReportReason) -> ComAtprotoModerationDefs.ReasonType {
    switch reason {
    case .spam: return .comatprotomoderationdefsreasonspam
    case .abuse: return .comatprotomoderationdefsreasonrude
    case .other: return .comatprotomoderationdefsreasonother
    }
  }
}
