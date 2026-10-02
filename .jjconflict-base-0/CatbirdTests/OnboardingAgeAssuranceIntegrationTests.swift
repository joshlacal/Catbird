import Foundation
import Petrel
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Catbird

// MARK: - Spy Regulatory Checker

final class SpyRegulatoryChecker: AgeRegulatoryChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _preflightCount = 0
    private var _agePromptCount = 0
    private var _providerRequestCount = 0
    private var preflightContinuations: [CheckedContinuation<Void, Never>] = []

    var signalToReturn: PlatformAgeSignal = PlatformAgeSignal(
        requirement: .none,
        ageBand: nil,
        significantChangeConsentRequired: false
    )

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

    var providerRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _providerRequestCount
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
        return signalToReturn
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
        return signalToReturn.ageBand
    }
    #endif
}

// MARK: - Onboarding & Intent Integration Tests

@Suite("OnboardingAgeAssuranceIntegrationTests")
struct OnboardingAgeAssuranceIntegrationTests {
    
    @Test("Passive regulatory preflight runs on AppState launch without prompts or provider network calls")
    @MainActor
    func passiveRegulatoryPreflight() async {
        let spy = SpyRegulatoryChecker()
        let expectedSignal = PlatformAgeSignal(
            requirement: .none,
            ageBand: nil,
            significantChangeConsentRequired: false
        )
        spy.signalToReturn = expectedSignal

        let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
        let appState = AppState(
            userDID: "did:plc:testuseronboarding123",
            client: client,
            regulatoryChecker: spy
        )

        await spy.waitForPreflight()

        for _ in 0..<50 {
            if appState.platformAgeSignal == expectedSignal {
                break
            }
            await Task.yield()
        }

        #expect(spy.preflightCount == 1)
        #expect(spy.agePromptCount == 0)
        #expect(spy.providerRequestCount == 0)
        #expect(appState.platformAgeSignal.requirement == .none)
        #expect(appState.platformAgeSignal.ageBand == nil)
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
