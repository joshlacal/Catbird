import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct FeedDiscoveryOnboardingTests {
  @Test func discoveryAcknowledgementIsAccountScopedAndSurvivesRecreation() {
    let suite = "blue.catbird.discovery-education.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let alice = "did:plc:discoveryalice"
    let bob = "did:plc:discoverybob"
    let store = FeedDiscoveryEducationStore(userDefaults: defaults)
    #expect(!store.hasAcknowledged(accountDID: alice))
    #expect(!store.hasAcknowledged(accountDID: bob))
    store.acknowledge(accountDID: alice)
    let restored = FeedDiscoveryEducationStore(userDefaults: defaults)
    #expect(restored.hasAcknowledged(accountDID: alice))
    #expect(!restored.hasAcknowledged(accountDID: bob))
    restored.acknowledge(accountDID: bob)
    #expect(store.hasAcknowledged(accountDID: alice))
    #expect(store.hasAcknowledged(accountDID: bob))
  }

  @Test func existingStepIndicesSurviveManagerRecreation() {
    let suite = "blue.catbird.discovery-onboarding.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let did = "did:plc:discoverytest"
    let manager = OnboardingManager(accountDID: did, userDefaults: defaults)
    for step in 0...3 {
      manager.saveStep(step, for: did)
      let restored = OnboardingManager(accountDID: did, userDefaults: defaults)
      #expect(restored.savedStep(for: did) == step)
      #expect(!restored.hasCompletedWelcome)
    }
  }

  @Test func completedAccountDoesNotReplayWelcome() {
    let suite = "blue.catbird.discovery-onboarding.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let alice = "did:plc:discoveryalice"
    let bob = "did:plc:discoverybob"
    let manager = OnboardingManager(accountDID: alice, userDefaults: defaults)
    manager.completeWelcomeOnboarding(for: alice)

    let restored = OnboardingManager(accountDID: alice, userDefaults: defaults)
    restored.checkForWelcomeOnboarding(for: alice)
    #expect(restored.hasCompletedWelcome)
    #expect(!restored.showWelcomeSheet)
    restored.configure(accountDID: bob)
    restored.checkForWelcomeOnboarding(for: bob)
    #expect(restored.showWelcomeSheet)
    #expect(!restored.hasCompletedWelcome(for: bob))
    #expect(restored.hasCompletedWelcome(for: alice))
  }

  @Test func starterPackPinnedOrderIsPreserved() async throws {
    let did = "did:plc:discoverytest"
    let first = try ATProtocolURI(uriString: "at://did:plc:creator/app.bsky.feed.generator/first")
    let second = try ATProtocolURI(uriString: "at://did:plc:creator/app.bsky.feed.generator/second")
    let discovered = try ATProtocolURI(uriString: "at://did:plc:creator/app.bsky.feed.generator/discovered")
    let preferences = Preferences(accountDID: did)
    let originalOrder = [first.uriString(), second.uriString()]
    preferences.pinnedFeeds = originalOrder
    preferences.savedFeeds = []
    let actions = FeedLibraryActions(accountDID: did, read: { preferences }, persist: { _ in .synced })

    // Choosing an existing starter-pack feed must neither demote nor reorder it.
    #expect(try await actions.add(first) == .pinned)
    #expect(preferences.pinnedFeeds == originalOrder)
    #expect(try await actions.add(discovered) == .saved)
    #expect(preferences.pinnedFeeds == originalOrder)
    #expect(preferences.savedFeeds == [discovered.uriString()])
    #expect(try await actions.add(discovered, to: .pinned) == .pinned)
    #expect(preferences.pinnedFeeds == originalOrder + [discovered.uriString()])
    #expect(preferences.savedFeeds.isEmpty)
  }
}
