import Foundation
import Testing
import UserNotifications
@testable import Catbird

@Suite("SignedOutPushSuppression policy and publication")
struct SignedOutPushSuppressionTests {
  static let accountA = "did:plc:fixtureaccounta"
  static let accountB = "did:plc:fixtureaccountb"
  static let accountC = "did:plc:fixtureaccountc"

  @Test("A signed-out presence suppresses every push")
  func noSignedInAccountSuppressesEveryPush() {
    #expect(
      SignedOutPushSuppression.suppresses(
        recipientDID: nil, presence: .signedOut, sessionEndedAccountDIDs: []))
    #expect(
      SignedOutPushSuppression.suppresses(
        recipientDID: Self.accountA, presence: .signedOut, sessionEndedAccountDIDs: []))
  }

  @Test("An unknown presence (launch) never suppresses")
  @MainActor
  func launchNeverSuppresses() {
    #expect(
      !SignedOutPushSuppression.suppresses(
        recipientDID: Self.accountA, presence: .unknown, sessionEndedAccountDIDs: [Self.accountA]))
    #expect(
      SignedOutPushSuppression.presence(
        for: .launching, registeredAccountDIDs: [Self.accountA], sessionEndedAccountDIDs: []) == .unknown)
  }

  @Test("The sign-in screen is signed out only when no stored account is still signed in")
  @MainActor
  func signInScreenPresence() {
    // Nothing stored, or every stored account's session ended
    #expect(
      SignedOutPushSuppression.presence(
        for: .unauthenticated, registeredAccountDIDs: [], sessionEndedAccountDIDs: []) == .signedOut)
    #expect(
      SignedOutPushSuppression.presence(
        for: .unauthenticated,
        registeredAccountDIDs: [Self.accountA, Self.accountB],
        sessionEndedAccountDIDs: [Self.accountB, Self.accountA]) == .signedOut)
    // A signed out (or expired) while B stays stored and signed in
    #expect(
      SignedOutPushSuppression.presence(
        for: .unauthenticated,
        registeredAccountDIDs: [Self.accountA, Self.accountB],
        sessionEndedAccountDIDs: [Self.accountA]) == .noActiveAccount)
  }

  @Test("With no active account only a recipient whose session ended is suppressed")
  func noActiveAccountSuppressesOnlyEndedRecipients() {
    #expect(
      SignedOutPushSuppression.suppresses(
        recipientDID: Self.accountA, presence: .noActiveAccount, sessionEndedAccountDIDs: [Self.accountA]))
    #expect(
      !SignedOutPushSuppression.suppresses(
        recipientDID: Self.accountB, presence: .noActiveAccount, sessionEndedAccountDIDs: [Self.accountA]))
    #expect(
      !SignedOutPushSuppression.suppresses(
        recipientDID: nil, presence: .noActiveAccount, sessionEndedAccountDIDs: [Self.accountA]))
  }

  @Test("The named recipient comes from the fields the extension and older payloads set")
  func namedRecipient() {
    #expect(SignedOutPushSuppression.namedRecipientDID(in: ["recipientDid": Self.accountA]) == Self.accountA)
    #expect(SignedOutPushSuppression.namedRecipientDID(in: ["recipient_did": Self.accountB]) == Self.accountB)
    #expect(SignedOutPushSuppression.namedRecipientDID(in: ["recipient_account": "hash"]) == nil)
  }

  @Test("The signed-in recipient is shown even if listed as ended")
  func signedInRecipientIsShownEvenIfListedEnded() {
    #expect(
      !SignedOutPushSuppression.suppresses(
        recipientDID: Self.accountA,
        presence: .signedIn(accountDID: Self.accountA),
        sessionEndedAccountDIDs: [Self.accountA]))
  }

  @Test("An ended recipient under another signed-in account is suppressed")
  func endedRecipientUnderAnotherAccountIsSuppressed() {
    #expect(
      SignedOutPushSuppression.suppresses(
        recipientDID: Self.accountA,
        presence: .signedIn(accountDID: Self.accountB),
        sessionEndedAccountDIDs: [Self.accountA]))
  }

  @Test("An unrelated or unnamed recipient keeps current delivery behavior")
  func unrelatedOrUnnamedRecipientKeepsCurrentBehavior() {
    #expect(
      !SignedOutPushSuppression.suppresses(
        recipientDID: Self.accountC,
        presence: .signedIn(accountDID: Self.accountB),
        sessionEndedAccountDIDs: [Self.accountA]))
    #expect(
      !SignedOutPushSuppression.suppresses(
        recipientDID: nil,
        presence: .signedIn(accountDID: Self.accountB),
        sessionEndedAccountDIDs: [Self.accountA]))
  }

  @Test("Publish tracks sign-out and sign-in without recording an ended session")
  func publishTracksSignOutAndSignIn() {
    let suiteName = "PushSuppressionTest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Start with sign-in A
    SignedOutPushSuppression.publish(.signedIn(accountDID: Self.accountA), in: defaults)
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == Self.accountA)
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))

    // Signed-out presence alone is no session end: a failed switch or a launch without a
    // current account also reaches it with every stored session intact.
    SignedOutPushSuppression.publish(.signedOut, in: defaults)
    #expect(defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == nil)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [])

    // A real session end is recorded explicitly
    SignedOutPushSuppression.recordSessionEndedAccount(Self.accountA, in: defaults)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])

    // No active account while another stored account is signed in: not every account is signed out
    SignedOutPushSuppression.publish(.noActiveAccount, in: defaults)
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == nil)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])

    // Sign in to B
    SignedOutPushSuppression.publish(.signedIn(accountDID: Self.accountB), in: defaults)
    #expect(!defaults.bool(forKey: SignedOutPushSuppression.signedOutKey))
    #expect(defaults.string(forKey: SignedOutPushSuppression.pushActiveAccountDIDKey) == Self.accountB)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [Self.accountA])

    // Sign in to A again (clears A from ended list)
    SignedOutPushSuppression.publish(.signedIn(accountDID: Self.accountA), in: defaults)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == [])

    // The widgets' and App Intents' "an account is signed in" key belongs to the account list
    #expect(defaults.object(forKey: "activeAccountDID") == nil)

    // Test bounded limit and deduplication
    for i in 1...20 {
      SignedOutPushSuppression.recordSessionEndedAccount("did:plc:account\(i)", in: defaults)
    }
    let ended = SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults)
    #expect(ended.count == SignedOutPushSuppression.sessionEndedAccountLimit)
    #expect(ended.first == "did:plc:account5")
    #expect(ended.last == "did:plc:account20")

    // Adding existing moves it to the end
    SignedOutPushSuppression.recordSessionEndedAccount("did:plc:account5", in: defaults)
    let reordered = SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults)
    #expect(reordered.count == SignedOutPushSuppression.sessionEndedAccountLimit)
    #expect(reordered.last == "did:plc:account5")

    // Malformed values ignored
    SignedOutPushSuppression.recordSessionEndedAccount("", in: defaults)
    SignedOutPushSuppression.recordSessionEndedAccount("   ", in: defaults)
    SignedOutPushSuppression.recordSessionEndedAccount("notadid", in: defaults)
    #expect(SignedOutPushSuppression.sessionEndedAccountDIDs(in: defaults) == reordered)
  }
}

