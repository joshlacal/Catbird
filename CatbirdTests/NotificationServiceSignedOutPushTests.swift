import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import Catbird

/// Executes the shipped extension class with local notification requests and isolated
/// defaults. Chat fixtures omit senderDid, so no profile lookup or keychain access occurs.
@Suite("NSE current delivery characterization")
struct NotificationServiceDeliveryCharacterizationTests {
  /// Encrypted chat pushes are gated off only in builds without MLS chat; with it on, they are
  /// decrypted, which needs the extension's MLS storage, so this runs only where the gate is off.
  @Test("Default initialization still neutralizes gated-off features", .enabled(if: !CatbirdFeatures.mlsChat))
  func defaultInitializationKeepsUnsupportedFiltering() async {
    let service = NotificationService()
    let output = await PushServiceFixture.deliver(
      PushServiceFixture.request(type: "mls_message"), through: service)
    #expect(output.title == "Catbird")
    #expect(output.body == "New activity")
    #expect(output.sound == nil)
    #expect(output.userInfo["type"] as? String == "mls_message")
  }

  @Test("An unreadable App Group keeps existing chat delivery")
  func unavailableDefaultsKeepChatDelivery() async {
    let output = await PushServiceFixture.deliver(
      PushServiceFixture.request(), through: NotificationService(appGroupDefaults: nil))
    #expect(output.title == "Alice")
    #expect(output.body == "private message")
    #expect(output.categoryIdentifier == "CHAT_MESSAGE")
    #expect(output.userInfo["recipientDid"] as? String == PushServiceFixture.accountA)
  }

  @Test("A legacy recipient hash resolves only against published known accounts")
  func legacyHashResolution() async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "knownAccountDIDs")
    let request = PushServiceFixture.request(recipientField: "recipient_account")
    let output = await fixture.deliver(request)
    #expect(output.userInfo["recipientDid"] as? String == PushServiceFixture.accountA)
    #expect(output.body == "private message")
  }

  @Test("A still-signed-in known account keeps chat delivery while another account is active",
    arguments: ["recipientDid", "recipient_did", "recipient_account"])
  func knownInactiveAccountKeepsDelivery(recipientField: String) async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set(PushServiceFixture.accountB, forKey: "pushActiveAccountDID")
    fixture.defaults.set([PushServiceFixture.accountA, PushServiceFixture.accountB], forKey: "knownAccountDIDs")
    fixture.defaults.set([], forKey: "sessionEndedPushAccountDIDs")
    let output = await fixture.deliver(PushServiceFixture.request(recipientField: recipientField))
    #expect(output.title == "Alice")
    #expect(output.body == "private message")
    #expect(output.categoryIdentifier == "CHAT_MESSAGE")
    #expect(output.userInfo["recipientDid"] as? String == PushServiceFixture.accountA)
    #expect(output.userInfo["convoId"] as? String == "private-conversation")
    #expect(output.userInfo["suppressedForSignedOutAccount"] == nil)
  }

  @Test("Missing and unmatched recipients are never guessed", arguments: [nil, "unmatched"] as [String?])
  func absentRecipientIsNotGuessed(recipient: String?) async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "knownAccountDIDs")
    let content = UNMutableNotificationContent()
    content.title = "Alice"
    content.body = "private message"
    // The extension writes the body from messageText, as Nest sends it.
    content.userInfo = ["type": "chat_message", "convoId": "conversation", "messageText": "private message"]
    if let recipient { content.userInfo["recipient_account"] = recipient }
    let output = await fixture.deliver(UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil))
    #expect(output.userInfo["recipientDid"] == nil)
    #expect(output.body == "private message")
  }
}

