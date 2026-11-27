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
