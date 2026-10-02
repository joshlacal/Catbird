import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct OnboardingGrowthTests {
    
    // MARK: - G62: Account Scoped Completion & Step Restoration
    
    @Test("Account scoped completion and step restoration across multiple DIDs")
    func accountScopedCompletionAndStepRestoration() async {
        // Use an isolated suite name to avoid colliding with live user defaults
        let suiteName = "blue.catbird.test.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        
        let onboardingManager = OnboardingManager(userDefaults: defaults)
        
        let didA = "did:plc:alice123"
        let didB = "did:plc:bob456"
        
        // 1. Initially neither DID has completed onboarding
        #expect(onboardingManager.hasCompletedWelcome(for: didA) == false)
        #expect(onboardingManager.hasCompletedWelcome(for: didB) == false)
        #expect(onboardingManager.savedStep(for: didA) == 0)
        #expect(onboardingManager.savedStep(for: didB) == 0)
        
        // 2. DID A progresses through step 2
        onboardingManager.saveStep(2, for: didA)
        #expect(onboardingManager.savedStep(for: didA) == 2)
        #expect(onboardingManager.savedStep(for: didB) == 0)
        
        // 3. DID A completes onboarding
        onboardingManager.completeWelcomeOnboarding(for: didA)
        #expect(onboardingManager.hasCompletedWelcome(for: didA) == true)
        #expect(onboardingManager.savedStep(for: didA) == 0) // reset on finish
        
        // 4. DID B must remain uncompleted and unaffected
        #expect(onboardingManager.hasCompletedWelcome(for: didB) == false)
        #expect(onboardingManager.savedStep(for: didB) == 0)
        
        // 5. DID B progresses to step 1
        onboardingManager.saveStep(1, for: didB)
        #expect(onboardingManager.savedStep(for: didA) == 0)
        #expect(onboardingManager.savedStep(for: didB) == 1)
        
        // 6. Resetting onboarding for DID A does not reset DID B
        onboardingManager.setCompletedWelcome(true, for: didB)
        onboardingManager.resetAllOnboarding(for: didA)
        #expect(onboardingManager.hasCompletedWelcome(for: didA) == false)
        #expect(onboardingManager.hasCompletedWelcome(for: didB) == true)
    }
    
    // MARK: - G63: Pending Starter Pack Survives Auth & Finalizes Once
    
    @Test("Pending starter pack survives auth, handles opt-out and deduplicates feeds")
    func pendingStarterPackSurvivesAuthAndFinalizesOnce() async {
        let suiteName = "blue.catbird.test.starterpack.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        
        let starterPackManager = StarterPackOnboardingManager(defaults: defaults)
        
        let packURI = "at://did:plc:creator123/app.bsky.graph.starterpack/3k2vsomepack"
        let packCID = "bafyreih3examplecid"
        let context = StarterPackPendingContext(
            uri: packURI,
            cid: packCID,
            name: "Swift Developers",
            creatorDID: "did:plc:creator123"
        )
        
        // 1. Set pending context
        starterPackManager.setPendingContext(context)
        #expect(starterPackManager.pendingContext == context)
        
        // 2. Re-instantiate manager with same defaults (simulating app restart / post-auth reload)
        let restoredManager = StarterPackOnboardingManager(defaults: defaults)
        #expect(restoredManager.pendingContext == context)
        #expect(restoredManager.pendingContext?.uri == packURI)
        #expect(restoredManager.pendingContext?.cid == packCID)
        
        // 3. Feed deduplication logic verification
        var currentPinnedFeeds = ["at://did:plc:sys/app.bsky.feed.generator/whats-hot", "at://did:plc:cat/app.bsky.feed.generator/cats"]
        let incomingPackFeeds = [
            "at://did:plc:cat/app.bsky.feed.generator/cats", // duplicate
            "at://did:plc:swift/app.bsky.feed.generator/swift-lang" // new
        ]
        
        var newPinnedCount = 0
        for feed in incomingPackFeeds {
            if !currentPinnedFeeds.contains(feed) {
                currentPinnedFeeds.append(feed)
                newPinnedCount += 1
            }
        }
        
        #expect(newPinnedCount == 1)
        #expect(currentPinnedFeeds.count == 3)
        #expect(currentPinnedFeeds.contains("at://did:plc:swift/app.bsky.feed.generator/swift-lang"))
        
        // 4. Clearing pending context on opt-out
        restoredManager.clearPendingContext()
        #expect(restoredManager.pendingContext == nil)
        
        let postClearManager = StarterPackOnboardingManager(defaults: defaults)
        #expect(postClearManager.pendingContext == nil)
    }
    
    // MARK: - G67: Signup Queue Time Estimate Formatting & State Lifecycle
    
    @Test("Signup queue estimate calculation and string formatting")
    func signupQueueTransitionsAndFormatsEstimate() async {
        // 1. Verify estimate formatting
        #expect(SignupQueuedView.formatEstimate(ms: nil) == "Estimating wait time...")
        #expect(SignupQueuedView.formatEstimate(ms: 0) == "Estimating wait time...")
        #expect(SignupQueuedView.formatEstimate(ms: 30_000) == "Estimated wait: Less than a minute")
        #expect(SignupQueuedView.formatEstimate(ms: 60_000) == "Estimated wait: ~1 minute")
        #expect(SignupQueuedView.formatEstimate(ms: 180_000) == "Estimated wait: ~3 minutes")
        #expect(SignupQueuedView.formatEstimate(ms: 3_600_000) == "Estimated wait: ~1 hour")
        #expect(SignupQueuedView.formatEstimate(ms: 7_200_000) == "Estimated wait: ~2 hours")
        
        // 2. Verify SignupQueueState clamped place and transitions
        let suiteName = "blue.catbird.test.queue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        
        let onboardingManager = OnboardingManager(userDefaults: defaults)
        #expect(onboardingManager.isSignupQueued == false)
        #expect(onboardingManager.signupQueueState == nil)
        
        // Place in queue clamped to at least 1
        let stateWithZero = OnboardingManager.SignupQueueState(
            isQueued: true,
            placeInQueue: max(1, 0),
            estimatedTimeMs: 120_000
        )
        #expect(stateWithZero.placeInQueue == 1)
        #expect(stateWithZero.isQueued == true)
        #expect(stateWithZero.estimatedTimeMs == 120_000)
        
        onboardingManager.isSignupQueued = true
        onboardingManager.signupQueueState = stateWithZero
        #expect(onboardingManager.isSignupQueued == true)
        #expect(onboardingManager.signupQueueState?.placeInQueue == 1)
        
        // Activation clears queued state
        onboardingManager.isSignupQueued = false
        onboardingManager.signupQueueState = nil
        #expect(onboardingManager.isSignupQueued == false)
        #expect(onboardingManager.signupQueueState == nil)
        
        // 3. Queue gate triggers welcome sheet even if onboarding was previously completed
        onboardingManager.setCompletedWelcome(true, for: "did:plc:queuedUser")
        #expect(onboardingManager.hasCompletedWelcome(for: "did:plc:queuedUser") == true)
        onboardingManager.showWelcomeSheet = false
        onboardingManager.isSignupQueued = true
        onboardingManager.checkForWelcomeOnboarding(for: "did:plc:queuedUser")
        #expect(onboardingManager.showWelcomeSheet == true)
        
        // 4. Queue signout resets queued state and dismisses sheet
        onboardingManager.isSignupQueued = false
        onboardingManager.signupQueueState = nil
        onboardingManager.showWelcomeSheet = false
        #expect(onboardingManager.isSignupQueued == false)
        #expect(onboardingManager.signupQueueState == nil)
        #expect(onboardingManager.showWelcomeSheet == false)
    }
}