@Suite("Foreground notification presentation filtering")
struct NotificationForegroundPresentationTests {
  static let accountA = "did:plc:fixtureaccounta"
  static let accountB = "did:plc:fixtureaccountb"
  static let accountC = "did:plc:fixtureaccountc"

  @Test("Encrypted chat pushes follow the same signed-out rules as every other push")
  func encryptedChatSignedOutSuppression() {
    let mlsPush: [AnyHashable: Any] = ["type": "mls_message", "convo_id": "group"]
    #expect(NotificationManager.isSuppressedForSignedOutAccount(
      userInfo: mlsPush, recipientDID: Self.accountA, presence: .signedOut, sessionEndedAccountDIDs: []))
    #expect(NotificationManager.isSuppressedForSignedOutAccount(
      userInfo: mlsPush, recipientDID: Self.accountA, presence: .signedIn(accountDID: Self.accountB),
      sessionEndedAccountDIDs: [Self.accountA]))
    #expect(!NotificationManager.isSuppressedForSignedOutAccount(
      userInfo: mlsPush, recipientDID: Self.accountA, presence: .signedIn(accountDID: Self.accountA),
      sessionEndedAccountDIDs: [Self.accountA]))
    #expect(!NotificationManager.isSuppressedForSignedOutAccount(
      userInfo: mlsPush, recipientDID: Self.accountC, presence: .signedIn(accountDID: Self.accountB),
      sessionEndedAccountDIDs: [Self.accountA]))
  }

  @Test("Notifications tagged as suppressed for signed out account return empty options")
  func suppressionMarkerYieldsEmptyOptions() {
    let options = NotificationManager.foregroundPresentationOptions(
      userInfo: ["suppressedForSignedOutAccount": true, "type": "chat_message"],
      recipientDID: Self.accountA,
      presence: .signedIn(accountDID: Self.accountA),
      sessionEndedAccountDIDs: [],
      openConversationID: nil
    )
    #expect(options.isEmpty)
  }

  @Test("Active conversation chat is suppressed in foreground")
  func activeConversationSuppression() {
    let options = NotificationManager.foregroundPresentationOptions(
      userInfo: ["type": "chat_message", "convoId": "open-convo"],
      recipientDID: Self.accountA,
      presence: .signedIn(accountDID: Self.accountA),
      sessionEndedAccountDIDs: [],
      openConversationID: "open-convo"
    )
    #expect(options.isEmpty)
  }

  @Test("Standard push for active account presents banner and sound")
  func standardPushPresents() {
    let options = NotificationManager.foregroundPresentationOptions(
      userInfo: ["reason": "like", "actorDid": "did:plc:liker"],
      recipientDID: Self.accountA,
      presence: .signedIn(accountDID: Self.accountA),
      sessionEndedAccountDIDs: [],
      openConversationID: nil
    )
    #expect(options == [.banner, .sound])
  }

  @Test("On the sign-in screen a still-signed-in account's push shows and an ended one's does not")
  func noActiveAccountForegroundPresentation() {
    let signedIn = NotificationManager.foregroundPresentationOptions(
      userInfo: ["type": "chat_message", "convoId": "other-convo"],
      recipientDID: Self.accountB,
      presence: .noActiveAccount,
      sessionEndedAccountDIDs: [Self.accountA],
      openConversationID: nil
    )
    #expect(signedIn == [.banner, .sound])

    let ended = NotificationManager.foregroundPresentationOptions(
      userInfo: ["type": "chat_message", "convoId": "other-convo"],
      recipientDID: Self.accountA,
      presence: .noActiveAccount,
      sessionEndedAccountDIDs: [Self.accountA],
      openConversationID: nil
    )
    #expect(ended.isEmpty)
  }

  @Test("Signed-out presence hides foreground notifications")
  func signedOutDeviceHidesForegroundPush() {
    let options = NotificationManager.foregroundPresentationOptions(
      userInfo: ["reason": "like", "actorDid": "did:plc:liker"],
      recipientDID: Self.accountA,
      presence: .signedOut,
      sessionEndedAccountDIDs: [],
      openConversationID: nil
    )
    #expect(options.isEmpty)
  }

  @Test("Ended account push is hidden while another account is active")
  func endedAccountHiddenUnderAnotherAccount() {
    let options = NotificationManager.foregroundPresentationOptions(
      userInfo: ["type": "chat_message", "convoId": "other-convo"],
      recipientDID: Self.accountA,
      presence: .signedIn(accountDID: Self.accountB),
      sessionEndedAccountDIDs: [Self.accountA],
      openConversationID: nil
    )
    #expect(options.isEmpty)

    // Unrelated account C is not hidden
    let optionsC = NotificationManager.foregroundPresentationOptions(
      userInfo: ["type": "chat_message", "convoId": "other-convo"],
      recipientDID: Self.accountC,
      presence: .signedIn(accountDID: Self.accountB),
      sessionEndedAccountDIDs: [Self.accountA],
      openConversationID: nil
    )
    #expect(optionsC == [.banner, .sound])
  }
}