@Suite("NSE signed-out push protection")
struct NotificationServiceSignedOutPushTests {
  @Test("A known sign-out removes private chat display and tap routing")
  func signedOutChatIsNeutralized() async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set(true, forKey: "signedOutForPush")
    let output = await fixture.deliver(PushServiceFixture.request())
    assertNeutralized(output)
  }

  @Test("Ended A is hidden while B is active for every supported recipient shape",
    arguments: ["recipientDid", "recipient_did", "recipient_account"])
  func endedRecipientUnderAnotherAccount(recipientField: String) async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set(PushServiceFixture.accountB, forKey: "pushActiveAccountDID")
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "sessionEndedPushAccountDIDs")
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "knownAccountDIDs")
    let output = await fixture.deliver(PushServiceFixture.request(recipientField: recipientField))
    assertNeutralized(output)
  }

  @Test("An ended recipient hash remains resolvable after the account leaves known accounts")
  func endedRecipientHashSurvivesAccountRemoval() async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set(PushServiceFixture.accountB, forKey: "pushActiveAccountDID")
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "sessionEndedPushAccountDIDs")
    fixture.defaults.set([PushServiceFixture.accountB], forKey: "knownAccountDIDs")
    let output = await fixture.deliver(PushServiceFixture.request(recipientField: "recipient_account"))
    assertNeutralized(output)
  }

  @Test("The widgets' activeAccountDID is not the push active account")
  func widgetActiveAccountDoesNotExemptEndedRecipient() async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    // A left in the widget key must not exempt A's pushes while B is the push active account
    fixture.defaults.set(PushServiceFixture.accountA, forKey: "activeAccountDID")
    fixture.defaults.set(PushServiceFixture.accountB, forKey: "pushActiveAccountDID")
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "sessionEndedPushAccountDIDs")
    let output = await fixture.deliver(PushServiceFixture.request())
    assertNeutralized(output)
  }

  @Test("The active recipient is delivered even if an old ended entry remains")
  func activeRecipientIsDelivered() async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set(PushServiceFixture.accountA, forKey: "pushActiveAccountDID")
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "sessionEndedPushAccountDIDs")
    let output = await fixture.deliver(PushServiceFixture.request())
    #expect(output.body == "private message")
    #expect(output.categoryIdentifier == "CHAT_MESSAGE")
  }

  @Test("With no active account a recipient whose session ended is hidden")
  func noActiveAccountHidesEndedRecipient() async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "sessionEndedPushAccountDIDs")
    fixture.defaults.set([PushServiceFixture.accountA, PushServiceFixture.accountB], forKey: "knownAccountDIDs")
    // The widgets' key may still name A; it is not the push active account
    fixture.defaults.set(PushServiceFixture.accountA, forKey: "activeAccountDID")
    let output = await fixture.deliver(PushServiceFixture.request())
    assertNeutralized(output)
  }

  @Test("With no active account a stored account that is still signed in keeps delivery",
    arguments: ["recipientDid", "recipient_did", "recipient_account"])
  func noActiveAccountKeepsSignedInRecipient(recipientField: String) async {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    // A signed out (or expired) on the sign-in screen; B is stored, signed in and registered
    fixture.defaults.set([PushServiceFixture.accountA], forKey: "sessionEndedPushAccountDIDs")
    fixture.defaults.set([PushServiceFixture.accountA, PushServiceFixture.accountB], forKey: "knownAccountDIDs")
    let output = await fixture.deliver(PushServiceFixture.request(
      recipientField: recipientField, recipient: PushServiceFixture.accountB))
    #expect(output.title == "Alice")
    #expect(output.body == "private message")
    #expect(output.categoryIdentifier == "CHAT_MESSAGE")
    #expect(output.userInfo["recipientDid"] as? String == PushServiceFixture.accountB)
    #expect(output.userInfo["suppressedForSignedOutAccount"] == nil)
  }

  @Test("Sign-out neutralizes all visible and routing fields even on non-chat mutable pushes")
  func signedOutSocialContentIsNeutralized() async throws {
    let fixture = PushServiceFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set(true, forKey: "signedOutForPush")
    let request = PushServiceFixture.request(type: "social")
    let content = request.content.mutableCopy() as! UNMutableNotificationContent
    content.userInfo["senderDid"] = "did:plc:privatesender"
    content.userInfo["uri"] = "at://did:plc:privatesender/app.bsky.feed.post/private"
    content.userInfo["aps"] = ["alert": ["title": "private title", "body": "private message"]]
    let imageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    let imageURL = imageDirectory.appendingPathComponent("private.png")
    let imageData = try #require(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII="))
    try imageData.write(to: imageURL)
    content.attachments = [try UNNotificationAttachment(identifier: "private-avatar", url: imageURL, options: nil)]
    let output = await fixture.deliver(UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil))
    assertNeutralized(output)
    #expect(output.userInfo["senderDid"] == nil)
    #expect(output.userInfo["uri"] == nil)
    #expect(output.userInfo["aps"] == nil)
  }

  private func assertNeutralized(_ output: UNNotificationContent) {
    #expect(output.title == "Catbird")
    #expect(output.subtitle.isEmpty)
    #expect(output.body == "New activity")
    #expect(output.sound == nil)
    #expect(output.badge == nil)
    #expect(output.interruptionLevel == .passive)
    #expect(output.relevanceScore == 0)
    #expect(output.attachments.isEmpty)
    #expect(!output.threadIdentifier.contains("private"))
    #expect(output.categoryIdentifier.isEmpty)
    #expect(output.targetContentIdentifier == nil)
    #expect(output.launchImageName.isEmpty)
    #expect(output.userInfo["messageText"] == nil)
    #expect(output.userInfo["recipientDid"] == nil)
    #expect(output.userInfo["recipient_did"] == nil)
    #expect(output.userInfo["recipient_account"] == nil)
    #expect(output.userInfo["convoId"] == nil)
    #expect(output.userInfo["suppressedForSignedOutAccount"] as? Bool == true)
  }
}

private struct PushServiceFixture {
  static let accountA = "did:plc:fixtureaccounta"
  static let accountB = "did:plc:fixtureaccountb"
  let suiteName = "NotificationServiceSignedOutPush-\(UUID().uuidString)"
  let defaults: UserDefaults

  init() {
    defaults = UserDefaults(suiteName: suiteName)!
  }

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
  }

  func deliver(_ request: UNNotificationRequest) async -> UNNotificationContent {
    await Self.deliver(request, through: NotificationService(appGroupDefaults: defaults))
  }

  static func deliver(_ request: UNNotificationRequest, through service: NotificationService) async
    -> UNNotificationContent
  {
    let output: UNNotificationContent = await withCheckedContinuation { continuation in
      service.didReceive(request) { continuation.resume(returning: $0) }
    }
    withExtendedLifetime(service) {}
    return output
  }

  static func request(
    type: String = "chat_message", recipientField: String = "recipientDid",
    recipient: String = PushServiceFixture.accountA
  ) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "Alice"
    content.subtitle = "Private conversation"
    content.body = "private message"
    content.sound = .default
    content.badge = 7
    content.interruptionLevel = .timeSensitive
    content.relevanceScore = 0.9
    content.threadIdentifier = "private-thread"
    content.categoryIdentifier = "PRIVATE_ACTIONS"
    content.targetContentIdentifier = "private-target"
    content.launchImageName = "private-image"
    let recipientValue = recipientField == "recipient_account"
      ? SHA256.hash(data: Data(recipient.utf8)).map { String(format: "%02x", $0) }.joined()
      : recipient
    content.userInfo = [
      "type": type,
      "messageText": "private message",
      "convoId": "private-conversation",
      recipientField: recipientValue,
    ]
    return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
  }
}
