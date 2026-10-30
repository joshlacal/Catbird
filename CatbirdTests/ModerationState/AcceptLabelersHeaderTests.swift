import Foundation
import Petrel
import Testing

@testable import Catbird

/// `atproto-accept-labelers` follows `@atproto/api` (`Agent.appLabelers`): the Bluesky moderation
/// service is sent with `;redact`, so the AppView applies its takedowns; subscribed labelers are not.
@Suite("Accept-labelers header")
struct AcceptLabelersHeaderTests {
  private typealias Fixtures = ModerationStateFixtures

  @Test("Only the Bluesky moderation service is marked redact")
  func onlyBlueskyModerationServiceIsRedacted() {
    let labelers = PreferencesManager.acceptLabelers(subscribedDIDs: [Fixtures.customLabelerDID, Fixtures.secondLabelerDID])

    #expect(labelers.map(\.did) == [Fixtures.blueskyModerationDID, Fixtures.customLabelerDID, Fixtures.secondLabelerDID])
    #expect(labelers.map(\.redact) == [true, false, false])
  }

  @Test("The Bluesky moderation service is always first, never duplicated and stays redacted")
  func blueskyModerationServiceIsDeduplicated() {
    let labelers = PreferencesManager.acceptLabelers(
      subscribedDIDs: [Fixtures.customLabelerDID, Fixtures.blueskyModerationDID, Fixtures.customLabelerDID])

    #expect(labelers.map(\.did) == [Fixtures.blueskyModerationDID, Fixtures.customLabelerDID])
    #expect(labelers.filter(\.redact).map(\.did) == [Fixtures.blueskyModerationDID])
  }

  @Test("Without subscriptions only the Bluesky moderation service is sent")
  func noSubscriptions() {
    let labelers = PreferencesManager.acceptLabelers(subscribedDIDs: [])

    #expect(labelers.count == 1)
    #expect(labelers.first?.did == Fixtures.blueskyModerationDID)
    #expect(labelers.first?.redact == true)
  }

  @Test("The header is capped at 20 labelers and keeps the redacted service")
  func headerIsCapped() {
    let many = (0..<30).map { "did:plc:statefixturelabeler\($0)" }
    let labelers = PreferencesManager.acceptLabelers(subscribedDIDs: many)

    #expect(labelers.count == 20)
    #expect(labelers.first?.did == Fixtures.blueskyModerationDID)
    #expect(labelers.filter(\.redact).count == 1)
    #expect(labelers.last?.did == "did:plc:statefixturelabeler18")
  }

  @Test("Requests after a preference fetch carry the redact marker on the Bluesky moderation service only")
  @MainActor
  func outgoingHeaderMarksOnlyTheBlueskyService() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("header"))
    account.server.publishLabeler(did: Fixtures.customLabelerDID)
    account.server.setPreferences(adultContentEnabled: false, labelerDIDs: [Fixtures.customLabelerDID])

    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    await account.appState.awaitModerationDefinitionsLoad()

    // The labeler-definitions request is the first one sent after the header was applied.
    let services = try #require(account.server.requests(forPath: "getServices").first)
    #expect(services.acceptLabelers == "\(Fixtures.blueskyModerationDID);redact, \(Fixtures.customLabelerDID)")
    #expect(account.appState.preferencesManager.appliedAcceptLabelerDIDs
      == [Fixtures.blueskyModerationDID, Fixtures.customLabelerDID])
  }
}
