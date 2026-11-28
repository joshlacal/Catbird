import Foundation
import CatbirdMLSCore
import Testing
@testable import Catbird

/// A chat deleted "for me" comes back when the other person writes again, as in Messages and Signal.
@Suite("MLS Deleted For Me Tests")
struct MLSDeletedForMeTests {
  private let account = "did:plc:AccountAAAAAAAAAAAAAAAAAA"
  private let convo = "11111111-1111-4111-8111-111111111111"
  private let other = "22222222-2222-4222-8222-222222222222"

  private func freshDefaults() -> UserDefaults {
    let name = "MLSDeletedForMeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func store(_ defaults: UserDefaults, now: Date = Date(timeIntervalSince1970: 1_000)) -> MLSDeletedForMe {
    MLSDeletedForMe(accountDID: account, defaults: defaults, now: { now })
  }

  @Test("A deleted chat with no newer message stays hidden")
  func staysHiddenWithoutNewMessage() {
    let defaults = freshDefaults()
    store(defaults).hide(convo)
    #expect(store(defaults).isHidden(convo, latestMessageAt: Date(timeIntervalSince1970: 999)))
    #expect(store(defaults).isHidden(convo, latestMessageAt: nil))
    #expect(!store(defaults).isHidden(other, latestMessageAt: nil))
  }

  @Test("A message that arrives after the deletion brings the chat back and clears the mark")
  func newerMessageReveals() {
    let defaults = freshDefaults()
    store(defaults).hide(convo)
    let later = Date(timeIntervalSince1970: 1_001)
    #expect(!store(defaults).isHidden(convo, latestMessageAt: later))
    // Cleared: an older latest message no longer hides it.
    #expect(!store(defaults).isHidden(convo, latestMessageAt: nil))
  }

  @Test("Starting a chat with the person reveals it")
  func revealClears() {
    let defaults = freshDefaults()
    store(defaults).hide(convo)
    store(defaults).reveal(convo)
    #expect(!store(defaults).isHidden(convo, latestMessageAt: nil))
  }

  @Test("Old deletions without a time are kept hidden until the next message after the upgrade")
  func legacyListMigrates() {
    let defaults = freshDefaults()
    defaults.set([convo], forKey: "mls.deletedForMe.\(account.lowercased())")

    let upgradedAt = Date(timeIntervalSince1970: 5_000)
    #expect(store(defaults, now: upgradedAt).isHidden(convo, latestMessageAt: Date(timeIntervalSince1970: 4_000)))
    #expect(defaults.object(forKey: "mls.deletedForMe.\(account.lowercased())") == nil)
    #expect(!store(defaults, now: upgradedAt).isHidden(convo, latestMessageAt: Date(timeIntervalSince1970: 5_001)))
  }

  @Test("Each account keeps its own deletions")
  func perAccount() {
    let defaults = freshDefaults()
    store(defaults).hide(convo)
    let otherAccount = MLSDeletedForMe(accountDID: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb", defaults: defaults)
    #expect(!otherAccount.isHidden(convo, latestMessageAt: nil))
  }

  private func message(seq: Int64, at seconds: TimeInterval, _ payload: MLSMessagePayload) throws -> MLSMessageModel {
    MLSMessageModel(
      messageID: "m\(seq)",
      conversationID: convo,
      currentUserDID: account,
      senderID: "did:plc:peerpeerpeerpeerpeerpeer",
      plaintextJSON: try payload.encodeToJSON(),
      epoch: 1,
      sequenceNumber: seq,
      timestamp: Date(timeIntervalSince1970: seconds),
      isOwn: false
    )
  }

  /// Newest-first pages of `messages`, like `listMessages(beforeSeq:limit:)`.
  private func pages(_ messages: [MLSMessageModel], size: Int) -> (Int64) async throws -> [MLSMessageModel] {
    { beforeSeq in
      Array(messages.filter { $0.sequenceNumber < beforeSeq }.sorted { $0.sequenceNumber > $1.sequenceNumber }.prefix(size))
    }
  }

  @Test("A text behind many reactions still brings the chat back")
  func searchesPastPreviewWindow() async throws {
    let defaults = freshDefaults()
    store(defaults).hide(convo)
    var all = [try message(seq: 1, at: 900, .text("before")), try message(seq: 2, at: 1_001, .text("hello again"))]
    for seq in Int64(3)...30 {
      all.append(try message(seq: seq, at: 1_001 + Double(seq), .reaction(messageId: "m2", emoji: "👍", action: .add)))
    }
    let newestFirst = all.sorted { $0.sequenceNumber > $1.sequenceNumber }
    let hidden = await store(defaults).isHidden(convo, newestFirst: Array(newestFirst.prefix(20)), olderThan: pages(all, size: 5))
    #expect(!hidden)
    #expect(!store(defaults).isHidden(convo, latestMessageAt: nil))
  }

  @Test("The search stops at messages older than the deletion")
  func searchStopsAtDeletion() async throws {
    let defaults = freshDefaults()
    store(defaults).hide(convo)
    var all = [try message(seq: 1, at: 900, .text("before"))]
    for seq in Int64(2)...25 {
      all.append(try message(seq: seq, at: 1_000 + Double(seq), .reaction(messageId: "m1", emoji: "👍", action: .add)))
    }
    let newestFirst = all.sorted { $0.sequenceNumber > $1.sequenceNumber }
    let hidden = await store(defaults).isHidden(convo, newestFirst: Array(newestFirst.prefix(20)), olderThan: pages(all, size: 5))
    #expect(hidden)
  }

  @Test("Only a new text or photo brings a chat back")
  func whichMessagesCount() {
    #expect(MLSDeletedForMe.bringsChatBack(.text("hello")))
    #expect(!MLSDeletedForMe.bringsChatBack(.text("")))
    #expect(!MLSDeletedForMe.bringsChatBack(.reaction(messageId: "m", emoji: "👍", action: .add)))
    #expect(!MLSDeletedForMe.bringsChatBack(.readReceipt(messageId: "m")))
    #expect(!MLSDeletedForMe.bringsChatBack(.typing(isTyping: true)))
    #expect(!MLSDeletedForMe.bringsChatBack(nil))
  }
}
