import Foundation
import Petrel
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Catbird

// MARK: - Onboarding & Intent Integration Tests

@Suite("OnboardingAgeAssuranceIntegrationTests")
struct OnboardingAgeAssuranceIntegrationTests {
    
    @Test("Passive AppState launch commits a no-requirement result without an age prompt")
    @MainActor
    func passiveRegulatoryPreflight() async {
        let checker = AgeAccessControlledChecker()
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(
            userDID: "did:plc:testuseronboarding123",
            client: client,
            regulatoryChecker: checker
        )
        defer { appState.cleanup() }

        let joined = await ageAccessJoinedRefresh(appState.ageAccess)
        await checker.waitForCalls(1)
        // The initial signal is already .none; checking admission proves this assertion cannot
        // accidentally pass before the startup task has committed its result.
        #expect(appState.ageAccess.isCheckingRequirement)
        #expect(!appState.ageAccess.allows(.generalContent))
        await checker.resolve(1, with: .none)
        await joined.value

        #expect(await checker.callCount == 1)
        #expect(await checker.nativePromptCount == 0)
        #expect(!appState.ageAccess.isCheckingRequirement)
        #expect(appState.ageAccess.allows(.generalContent))
        #expect(appState.platformAgeSignal == .none)
        #expect(appState.platformAgeSignal.ageBand == nil)
        // Network absence is not claimed: this AppState integration uses the normal test host.
        // The isolated coordinator suite injects all interactions and constructs no client.
    }

    @Test("External age assurance URL intent is ignored and returns nil")
    func ageAssuranceIntentIsIgnored() {
        let ageURL = URL(string: "bluesky://intent/age-assurance?state=xyz&code=123")!
        #expect(ExternalURLIntent.parse(from: ageURL) == nil)
        
        let httpsAgeURL = URL(string: "https://bsky.app/intent/age-assurance?state=xyz&code=123")!
        #expect(ExternalURLIntent.parse(from: httpsAgeURL) == nil)
    }
    
    @Test("Supported external intents remain intact and parse accurately")
    func supportedExternalIntentsRemainIntact() {
        let composeURL = URL(string: "bluesky://intent/compose?text=Hello%20World")!
        #expect(ExternalURLIntent.parse(from: composeURL) == .compose(text: "Hello World"))
        
        let verifyURL = URL(string: "bluesky://intent/verify-email?code=ABC12345")!
        #expect(ExternalURLIntent.parse(from: verifyURL) == .verifyEmail(code: "ABC12345"))
        
        let groupChatURL = URL(string: "bluesky://chat/3kxyz78")!
        #expect(ExternalURLIntent.parse(from: groupChatURL) == .groupChatJoin(code: "3kxyz78"))
    }
    
    @Test("Age policy operates on coarse signals without exact birth date")
    func policyDecisionsRequireNoBirthDate() {
        let unknownDecision = AgePolicy.decision(for: .unknown, context: .ordinaryUse)
        #expect(unknownDecision == .allow)
        
        let under13Band = AgeBand.under13
        let under13Signal = PlatformAgeSignal(
            requirement: .none,
            ageBand: under13Band,
            significantChangeConsentRequired: false
        )
        let under13Decision = AgePolicy.decision(for: .platform(under13Signal), context: .ordinaryUse)
        #expect(under13Decision == .deny)
        
        let teenBand = AgeBand.teen
        let teenSignal = PlatformAgeSignal(
            requirement: .none,
            ageBand: teenBand,
            significantChangeConsentRequired: false
        )
        let teenDecision = AgePolicy.decision(for: .platform(teenSignal), context: .ordinaryUse)
        #expect(teenDecision == .allow)
        
        let matureDecision = AgePolicy.decision(for: .platform(teenSignal), context: .matureContent)
        #expect(matureDecision == .hideSensitiveContent)
    }
}
