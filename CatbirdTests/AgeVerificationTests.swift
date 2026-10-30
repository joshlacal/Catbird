import Testing
import Foundation
import Petrel
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
@testable import Catbird

@Suite("AgeVerificationTests")
struct AgeVerificationTests {

    // MARK: - Core Pure Policy Decisions (Step 1)

    @Test("Unknown signal permits ordinary use and keeps mature content hidden")
    func testUnknownSignalDecisions() {
        #expect(AgePolicy.decision(for: .unknown, context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .unknown, context: .matureContent) == .hideSensitiveContent)
    }

    @Test("Platform signal requiring age check without age band is unavailable due to consent")
    func testPlatformAgeCheckRequiredWithoutBand() {
        let signal = PlatformAgeSignal(
            requirement: .ageCheckRequired,
            ageBand: nil,
            significantChangeConsentRequired: false
        )
        #expect(AgePolicy.decision(for: .platform(signal), context: .ordinaryUse) == .unavailableDueToConsent)
        #expect(AgePolicy.decision(for: .platform(signal), context: .matureContent) == .unavailableDueToConsent)
    }

    @Test("Significant change flag does not invent an unscoped ordinary-use gate")
    func testSignificantChangeFlagDoesNotCreateUnscopedGate() {
        let signal = PlatformAgeSignal(
            requirement: .none,
            ageBand: .adult,
            significantChangeConsentRequired: true
        )
        // A future significant-change gate must name the covered release/feature.
        // The passive flag alone is not an account-wide age restriction.
        #expect(AgePolicy.decision(for: .platform(signal), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .platform(signal), context: .matureContent) == .hideSensitiveContent)
    }

    @Test("Adult platform band never enables mature content at policy level")
    func testAdultBandNeverEnablesMatureContent() {
        let signalNone = PlatformAgeSignal(
            requirement: .none,
            ageBand: .adult,
            significantChangeConsentRequired: false
        )
        #expect(AgePolicy.decision(for: .platform(signalNone), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .platform(signalNone), context: .matureContent) == .hideSensitiveContent)

        let signalRequired = PlatformAgeSignal(
            requirement: .ageCheckRequired,
            ageBand: .adult,
            significantChangeConsentRequired: false
        )
        #expect(AgePolicy.decision(for: .platform(signalRequired), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .platform(signalRequired), context: .matureContent) == .hideSensitiveContent)
    }

    @Test("Under 13 coarse age band denies ordinary use and mature content")
    func testUnder13BandDeniesAccess() {
        let signal = PlatformAgeSignal(
            requirement: .none,
            ageBand: .under13,
            significantChangeConsentRequired: false
        )
        #expect(AgePolicy.decision(for: .platform(signal), context: .ordinaryUse) == .deny)
        #expect(AgePolicy.decision(for: .platform(signal), context: .matureContent) == .deny)
    }

    @Test("Teen coarse age band permits ordinary use and hides mature content")
    func testTeenBandPermitsOrdinaryUse() {
        let signal = PlatformAgeSignal(
            requirement: .none,
            ageBand: .teen,
            significantChangeConsentRequired: false
        )
        #expect(AgePolicy.decision(for: .platform(signal), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .platform(signal), context: .matureContent) == .hideSensitiveContent)
    }

    // MARK: - Provider Restriction Decisions & Operation Scoping

    @Test("Provider restriction without handoff results in deny")
    func testProviderRestrictionWithoutHandoff() throws {
        let providerDID = try DID(didString: "did:plc:z72i7hdynmk6r22z27h6tvur")
        let restriction = ProviderRestriction(
            provider: providerDID,
            operation: .generalContent,
            reason: .ageRestricted,
            handoff: nil
        )
        #expect(AgePolicy.decision(for: .provider(restriction), context: .ordinaryUse) == .deny)
        #expect(AgePolicy.decision(for: .provider(restriction), context: .matureContent) == .deny)
    }

    @Test("Provider restriction with trusted handoff yields requireProviderVerification")
    func testProviderRestrictionWithTrustedHandoff() throws {
        let providerDID = try DID(didString: "did:plc:z72i7hdynmk6r22z27h6tvur")
        let handoffURL = try #require(URL(string: "https://auth.example.com/verify?user=123"))
        let handoff = try #require(TrustedHandoff(url: handoffURL, isProviderOwned: { $0.host == "auth.example.com" }))

        let restriction = ProviderRestriction(
            provider: providerDID,
            operation: .generalContent,
            reason: .ageAssuranceRequired,
            handoff: handoff
        )
        #expect(AgePolicy.decision(for: .provider(restriction), context: .ordinaryUse) == .requireProviderVerification(handoff))
    }

