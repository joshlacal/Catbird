import Foundation
import Petrel
import Testing

@testable import Catbird

// Subject builders: how labels on accounts and profile records reach a decision
// (port of subjects/account.ts and profile.ts).

@Suite("Moderation: subjects")
struct ModerationSubjectsTests {
  private let options = ModerationFixtures.options(adult: true, settings: ["porn": .hide, "nudity": .warn])

  // MARK: Account versus profile labels

  @Test("Profile-record labels are not account labels, except !no-unauthenticated")
  func accountLabelFiltering() throws {
    let account = try ModerationFixtures.accountLabel("porn", name: "alice")
    let profile = try ModerationFixtures.profileLabel("nudity", name: "alice")
    let noAuth = try ModerationFixtures.profileLabel("!no-unauthenticated", name: "alice")

    #expect(ModerationSubjects.filterAccountLabels([account, profile, noAuth]).map(\.val) == ["porn", "!no-unauthenticated"])
    #expect(ModerationSubjects.filterProfileLabels([account, profile, noAuth]).map(\.val) == ["nudity", "!no-unauthenticated"])
    #expect(ModerationSubjects.filterAccountLabels(nil).isEmpty)
    #expect(ModerationSubjects.filterProfileLabels(nil).isEmpty)
  }

  @Test("decideAccount uses account labels only; decideProfile uses profile-record labels only")
  func accountAndProfileSplit() throws {
    let labels = [
      try ModerationFixtures.accountLabel("porn", name: "alice"),
      try ModerationFixtures.profileLabel("nudity", name: "alice"),
    ]
    let subject = try ModerationFixtures.profile("alice", labels: labels)

    let account = ModerationSubjects.decideAccount(subject, options: options)
    #expect(account.causes.map(\.label.val) == ["porn"])
    #expect(account.causes.map(\.target) == [.account])

    let profile = ModerationSubjects.decideProfile(subject, options: options)
    #expect(profile.causes.map(\.label.val) == ["nudity"])
    #expect(profile.causes.map(\.target) == [.profile])

    let both = ModerationSubjects.decideProfileSubject(subject, options: options)
    #expect(both.causes.map(\.label.val) == ["porn", "nudity"])
    #expect(both.did == "did:web:alice.test")
  }

  @Test("Every profile view type conforms and behaves the same")
  func profileConformances() throws {
    let label = try ModerationFixtures.accountLabel("porn", name: "alice")
    let did = try DID(didString: "did:web:alice.test")
    let handle = try Handle(handleString: "alice.test")

    let basic = try ModerationFixtures.profile("alice", labels: [label])
    let view = AppBskyActorDefs.ProfileView(did: did, handle: handle, labels: [label])
    let detailed = AppBskyActorDefs.ProfileViewDetailed(did: did, handle: handle, labels: [label])
    let chat = ChatBskyActorDefs.ProfileViewBasic(did: did, handle: handle, labels: [label])

    func hidden(_ subject: some ModerationAccountSubject) -> Bool {
      #expect(subject.moderationDID == "did:web:alice.test")
      return ModerationSubjects.decideAccount(subject, options: options).ui(.profileList).filter
    }
    #expect(hidden(basic))
    #expect(hidden(view))
    #expect(hidden(detailed))
    #expect(hidden(chat))
  }

  @Test("An account with no labels yields an empty decision that still carries its DID")
  func emptyAccount() throws {
    let decision = ModerationSubjects.decideProfileSubject(try ModerationFixtures.profile("self"), options: options)
    #expect(decision.isEmpty)
    #expect(decision.did == ModerationFixtures.selfDID)
    #expect(decision.isMe)
  }
}
