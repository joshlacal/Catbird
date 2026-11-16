import CatbirdMLSCore
import Foundation
import Observation

/// Whether this account can start an encrypted chat right now.
enum EncryptedChatSelfReadiness: Equatable, Sendable {
  case ready
  /// The one-time introduction has not been accepted yet.
  case needsIntroduction
  /// The user turned encrypted chat off in Settings > Chat.
  case turnedOff
  /// The account cannot use encrypted chat; `message` says why in plain words.
  case accountNotEligible(message: String)
}

extension EncryptedChatSelfReadiness {
  /// Readiness from the account's encrypted chat preference and eligibility.
  static func evaluate(
    runtimeAllowed: Bool, userTurnedOff: Bool, eligibilityProblem: String?
  ) -> EncryptedChatSelfReadiness {
    if !runtimeAllowed {
      return userTurnedOff ? .turnedOff : .needsIntroduction
    }
    if let eligibilityProblem { return .accountNotEligible(message: eligibilityProblem) }
    return .ready
  }
}

/// What the new conversation screen shows once a person is picked.
enum NewConversationKindState: Equatable, Sendable {
  case checking
  case capable
  case incapable
  case unknown
}

/// The handlers a kind choice runs. An encrypted-chat choice only ever reaches the encrypted
/// handlers; nothing here starts or sends into a Bluesky DM unless the user picked Bluesky DM.
struct NewConversationKindHandlers {
  var startEncrypted: @MainActor (NewConversationRecipient) async -> Void
  var startBluesky: @MainActor (NewConversationRecipient) async -> Void
  var presentIntroduction: @MainActor () -> Void
  var presentChatSettingsPointer: @MainActor () -> Void
  var presentAccountNotEligible: @MainActor (String) -> Void
}

/// The conversation-type choice for one picked person. The user always picks the type.
@MainActor
@Observable
final class NewConversationKindModel {
  static let incapableNotice = "Encrypted chat isn’t available for this person yet."
  static let unknownNotice = "Couldn’t check encrypted chat"

  let recipient: NewConversationRecipient
  private(set) var state: NewConversationKindState = .checking
  private(set) var isStarting = false

  @ObservationIgnored private let checkCapability: (String, Bool) async -> MLSChatCapability
  @ObservationIgnored private let selfReadiness: @MainActor () -> EncryptedChatSelfReadiness
  @ObservationIgnored private var generation = 0

  init(
    recipient: NewConversationRecipient,
    checkCapability: @escaping (String, Bool) async -> MLSChatCapability,
    selfReadiness: @escaping @MainActor () -> EncryptedChatSelfReadiness
  ) {
    self.recipient = recipient
    self.checkCapability = checkCapability
    self.selfReadiness = selfReadiness
  }

  /// The kinds offered, in order: encrypted first when the person can use it.
  var options: [ChatConversationKind] {
    state == .capable ? [.encrypted, .bluesky] : [.bluesky]
  }

  /// The one line shown when encrypted chat is not offered.
  var notice: String? {
    switch state {
    case .incapable: return Self.incapableNotice
    case .unknown: return Self.unknownNotice
    case .checking, .capable: return nil
    }
  }

  var canRetry: Bool { state == .unknown }

  func load() async {
    await check(forceRefresh: false)
  }

  /// Try again after a failed lookup; reads the person's records afresh.
  func retry() async {
    await check(forceRefresh: true)
  }

  private func check(forceRefresh: Bool) async {
    generation += 1
    let current = generation
    state = .checking
    let capability = await checkCapability(recipient.did, forceRefresh)
    guard current == generation, !Task.isCancelled else { return }
    switch capability {
    case .capable: state = .capable
    case .incapable: state = .incapable
    case .unknown: state = .unknown
    }
  }

  /// Runs the user's choice. Choosing encrypted chat never reaches the Bluesky handler: when
  /// this account is not ready it presents the introduction or a pointer to Chat Settings.
  func choose(_ kind: ChatConversationKind, handlers: NewConversationKindHandlers) async {
    guard options.contains(kind), !isStarting else { return }
    switch kind {
    case .bluesky:
      isStarting = true
      defer { isStarting = false }
      await handlers.startBluesky(recipient)
    case .encrypted:
      switch selfReadiness() {
      case .ready:
        isStarting = true
        defer { isStarting = false }
        await handlers.startEncrypted(recipient)
      case .needsIntroduction:
        handlers.presentIntroduction()
      case .turnedOff:
        handlers.presentChatSettingsPointer()
      case .accountNotEligible(let message):
        handlers.presentAccountNotEligible(message)
      }
    }
  }
}