    @Test("Direct messaging provider restriction affects only direct messaging and not ordinary or mature content")
    func testDirectMessagingRestrictionScoping() throws {
        let providerDID = try DID(didString: "did:plc:z72i7hdynmk6r22z27h6tvur")
        let handoffURL = try #require(URL(string: "https://auth.example.com/verify-dm"))
        let handoff = try #require(TrustedHandoff(url: handoffURL, isProviderOwned: { $0.host == "auth.example.com" }))

        let dmRestriction = ProviderRestriction(
            provider: providerDID,
            operation: .directMessaging,
            reason: .ageAssuranceRequired,
            handoff: handoff
        )

        // Must NOT block ordinary use or mature content
        #expect(AgePolicy.decision(for: .provider(dmRestriction), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .provider(dmRestriction), context: .matureContent) == .hideSensitiveContent)
        #expect(AgePolicy.decision(for: .provider(dmRestriction), context: .operation(.generalContent)) == .allow)
        #expect(AgePolicy.decision(for: .provider(dmRestriction), context: .operation(.groupMessaging)) == .allow)

        // MUST block direct messaging operation
        #expect(AgePolicy.decision(for: .provider(dmRestriction), context: .operation(.directMessaging)) == .requireProviderVerification(handoff))

        let dmRestrictionNoHandoff = ProviderRestriction(
            provider: providerDID,
            operation: .directMessaging,
            reason: .ageRestricted,
            handoff: nil
        )
        #expect(AgePolicy.decision(for: .provider(dmRestrictionNoHandoff), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .provider(dmRestrictionNoHandoff), context: .matureContent) == .hideSensitiveContent)
        #expect(AgePolicy.decision(for: .provider(dmRestrictionNoHandoff), context: .operation(.directMessaging)) == .deny)
    }

    @Test("General content provider restriction blocks all operations")
    func testGeneralContentRestrictionBlocksAll() throws {
        let providerDID = try DID(didString: "did:plc:z72i7hdynmk6r22z27h6tvur")
        let restriction = ProviderRestriction(
            provider: providerDID,
            operation: .generalContent,
            reason: .ageRestricted,
            handoff: nil
        )

        #expect(AgePolicy.decision(for: .provider(restriction), context: .ordinaryUse) == .deny)
        #expect(AgePolicy.decision(for: .provider(restriction), context: .matureContent) == .deny)
        #expect(AgePolicy.decision(for: .provider(restriction), context: .operation(.generalContent)) == .deny)
        #expect(AgePolicy.decision(for: .provider(restriction), context: .operation(.directMessaging)) == .deny)
        #expect(AgePolicy.decision(for: .provider(restriction), context: .operation(.groupMessaging)) == .deny)
        #expect(AgePolicy.decision(for: .provider(restriction), context: .operation(.custom("customOp"))) == .deny)
    }

    // MARK: - Trusted Handoff Validation Tests

    @Test("TrustedHandoff rejects non-HTTPS schemes")
    func testTrustedHandoffRejectsHTTP() {
        let httpURL = URL(string: "http://auth.example.com/verify")!
        let handoff = TrustedHandoff(url: httpURL, isProviderOwned: { _ in true })
        #expect(handoff == nil)
    }

    @Test("TrustedHandoff rejects unverified provider ownership")
    func testTrustedHandoffRejectsUnverifiedHost() {
        let httpsURL = URL(string: "https://evil.com/verify")!
        let handoff = TrustedHandoff(url: httpsURL, isProviderOwned: { $0.host == "auth.example.com" })
        #expect(handoff == nil)
    }

    @Test("TrustedHandoff accepts HTTPS URL matching provider ownership predicate")
    func testTrustedHandoffAcceptsValid() {
        let httpsURL = URL(string: "https://auth.example.com/verify")!
        let handoff = TrustedHandoff(url: httpsURL, isProviderOwned: { $0.host == "auth.example.com" })
        #expect(handoff != nil)
        #expect(handoff?.url == httpsURL)
    }

    // MARK: - Privacy Boundary / Data Model Invariants

    @Test("Coarse bounds classify the standard under-13, teen and adult bands")
    func testAgeBandCoarseBoundsOnly() {
        let band = AgeBand(lowerBound: 13, upperBound: 17)
        #expect(band.lowerBound == 13)
        #expect(band.upperBound == 17)
        #expect(band.isUnder13 == false)
        #expect(band.isAdult == false)

        let under13 = AgeBand.under13
        #expect(under13.isUnder13 == true)
        #expect(under13.isAdult == false)

        let adult = AgeBand.adult
        #expect(adult.isUnder13 == false)
        #expect(adult.isAdult == true)
    }

    @Test("An affirmative no-requirement signal permits ordinary use")
    func testNeutralPlatformSignal() {
        let neutralSignal = PlatformAgeSignal(
            requirement: .none,
            ageBand: nil,
            significantChangeConsentRequired: false
        )
        #expect(AgePolicy.decision(for: .platform(neutralSignal), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .platform(neutralSignal), context: .matureContent) == .hideSensitiveContent)
    }

