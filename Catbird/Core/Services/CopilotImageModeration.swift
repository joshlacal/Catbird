import Foundation
import Observation
import Petrel

/// A live decision for one account, post and sheet context. Never saved in history.
struct CopilotImageModerationSnapshot: Equatable, Sendable {
  let context: CopilotContext
  let accountDID: String
  let accountRevision: UInt64
  let clientID: ObjectIdentifier?
  let policy: ModerationPolicy
  let presentation: PostModerationPresentation
  let rowVisible: Bool

  var imageUI: ModerationUI { presentation.body.merged(with: presentation.media) }

  func allows(_ reveal: ModerationRevealState) -> Bool {
    rowVisible && !imageUI.noOverride && (!imageUI.blur || reveal.isRevealed(imageUI))
  }

  static func make(
    context: CopilotContext, accountDID: String, accountRevision: UInt64,
    clientID: ObjectIdentifier?, post: AppBskyFeedDefs.PostView, policy: ModerationPolicy,
    revealedFilter: String?, listFilterExemptDID: String? = nil
  ) -> Self? {
    guard !accountDID.isEmpty, policy.accountDID == accountDID,
          case .post(let uri, let cid, let author, _, let evidence?) = context,
          uri == post.uri.uriString(), cid == post.cid.string,
          author == post.author.did.didString(),
          evidence == CopilotPostEvidenceBuilder.build(post) else { return nil }
    let presentation = PostModerationPresentation.make(
      post: post, policy: policy, surface: .contentList, listFilterExemptDID: listFilterExemptDID)
    return Self(context: context, accountDID: accountDID, accountRevision: accountRevision,
      clientID: clientID, policy: policy, presentation: presentation,
      rowVisible: !presentation.hidesRow || revealedFilter == presentation.filterIdentity)
  }
}

/// The bridge reads observable account/policy/post state each time, never a
/// captured moderation decision. Missing bridges deny images by default.
struct CopilotImageModerationSource: Sendable {
  let read: @MainActor @Sendable (CopilotContext, String) -> CopilotImageModerationSnapshot?

  @MainActor
  func authorization(
    snapshot: CopilotImageModerationSnapshot?, revealSession: CopilotImageRevealSession
  ) -> CopilotImageAuthorization {
    guard let snapshot else { return .denied }
    let reveal = revealSession.reveal(for: snapshot)
    guard snapshot.allows(reveal) else { return .denied }
    let revision = revealSession.revision
    return CopilotImageAuthorization { context, accountDID in
      context == snapshot.context && accountDID == snapshot.accountDID
        && revealSession.revision == revision
        && self.read(context, accountDID) == snapshot && snapshot.allows(reveal)
    }
  }
}

/// A deliberate Hide revokes outstanding grants synchronously, before task
/// cancellation propagates. Reveal permissions never outlive this sheet session.
@MainActor @Observable
final class CopilotImageRevealSession {
  private(set) var revision: UInt64 = 0
  private var snapshot: CopilotImageModerationSnapshot?
  private var state = ModerationRevealState()

  func reveal(for current: CopilotImageModerationSnapshot?) -> ModerationRevealState {
    snapshot == current ? state : ModerationRevealState()
  }

  func show(_ snapshot: CopilotImageModerationSnapshot) {
    guard snapshot.rowVisible, !snapshot.imageUI.noOverride else { return }
    revision &+= 1
    self.snapshot = snapshot
    state.show(snapshot.imageUI)
  }

  func hide() {
    revision &+= 1
    snapshot = nil
    state.hide()
  }
}

/// Rechecked at the pixel boundaries. A prior selection or saved context is
/// never itself authorization to fetch, tokenize or generate with an image.
struct CopilotImageAuthorization: Sendable {
  let permits: @MainActor @Sendable (CopilotContext, String) -> Bool
  static let denied = Self { _, _ in false }

  func require(context: CopilotContext, accountDID: String) async throws {
    try Task.checkCancellation()
    guard await permits(context, accountDID) else { throw CancellationError() }
    try Task.checkCancellation()
  }
}
