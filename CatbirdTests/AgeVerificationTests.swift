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

    @Test("Significant change consent requirement renders ordinary use unavailable")
    func testSignificantChangeConsentRequired() {
        let signal = PlatformAgeSignal(
            requirement: .none,
            ageBand: .adult,
            significantChangeConsentRequired: true
        )
        #expect(AgePolicy.decision(for: .platform(signal), context: .ordinaryUse) == .unavailableDueToConsent)
        #expect(AgePolicy.decision(for: .platform(signal), context: .matureContent) == .unavailableDueToConsent)
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

    @Test("AgeBand exposes only coarse bounds and no exact age or birth date")
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

    @Test("Pre-iOS 26.2 or unavailable preflight signal is neutral")
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

    final class SpyAgeRegulatoryChecker: AgeRegulatoryChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var _preflightCount: Int = 0
        private var _agePromptCount: Int = 0
        private var preflightContinuations: [CheckedContinuation<Void, Never>] = []

        var stubbedSignal: PlatformAgeSignal = .none

        var preflightCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _preflightCount
        }

        var agePromptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _agePromptCount
        }

        func preflight() async -> PlatformAgeSignal {
            lock.lock()
            _preflightCount += 1
            let continuations = preflightContinuations
            preflightContinuations.removeAll()
            lock.unlock()
            for cont in continuations {
                cont.resume()
            }
            return stubbedSignal
        }

        func waitForPreflight() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if _preflightCount > 0 {
                    lock.unlock()
                    continuation.resume()
                } else {
                    preflightContinuations.append(continuation)
                    lock.unlock()
                }
            }
        }

        #if canImport(UIKit)
        @MainActor
        func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? {
            lock.lock()
            _agePromptCount += 1
            lock.unlock()
            return stubbedSignal.ageBand
        }
        #endif
    }

    @Test("AppState launch preflight executes passively with injected regulatory checker")
    @MainActor
    func testAppStateLaunchPreflightIntegration() async {
        let spy = SpyAgeRegulatoryChecker()
        let stubbedSignal = PlatformAgeSignal(
            requirement: .ageCheckRequired,
            ageBand: .teen,
            significantChangeConsentRequired: false
        )
        spy.stubbedSignal = stubbedSignal

        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(
            userDID: "did:plc:testuser1234567890ab",
            client: client,
            regulatoryChecker: spy
        )

        // Wait deterministically for preflight to execute
        await spy.waitForPreflight()

        // Yield to let the MainActor task update AppState.platformAgeSignal
        for _ in 0..<50 {
            if appState.platformAgeSignal == stubbedSignal {
                break
            }
            await Task.yield()
        }

        #expect(spy.preflightCount == 1)
        #expect(spy.agePromptCount == 0)
        #expect(appState.platformAgeSignal == stubbedSignal)
        #expect(AgePolicy.decision(for: .platform(appState.platformAgeSignal), context: .ordinaryUse) == .allow)
        #expect(AgePolicy.decision(for: .platform(appState.platformAgeSignal), context: .matureContent) == .hideSensitiveContent)
    }

    @Test("AppState account-eviction cleanup resets platformAgeSignal to none")
    @MainActor
    func testAppStateCleanupResetsPlatformAgeSignal() async {
        let spy = SpyAgeRegulatoryChecker()
        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(
            userDID: "did:plc:testuser1234567890ab",
            client: client,
            regulatoryChecker: spy
        )

        let coarseSignal = PlatformAgeSignal(
            requirement: .ageCheckRequired,
            ageBand: .adult,
            significantChangeConsentRequired: false
        )
        appState.platformAgeSignal = coarseSignal
        #expect(appState.platformAgeSignal == coarseSignal)

        // Real account-eviction cleanup path (without calling refreshAfterAccountSwitch)
        appState.cleanup()

        #expect(appState.platformAgeSignal == .none)
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

    @Test("Preferences SwiftData model round-trips correctly without age data")
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