    // MARK: - Injected Regulatory Checking & Launch Preflight Behavioral Tests

    @Test("AppState launch consumes its injected preflight without retaining the returned band")
    @MainActor
    func testAppStateLaunchPreflightIntegration() async {
        let checker = AgeAccessControlledChecker()
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(
            userDID: "did:plc:testuser1234567890ab",
            client: client,
            regulatoryChecker: checker
        )
        defer { appState.cleanup() }

        let joined = await ageAccessJoinedRefresh(appState.ageAccess)
        await checker.waitForCalls(1)
        #expect(appState.ageAccess.isCheckingRequirement)
        #expect(!appState.ageAccess.allows(.generalContent))
        await checker.resolve(1, with: PlatformAgeSignal(
            requirement: .ageCheckRequired,
            ageBand: .teen,
            significantChangeConsentRequired: false
        ))
        await joined.value // Completion proves the coordinator committed the returned decision.

        #expect(await checker.callCount == 1)
        #expect(await checker.nativePromptCount == 0)
        #expect(!appState.ageAccess.isCheckingRequirement)
        #expect(appState.platformAgeSignal.requirement == .ageCheckRequired)
        #expect(appState.platformAgeSignal.ageBand == nil)
        #expect(appState.ageAccess.allows(.generalContent))
        #expect(appState.ageAccess.restrictsMatureContent)
        #expect(!appState.isAdultContentEnabled)
    }

    @Test("AppState cleanup fences a late preflight and retains no age band")
    @MainActor
    func testAppStateCleanupFencesPlatformAgeSignal() async {
        let checker = AgeAccessControlledChecker()
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(
            userDID: "did:plc:testuser1234567890ab",
            client: client,
            regulatoryChecker: checker
        )
        let joined = await ageAccessJoinedRefresh(appState.ageAccess)
        await checker.waitForCalls(1)
        await checker.resolve(1, with: .init(requirement: .ageCheckRequired, ageBand: .adult))
        await joined.value
        #expect(appState.ageAccess.allows(.generalContent))
        #expect(appState.platformAgeSignal.ageBand == nil)

        let pending = await ageAccessJoinedRefresh(appState.ageAccess)
        await checker.waitForCalls(2)
        appState.cleanup()
        let revision = appState.ageAccess.revision
        await checker.resolve(2, with: .none)
        await pending.value

        #expect(appState.ageAccess.revision == revision)
        #expect(appState.platformAgeSignal.requirement == .ageCheckRequired)
        #expect(appState.platformAgeSignal.ageBand == nil)
        #expect(!appState.ageAccess.allows(.generalContent))
        #expect(appState.ageAccess.restrictsMatureContent)
        #expect(!appState.ageAccess.isCheckingRequirement)
        #expect(!appState.isAdultContentEnabled)
    }

    @Test("Injected platform age signal updates policy decision correctly")
    func testInjectedPlatformAgeSignalPolicy() {
        let requiredSignal = PlatformAgeSignal(
            requirement: .ageCheckRequired,
            ageBand: nil,
            significantChangeConsentRequired: false
        )
        let decision = AgePolicy.decision(for: .platform(requiredSignal), context: .ordinaryUse)
        #expect(decision == .unavailableDueToConsent)
    }

    @Test("Existing preference fields survive a SwiftData round trip")
    func testPreferencesPersistenceRoundTrip() throws {
        let schema = Schema([Preferences.self])
        let configuration = ModelConfiguration(
            "PreferencesTest",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let initialPrefs = Preferences(
            accountDID: "did:plc:testuser12345",
            savedFeeds: ["at://did:plc:feed1", "at://did:plc:feed2"],
            pinnedFeeds: ["following", "at://did:plc:feed1"],
            adultContentEnabled: true,
            interests: ["swift", "atproto"],
            primaryLanguage: "ja",
            contentLanguages: ["ja", "en"],
            hideVerificationBadges: true
        )

        context.insert(initialPrefs)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Preferences>(
            predicate: #Predicate<Preferences> { $0.accountDID == "did:plc:testuser12345" }
        ))

        #expect(fetched.count == 1)
        guard let loaded = fetched.first else {
            Issue.record("Expected to find stored preferences")
            return
        }

        #expect(loaded.accountDID == "did:plc:testuser12345")
        #expect(loaded.savedFeeds == ["at://did:plc:feed1", "at://did:plc:feed2"])
        #expect(loaded.pinnedFeeds == ["following", "at://did:plc:feed1"])
        #expect(loaded.adultContentEnabled == true)
        #expect(loaded.interests == ["swift", "atproto"])
        #expect(loaded.primaryLanguage == "ja")
        #expect(loaded.contentLanguages == ["ja", "en"])
        #expect(loaded.hideVerificationBadges == true)
    }
}
