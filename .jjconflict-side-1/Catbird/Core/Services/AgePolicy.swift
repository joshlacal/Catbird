import Foundation
import Petrel

/// Coarse age band supplied by platform or provider.
/// Never stores exact age or birth date.
struct AgeBand: Sendable, Equatable {
    let lowerBound: Int?
    let upperBound: Int?

    init(lowerBound: Int? = nil, upperBound: Int? = nil) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    static let under13 = AgeBand(lowerBound: nil, upperBound: 12)
    static let teen = AgeBand(lowerBound: 13, upperBound: 17)
    static let adult = AgeBand(lowerBound: 18, upperBound: nil)

    var isUnder13: Bool {
        if let upper = upperBound, upper < 13 {
            return true
        }
        return false
    }

    var isAdult: Bool {
        if let lower = lowerBound, lower >= 18 {
            return true
        }
        return false
    }
}

/// Sanitized platform age signal from OS regulatory APIs.
struct PlatformAgeSignal: Sendable, Equatable {
    let requirement: Requirement
    let ageBand: AgeBand?
    let significantChangeConsentRequired: Bool

    static let none = PlatformAgeSignal()

    init(
        requirement: Requirement = .none,
        ageBand: AgeBand? = nil,
        significantChangeConsentRequired: Bool = false
    ) {
        self.requirement = requirement
        self.ageBand = ageBand
        self.significantChangeConsentRequired = significantChangeConsentRequired
    }
    enum Requirement: Sendable, Equatable {
        case none
        case ageCheckRequired
    }
}

/// Operation subject to age policy evaluation.
enum AgeRestrictedOperation: Sendable, Equatable, Hashable {
    case generalContent
    case matureContent
    case directMessaging
    case groupMessaging
    case custom(String)
}

/// Validated provider-owned URL for out-of-band verification.
struct TrustedHandoff: Sendable, Equatable {
    let url: URL

    /// Initializes a trusted handoff if the URL has HTTPS scheme, a non-empty host,
    /// and satisfies the provider ownership validator predicate.
    init?(
        url: URL,
        isProviderOwned: (URL) -> Bool
    ) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else {
            return nil
        }
        guard isProviderOwned(url) else {
            return nil
        }
        self.url = url
    }
}

/// Service-enforced restriction returned by an AT Protocol provider.
struct ProviderRestriction: Sendable, Equatable {
    let provider: DID
    let operation: AgeRestrictedOperation
    let reason: Reason
    let handoff: TrustedHandoff?

    init(
        provider: DID,
        operation: AgeRestrictedOperation = .generalContent,
        reason: Reason = .ageRestricted,
        handoff: TrustedHandoff? = nil
    ) {
        self.provider = provider
        self.operation = operation
        self.reason = reason
        self.handoff = handoff
    }

    enum Reason: Sendable, Equatable {
        case ageAssuranceRequired
        case parentalConsentRequired
        case ageRestricted
        case custom(String)
    }
}

/// Input signal to age policy evaluation.
enum AgeSignal: Sendable, Equatable {
    case unknown
    case platform(PlatformAgeSignal)
    case provider(ProviderRestriction)
}

/// Evaluated age policy decision.
enum AgePolicyDecision: Sendable, Equatable {
    case allow
    case hideSensitiveContent
    case requireProviderVerification(TrustedHandoff)
    case unavailableDueToConsent
    case deny
}

/// Context in which age policy is evaluated.
enum AgePolicyContext: Sendable, Equatable {
    case ordinaryUse
    case matureContent
    case operation(AgeRestrictedOperation)
}

/// Pure policy evaluator mapping age signals and contexts to decisions.
struct AgePolicy: Sendable {
    typealias Context = AgePolicyContext

    /// Pure function computing policy decision for a given signal and context.
    static func decision(
        for signal: AgeSignal,
        context: AgePolicyContext = .ordinaryUse
    ) -> AgePolicyDecision {
        let operation: AgeRestrictedOperation
        switch context {
        case .ordinaryUse:
            operation = .generalContent
        case .matureContent:
            operation = .matureContent
        case .operation(let op):
            operation = op
        }
        return evaluate(operation: operation, signal: signal)
    }

    // MARK: - Private Evaluators

    private static func evaluate(
        operation: AgeRestrictedOperation,
        signal: AgeSignal
    ) -> AgePolicyDecision {
        if operation == .matureContent {
            return evaluateMatureContent(signal: signal)
        }
        return evaluateStandardOperation(operation: operation, signal: signal)
    }

    private static func evaluateStandardOperation(
        operation: AgeRestrictedOperation,
        signal: AgeSignal
    ) -> AgePolicyDecision {
        switch signal {
        case .unknown:
            return .allow

        case .platform(let platform):
            if platform.significantChangeConsentRequired {
                return .unavailableDueToConsent
            }
            switch platform.requirement {
            case .none:
                if let band = platform.ageBand, band.isUnder13 {
                    return .deny
                }
                return .allow

            case .ageCheckRequired:
                guard let band = platform.ageBand else {
                    return .unavailableDueToConsent
                }
                if band.isUnder13 {
                    return .deny
                }
                return .allow
            }

        case .provider(let restriction):
            if restriction.operation == operation || restriction.operation == .generalContent {
                if let handoff = restriction.handoff {
                    return .requireProviderVerification(handoff)
                }
                return .deny
            }
            return .allow
        }
    }

    private static func evaluateMatureContent(signal: AgeSignal) -> AgePolicyDecision {
        switch signal {
        case .unknown:
            return .hideSensitiveContent

        case .platform(let platform):
            if platform.significantChangeConsentRequired {
                return .unavailableDueToConsent
            }
            if platform.requirement == .ageCheckRequired && platform.ageBand == nil {
                return .unavailableDueToConsent
            }
            if let band = platform.ageBand, band.isUnder13 {
                return .deny
            }
            // Adult or teen coarse band never enables mature content at policy level.
            // Moderation preferences remain authoritative for rendering.
            return .hideSensitiveContent

        case .provider(let restriction):
            if restriction.operation == .matureContent || restriction.operation == .generalContent {
                if let handoff = restriction.handoff {
                    return .requireProviderVerification(handoff)
                }
                return .deny
            }
            return .hideSensitiveContent
        }
    }
}
