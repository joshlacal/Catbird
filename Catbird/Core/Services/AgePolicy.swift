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

    /// Bounds are evidence only for the thresholds they actually establish.
    /// Apple may return regional gates different from the requested gates.
    var isValid: Bool {
        guard lowerBound != nil || upperBound != nil else { return false }
        if let lowerBound, lowerBound < 0 { return false }
        if let upperBound, upperBound < 0 { return false }
        if let lowerBound, let upperBound, lowerBound > upperBound { return false }
        return true
    }

    var isAtLeast13: Bool {
        isValid && (lowerBound.map { $0 >= 13 } ?? false)
    }

    var isUnder13: Bool {
        guard isValid else { return false }
        if let upper = upperBound, upper < 13 {
            return true
        }
        return false
    }

    var isAdult: Bool {
        guard isValid else { return false }
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
        /// Applicability could not be determined. This never clears an earlier requirement.
        case unavailable
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
            // Significant-change applicability alone declares neither a change nor its scope.
            // It cannot create an ordinary-use gate without a separate declared change.
            switch platform.requirement {
            case .none:
                if let band = platform.ageBand, band.isUnder13 {
                    return .deny
                }
                return .allow

            case .unavailable:
                // An unavailable first lookup creates no obligation by itself. The lifecycle
                // owner retains an already-established requirement across unavailable refreshes.
                return .allow

            case .ageCheckRequired:
                guard let band = platform.ageBand, band.isValid else {
                    return .unavailableDueToConsent
                }
                if band.isUnder13 {
                    return .deny
                }
                return band.isAtLeast13 ? .allow : .unavailableDueToConsent
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
            if platform.requirement == .ageCheckRequired {
                let ordinaryDecision = evaluateStandardOperation(operation: .generalContent, signal: signal)
                if ordinaryDecision != .allow { return ordinaryDecision }
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
