import Foundation
import Petrel
import SwiftData
import SwiftUI
import Testing

@testable import Catbird

/// AppState owns one moderation policy per account. These suites drive the production path: canned
/// preference and labeler-service responses go through a real `ATProtoClient`, then
/// `PreferencesManager` and `AppState.refreshModerationPolicy()` build the policy.
@Suite("Moderation policy state", .serialized)
@MainActor
struct ModerationPolicyStateTests {
  private typealias Fixtures = ModerationStateFixtures

  private func pornPost() throws -> AppBskyFeedDefs.PostView {
    try ModerationStatePosts.post(labeled: "porn")
  }

  /// Identifiers of the custom definitions the policy holds for one labeler.
  private func definitionIDs(_ state: AppState, labeler: String) -> [String] {
    state.moderationPolicy.labelDefinitions[labeler]?.map(\.identifier) ?? []
  }

  private func subscribedLabelerDIDs(_ state: AppState) -> [String] {
    state.moderationPolicy.prefs.labelers.map(\.did)
  }

  private func blurs(_ state: AppState, _ post: AppBskyFeedDefs.PostView) -> Bool {
    state.moderationPolicy.decide(post: post).ui(.contentList).blur
  }

  // MARK: - Account switch

  @Test("Each account's policy comes from its own confirmed state, before and after its fetch")
  func accountSwitchReflectsTheNewAccountImmediately() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let didA = Fixtures.uniqueDID("switcha")
    let didB = Fixtures.uniqueDID("switchb")
    // Both accounts finished a confirmed fetch in an earlier session.
    try harness.persistRow(
      did: didA, adultContentEnabled: true,
      contentLabelPrefs: [ContentLabelPreference(labelerDid: nil, label: "porn", visibility: "ignore")],
      confirmed: true)
    try harness.persistRow(did: didB, adultContentEnabled: false, confirmed: true)
    let a = try await harness.makeAccount(did: didA)
    let b = try await harness.makeAccount(did: didB)
    a.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "ignore")])
    b.server.setPreferences(adultContentEnabled: false)
    let post = try pornPost()

    // Account A is active: adult content on, porn set to ignore, so the post is kept.
    #expect(a.appState.moderationPolicy.accountDID == didA)
    #expect(a.appState.isAdultContentEnabled)
    #expect(!a.appState.moderationPolicy.listFilter(post: post))

    // Switch to B. The activation path rebuilds the policy from B's own row before any network work.
    b.appState.refreshModerationPolicy()
    #expect(b.appState.moderationPolicy.accountDID == didB)
    #expect(b.appState.moderationPolicy.isConfirmed)
    #expect(!b.appState.moderationPolicy.adultContentEnabled)
    #expect(!b.appState.isAdultContentEnabled)
    #expect(b.appState.moderationPolicy.listFilter(post: post))
    #expect(b.server.requests(forPath: "getPreferences").isEmpty)

    // B's fetch changes nothing about the decision, and nothing of A's carries over.
    try await b.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    #expect(b.appState.moderationPolicy.accountDID == didB)
    #expect(!b.appState.isAdultContentEnabled)
    #expect(b.appState.moderationPolicy.listFilter(post: post))
    #expect(b.appState.makeFilterSettings(snapshot: nil).moderationPolicy == b.appState.moderationPolicy)
    #expect(a.appState.isAdultContentEnabled)

    // Switching back restores A before and after A's fetch.
    a.appState.refreshModerationPolicy()
    #expect(a.appState.moderationPolicy.accountDID == didA)
    #expect(a.appState.isAdultContentEnabled)
    #expect(!a.appState.moderationPolicy.listFilter(post: post))
    try await a.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    #expect(a.appState.isAdultContentEnabled)
    #expect(!a.appState.moderationPolicy.listFilter(post: post))
    #expect(!b.appState.isAdultContentEnabled)
  }

  @Test("Activating an account after a switch resets the policy to its own confirmed state")
  func switchActivationResetsThePolicy() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("activation")
    try harness.persistRow(
      did: did, adultContentEnabled: true,
      contentLabelPrefs: [ContentLabelPreference(labelerDid: nil, label: "porn", visibility: "ignore")],
      confirmed: true)
    // The AppState exists but has not read its store yet, as when it is created ahead of the switch.
    let account = try await harness.makeAccount(did: did, initializePreferences: false)
    let state = account.appState
    account.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "ignore")])
    state.preferencesManager.configure(accountDID: did)
    state.preferencesManager.setModelContext(harness.container.mainContext)
    state.preferencesManager.updateClient(account.client)
    #expect(!state.isAdultContentEnabled)
    #expect(state.moderationPolicy.accountDID == did)

    await state.refreshAfterAccountSwitch()

    #expect(state.moderationPolicy.isConfirmed)
    #expect(state.isAdultContentEnabled)
    #expect(!state.moderationPolicy.listFilter(post: try pornPost()))
  }

  @Test("An account without a confirmed row is fail-closed and never inherits another account's setting")
  func unconfirmedAccountIsFailClosed() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let confirmedDID = Fixtures.uniqueDID("confirmed")
    let newDID = Fixtures.uniqueDID("newaccount")
    try harness.persistRow(did: confirmedDID, adultContentEnabled: true, confirmed: true)
    let confirmed = try await harness.makeAccount(did: confirmedDID)
    let fresh = try await harness.makeAccount(did: newDID)
    let post = try pornPost()

    #expect(confirmed.appState.isAdultContentEnabled)
    #expect(fresh.appState.moderationPolicy.accountDID == newDID)
    #expect(!fresh.appState.moderationPolicy.isConfirmed)
    #expect(!fresh.appState.isAdultContentEnabled)
    #expect(fresh.appState.moderationPolicy.listFilter(post: post))
    // Only the Bluesky moderation service is trusted until preferences are confirmed.
    #expect(subscribedLabelerDIDs(fresh.appState) == [Fixtures.blueskyModerationDID])
  }

  @Test("A stored adult flag that the server never confirmed does not enable adult content")
  func unconfirmedStoredFlagIsIgnored() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("unconfirmedflag")
    try harness.persistRow(did: did, adultContentEnabled: true, confirmed: false)
    let account = try await harness.makeAccount(did: did)

    #expect(!account.appState.isAdultContentEnabled)
    #expect(!account.appState.moderationPolicy.isConfirmed)
    #expect(account.appState.moderationPolicy.listFilter(post: try pornPost()))
  }

  // MARK: - Failed refresh

  @Test("A failed preference refresh keeps the confirmed policy; an unconfirmed account stays fail-closed")
  func failedRefreshKeepsLastConfirmedPolicy() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let post = try pornPost()

    // An account with a confirmed fetch keeps its policy through an outage.
    let confirmedDID = Fixtures.uniqueDID("failedrefresh")
    let confirmed = try await harness.makeAccount(did: confirmedDID)
    confirmed.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "ignore")])
    try await confirmed.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    let before = confirmed.appState.moderationPolicy
    #expect(before.isConfirmed)
    #expect(before.adultContentEnabled)
    #expect(!before.listFilter(post: post))

    confirmed.server.setPreferencesStatus(400)
    await #expect(throws: (any Error).self) {
      try await confirmed.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    }
    #expect(confirmed.appState.moderationPolicy == before)
    #expect(confirmed.appState.isAdultContentEnabled)
    #expect(!confirmed.appState.moderationPolicy.listFilter(post: post))
    // Refreshing from the stored row after the outage still yields the confirmed policy.
    confirmed.appState.refreshModerationPolicy()
    #expect(confirmed.appState.moderationPolicy == before)

    // An account that never confirmed anything stays fail-closed while the server is down.
    let freshDID = Fixtures.uniqueDID("neverconfirmed")
    let fresh = try await harness.makeAccount(did: freshDID)
    fresh.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "ignore")])
    fresh.server.setPreferencesStatus(400)
    await #expect(throws: (any Error).self) {
      try await fresh.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    }
    #expect(fresh.appState.moderationPolicy.accountDID == freshDID)
    #expect(!fresh.appState.moderationPolicy.isConfirmed)
    #expect(!fresh.appState.isAdultContentEnabled)
    #expect(fresh.appState.moderationPolicy.listFilter(post: post))
  }

  @Test("Before the store is readable the policy is this account's fail-closed policy")
  func unreadableStoreIsFailClosedForTheAccount() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("unreadable")
    let account = try await harness.makeAccount(did: did, initializePreferences: false)

    #expect(account.appState.moderationPolicy.accountDID == did)
    #expect(!account.appState.isAdultContentEnabled)
    account.appState.refreshModerationPolicy()
    #expect(account.appState.moderationPolicy.accountDID == did)
    #expect(!account.appState.isAdultContentEnabled)
  }

  // MARK: - Background poll

  @Test("A successful poll fetch flips the policy when the server turns adult content off")
  func pollFetchFlipsThePolicy() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("poll")
    let account = try await harness.makeAccount(did: did)
    let recorder = ModerationPolicyChangeRecorder(accountDID: did)
    let post = try pornPost()
    let preferences = account.appState.preferencesManager

    account.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "ignore")])
    try await preferences.fetchPreferences(forceRefresh: true)
    #expect(account.appState.isAdultContentEnabled)
    #expect(!account.appState.moderationPolicy.listFilter(post: post))
    #expect(recorder.count == 1)

    // The server turns adult content off elsewhere. `AppState.startBackgroundPolling` runs exactly this
    // fetch every five minutes.
    account.server.setPreferences(adultContentEnabled: false, contentLabelPrefs: [("porn", "ignore")])
    try await preferences.fetchPreferences(forceRefresh: true)
    #expect(!account.appState.isAdultContentEnabled)
    #expect(!account.appState.moderationPolicy.adultContentEnabled)
    #expect(account.appState.moderationPolicy.listFilter(post: post))
    #expect(recorder.count == 2)

    // An unchanged poll publishes nothing.
    try await preferences.fetchPreferences(forceRefresh: true)
    #expect(recorder.count == 2)
  }

  @Test("A confirmed write rebuilds the policy before FeedPreferencesChanged is posted")
  func confirmedWriteRebuildsBeforeFeedNotification() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("write")
    let account = try await harness.makeAccount(did: did)
    account.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "hide")])
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    let post = try pornPost()
    #expect(account.appState.moderationPolicy.listFilter(post: post))

    final class PolicyProbe: @unchecked Sendable {
      let state: AppState
      var policyAtNotification: ModerationPolicy?
      init(state: AppState) { self.state = state }
    }
    let probe = PolicyProbe(state: account.appState)
    let token = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("FeedPreferencesChanged"), object: nil, queue: nil
    ) { notification in
      guard notification.userInfo?["accountDID"] as? String == did else { return }
      MainActor.assumeIsolated { probe.policyAtNotification = probe.state.moderationPolicy }
    }
    defer { NotificationCenter.default.removeObserver(token) }

    try await account.appState.preferencesManager.setContentLabelVisibility(
      label: "porn", visibility: "ignore", expectedAccountDID: did)

    #expect(account.server.requests.contains { $0.method == "POST" && $0.path.hasSuffix("putPreferences") })
    #expect(!account.appState.moderationPolicy.listFilter(post: post))
    let seen = try #require(probe.policyAtNotification)
    #expect(!seen.listFilter(post: post))
  }

  // MARK: - Confirmed writes

  /// Preference kinds that carry no moderation setting of their own. Their writes still re-read the
  /// server's preferences and overwrite the stored adult flag, label prefs and labelers.
  enum UnrelatedWrite: String, CaseIterable, Sendable {
    case interests
    case verification
    case postInteractionSettings

    @MainActor
    func perform(on manager: PreferencesManager) async throws {
      switch self {
      case .interests: try await manager.addInterest("moderation-fixture")
      case .verification: try await manager.setVerificationPrefs(nil)
      case .postInteractionSettings: try await manager.setPostInteractionSettingsPref(nil)
      }
    }
  }

  @Test("A confirmed write of any kind rebuilds the policy from the server's fresh read", arguments: UnrelatedWrite.allCases)
  func unrelatedWriteRebuildsThePolicy(write: UnrelatedWrite) async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("unrelatedwrite\(write.rawValue.lowercased())"))
    let state = account.appState
    let post = try pornPost()

    account.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "ignore")])
    try await state.preferencesManager.fetchPreferences(forceRefresh: true)
    #expect(state.isAdultContentEnabled)
    #expect(!state.moderationPolicy.listFilter(post: post))

    // The server's adult flag and label prefs change elsewhere. No poll runs before this write.
    account.server.setPreferences(adultContentEnabled: false, contentLabelPrefs: [("porn", "hide")])
    try await write.perform(on: state.preferencesManager)

    #expect(account.server.requests.contains { $0.method == "POST" && $0.path.hasSuffix("putPreferences") })
    #expect(!state.isAdultContentEnabled)
    #expect(!state.moderationPolicy.adultContentEnabled)
    #expect(state.moderationPolicy.prefs.labels["porn"] == .hide)
    #expect(state.moderationPolicy.listFilter(post: post))
  }

  // MARK: - Legacy flag

  @Test("The legacy unscoped adult flag in shared defaults no longer enables adult content")
  func legacyUnscopedFlagIsIgnored() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("legacyflag")
    let defaults = AppSettingsModel.sharedDefaults()
    let scopedKey = AppSettingsModel.scopedKey("isAdultContentEnabled", accountDID: did)
    defaults.set(true, forKey: "isAdultContentEnabled")
    defaults.set(true, forKey: scopedKey)
    defer {
      defaults.removeObject(forKey: "isAdultContentEnabled")
      defaults.removeObject(forKey: scopedKey)
    }

    let account = try await harness.makeAccount(did: did)
    #expect(!account.appState.isAdultContentEnabled)
    #expect(account.appState.moderationPolicy.listFilter(post: try pornPost()))

    // A confirmed server value of "off" wins over both stored flags.
    account.server.setPreferences(adultContentEnabled: false)
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    #expect(!account.appState.isAdultContentEnabled)

    // A confirmed server value of "on" is the only thing that enables it.
    account.server.setPreferences(adultContentEnabled: true)
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    #expect(account.appState.isAdultContentEnabled)
  }

  @Test("No preference path writes the adult flag back to shared defaults")
  func adultFlagIsNeverWrittenToSharedDefaults() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("noflagwrite")
    let defaults = AppSettingsModel.sharedDefaults()
    let scopedKey = AppSettingsModel.scopedKey("isAdultContentEnabled", accountDID: did)
    // Sentinels that differ from every value the server below ever reports ("off").
    defaults.set(true, forKey: "isAdultContentEnabled")
    defaults.set(true, forKey: scopedKey)
    defer {
      defaults.removeObject(forKey: "isAdultContentEnabled")
      defaults.removeObject(forKey: scopedKey)
    }
    func expectSentinelsUntouched(after step: String, sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(defaults.object(forKey: scopedKey) as? Bool == true, "\(step) rewrote the scoped flag", sourceLocation: sourceLocation)
      #expect(
        defaults.object(forKey: "isAdultContentEnabled") as? Bool == true, "\(step) rewrote the unscoped flag",
        sourceLocation: sourceLocation)
    }

    let account = try await harness.makeAccount(did: did)
    let state = account.appState
    let preferences = state.preferencesManager
    account.server.setPreferences(adultContentEnabled: true)
    try await preferences.fetchPreferences(forceRefresh: true)
    expectSentinelsUntouched(after: "a preferences fetch")

    // The adult-content write path: the server holds "on" and the edit turns it off.
    try await preferences.updateAdultContentEnabled(false)
    #expect(!state.isAdultContentEnabled)
    expectSentinelsUntouched(after: "an adult-content write")

    // The confirmed no-op path: the interest is added, then added again without a change.
    try await preferences.addInterest("moderation-fixture")
    try await preferences.addInterest("moderation-fixture")
    expectSentinelsUntouched(after: "a confirmed no-op write")

    // Synchronizing preferences with app settings.
    try await preferences.syncPreferencesWithAppSettings(state)
    expectSentinelsUntouched(after: "syncPreferencesWithAppSettings")

    // The sentinel "on" flags are not read back either: the server's "off" stands.
    #expect(!state.isAdultContentEnabled)
  }

  @Test("The legacy feed filter takes its adult setting from the policy, not from an unconfirmed stored row")
  func legacyFeedFilterSharesTheAdultSource() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("legacylists")
    // An upgraded user's row from before preferences were confirmed, with adult content left on.
    try harness.persistRow(did: did, adultContentEnabled: true, confirmed: false)
    let account = try await harness.makeAccount(did: did)
    let state = account.appState

    let beforeConfirmation = await state.buildFilterSettings()
    // The legacy snapshot is seeded from the unconfirmed row and still says adult content is on ...
    #expect(FeedPreferenceSnapshotStore.shared.snapshot(for: did)?.adultContentEnabled == true)
    // ... but the policy, which is all the lists read for labels, says it is off until the server confirms it.
    #expect(!state.isAdultContentEnabled)
    #expect(!beforeConfirmation.moderationPolicy.adultContentEnabled)
    #expect(beforeConfirmation.moderationPolicy == state.moderationPolicy)

    account.server.setPreferences(adultContentEnabled: true)
    try await state.preferencesManager.fetchPreferences(forceRefresh: true)
    let afterConfirmation = await state.buildFilterSettings()
    #expect(state.isAdultContentEnabled)
    #expect(afterConfirmation.moderationPolicy.adultContentEnabled)

    account.server.setPreferences(adultContentEnabled: false)
    try await state.preferencesManager.fetchPreferences(forceRefresh: true)
    let afterTurnOff = await state.buildFilterSettings()
    #expect(!state.isAdultContentEnabled)
    #expect(!afterTurnOff.moderationPolicy.adultContentEnabled)
  }

  // MARK: - Custom labelers

  @Test("Subscribed labelers' definitions join the policy once loaded and survive a failed reload")
  func customLabelerDefinitionsLoadAndSurviveFailure() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("definitions")
    let account = try await harness.makeAccount(did: did)
    let server = account.server
    let recorder = ModerationPolicyChangeRecorder(accountDID: did)
    let bluesky = Fixtures.blueskyModerationDID
    let first = Fixtures.customLabelerDID
    let second = Fixtures.secondLabelerDID
    let spoiler = Fixtures.customLabelValue
    server.publishLabeler(did: first)
    server.publishLabeler(did: second, identifier: "fixture-other")
    let post = try ModerationStatePosts.post(labeled: spoiler, source: first)
    let state = account.appState
    let preferences = state.preferencesManager

    // The policy is built from the confirmed row at once; definitions arrive afterwards.
    server.setPreferences(adultContentEnabled: false, labelerDIDs: [first])
    try await preferences.fetchPreferences(forceRefresh: true)
    #expect(subscribedLabelerDIDs(state) == [bluesky, first])
    #expect(state.moderationPolicy.labelDefinitions.isEmpty)
    #expect(!blurs(state, post))
    await state.awaitModerationDefinitionsLoad()
    #expect(definitionIDs(state, labeler: first) == [spoiler])
    #expect(blurs(state, post))
    #expect(recorder.count == 2)

    // A second labeler is subscribed while the service is down: the subscription applies at once, the
    // first labeler keeps its last successful definitions, and nothing is invented for the second.
    server.setPreferences(adultContentEnabled: false, labelerDIDs: [first, second])
    server.setServicesStatus(400)
    try await preferences.fetchPreferences(forceRefresh: true)
    await state.awaitModerationDefinitionsLoad()
    #expect(subscribedLabelerDIDs(state).contains(second))
    #expect(definitionIDs(state, labeler: first) == [spoiler])
    #expect(definitionIDs(state, labeler: second).isEmpty)
    #expect(blurs(state, post))

    // Once the service recovers, the next refresh loads the missing definitions.
    server.setServicesStatus(200)
    state.refreshModerationPolicy()
    await state.awaitModerationDefinitionsLoad()
    #expect(definitionIDs(state, labeler: second) == ["fixture-other"])
    let statuses = server.requests(forPath: "getServices").map(\.status)
    #expect(statuses == [200, 400, 200])

    // Unsubscribing drops that labeler's definitions and stops honoring its labels.
    server.setPreferences(adultContentEnabled: false, labelerDIDs: [second])
    try await preferences.fetchPreferences(forceRefresh: true)
    await state.awaitModerationDefinitionsLoad()
    #expect(definitionIDs(state, labeler: first).isEmpty)
    #expect(!blurs(state, post))
  }

  @Test("A slow labeler-service load is cancelled by an account switch instead of timing out the drain")
  func slowDefinitionsLoadDoesNotBlockAccountSwitch() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("slowswitch")
    let account = try await harness.makeAccount(did: did)
    let server = account.server
    let state = account.appState
    let labeler = Fixtures.customLabelerDID
    server.publishLabeler(did: labeler)
    server.setPreferences(adultContentEnabled: false, labelerDIDs: [labeler])
    // Longer than the 2 s drain deadline of `AccountServiceWork`, so an un-cancelled load must time it out.
    server.setServicesDelay(5)

    // The confirmed fetch starts the definitions load; the fake server has the request and is holding it.
    try await state.preferencesManager.fetchPreferences(forceRefresh: true)
    for _ in 0..<200 where server.requests(forPath: "getServices").isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.requests(forPath: "getServices").count == 1)

    let started = ContinuousClock.now
    try await state.suspendForAccountSwitch()
    let switchDuration = ContinuousClock.now - started
    #expect(switchDuration < .seconds(2), "the switch waited \(switchDuration) for the labeler service")

    // The load was cancelled: nothing waits on it any more and its result never applied.
    let awaitStarted = ContinuousClock.now
    await state.awaitModerationDefinitionsLoad()
    #expect(ContinuousClock.now - awaitStarted < .seconds(1))
    #expect(definitionIDs(state, labeler: labeler).isEmpty)
  }

  // MARK: - Consumers

  @Test("Filter settings and the SwiftUI environment carry the account's policy")
  func policyReachesFilterSettingsAndEnvironment() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let did = Fixtures.uniqueDID("consumers")
    let account = try await harness.makeAccount(did: did)

    #expect(EnvironmentValues().moderationPolicy == .failClosed)
    #expect(FeedTunerSettings.default.moderationPolicy == .failClosed)
    #expect(account.appState.makeFilterSettings(snapshot: nil).moderationPolicy == account.appState.moderationPolicy)

    account.server.setPreferences(adultContentEnabled: true, contentLabelPrefs: [("porn", "warn")])
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    let policy = account.appState.moderationPolicy
    #expect(policy.adultContentEnabled)
    #expect(account.appState.makeFilterSettings(snapshot: nil).moderationPolicy == policy)
    #expect(policy.prefs.labels["porn"] == .warn)
  }
}
