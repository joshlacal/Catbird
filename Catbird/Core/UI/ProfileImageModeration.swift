import Foundation
import Petrel

// Moderation of profile images (avatars and banners) through the label engine.
// An image the engine blurs is never loaded: callers draw a neutral placeholder
// instead, and do not open the full-size viewer for it.

/// The account an avatar or banner belongs to, as the moderation engine sees it.
///
/// Callers pass the account DID when they have it. Without one, the DID is read
/// from the labels: an account label's URI is the DID and a profile-record
/// label's URI names it, so the account's own self-labels still count.
struct ProfileImageModerationSubject: ModerationAccountSubject {
  let moderationDID: String
  let moderationLabels: [ComAtprotoLabelDefs.Label]?

  init(did: String?, labels: [ComAtprotoLabelDefs.Label]?) {
    moderationLabels = labels
    if let did, !did.isEmpty {
      moderationDID = did
    } else {
      moderationDID = labels?.lazy.compactMap(Self.subjectDID(of:)).first ?? ""
    }
  }

  /// The account DID that a label on an account or on its profile record is
  /// about, or `nil` for a label on anything else.
  static func subjectDID(of label: ComAtprotoLabelDefs.Label) -> String? {
    let uri = label.uri.uriString()
    if uri.hasPrefix("did:") { return uri }

    let scheme = "at://"
    let suffix = ModerationSubjects.profileRecordURISuffix
    guard uri.hasPrefix(scheme), uri.hasSuffix(suffix), uri.count > scheme.count + suffix.count else { return nil }
    let authority = uri.dropFirst(scheme.count).dropLast(suffix.count)
    return authority.hasPrefix("did:") ? String(authority) : nil
  }
}

extension ModerationPolicy {
  /// Whether an account's avatar must stay a placeholder: the engine blurs it in
  /// the `avatar` context (account labels and profile-record labels merged).
  func concealsAvatar(did: String?, labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
    profileImageUI(.avatar, did: did, labels: labels).blur
  }

  /// Whether an account's banner must stay a placeholder (`banner` context).
  func concealsBanner(did: String?, labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
    profileImageUI(.banner, did: did, labels: labels).blur
  }

  /// The engine's UI result for one profile-image context. An account without
  /// labels skips the engine entirely.
  func profileImageUI(
    _ context: ModerationContext,
    did: String?,
    labels: [ComAtprotoLabelDefs.Label]?
  ) -> ModerationUI {
    guard let labels, !labels.isEmpty else { return .empty }
    return decide(profile: ProfileImageModerationSubject(did: did, labels: labels)).ui(context)
  }
}
