import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(DeclaredAgeRange)
import DeclaredAgeRange
#endif

/// Protocol for platform-level age regulatory checking and coarse age acquisition.
protocol AgeRegulatoryChecking: Sendable {
    /// Passively queries on-device regulatory requirements without network calls or user prompts.
    func preflight() async -> PlatformAgeSignal

    #if canImport(UIKit)
    /// Prompts for coarse age range through platform system UI using minimum standard gates (13, 18).
    /// Discards all declaration methods, parental controls, and exact identity evidence.
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand?
    #endif
}

/// Native Apple DeclaredAgeRange platform adapter.
/// This is the only production type permitted to import `DeclaredAgeRange`.
final class AppleAgeRangeAdapter: AgeRegulatoryChecking, Sendable {
    static let shared = AppleAgeRangeAdapter()

    init() {}

    func preflight() async -> PlatformAgeSignal {
        #if canImport(DeclaredAgeRange)
        if #available(iOS 26.4, macOS 26.4, *) {
            do {
                let service = AgeRangeService.shared
                let features = try await service.requiredRegulatoryFeatures
                let ageRequired = features.contains(.declaredAgeRangeRequired)
                let consentRequired = features.contains(.significantAppChangeRequiresParentalConsent)
                return PlatformAgeSignal(
                    requirement: ageRequired ? .ageCheckRequired : .none,
                    ageBand: nil,
                    significantChangeConsentRequired: consentRequired
                )
            } catch {
                // Unsupported or unavailable returns no affirmative requirement
                return PlatformAgeSignal(
                    requirement: .none,
                    ageBand: nil,
                    significantChangeConsentRequired: false
                )
            }
        } else if #available(iOS 26.2, macOS 26.2, *) {
            do {
                let service = AgeRangeService.shared
                let eligible = try await service.isEligibleForAgeFeatures
                return PlatformAgeSignal(
                    requirement: eligible ? .ageCheckRequired : .none,
                    ageBand: nil,
                    significantChangeConsentRequired: false
                )
            } catch {
                return PlatformAgeSignal(
                    requirement: .none,
                    ageBand: nil,
                    significantChangeConsentRequired: false
                )
            }
        } else {
            return PlatformAgeSignal(
                requirement: .none,
                ageBand: nil,
                significantChangeConsentRequired: false
            )
        }
        #else
        return PlatformAgeSignal(
            requirement: .none,
            ageBand: nil,
            significantChangeConsentRequired: false
        )
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? {
        #if canImport(DeclaredAgeRange)
        if #available(iOS 26.0, macOS 26.0, *) {
            let service = AgeRangeService.shared
            let response = try await service.requestAgeRange(ageGates: 13, 18, in: viewController)
            switch response {
            case .declinedSharing:
                return nil
            case .sharing(let range):
                // Copies only lowerBound / upperBound; discards ageRangeDeclaration and activeParentalControls
                return AgeBand(lowerBound: range.lowerBound, upperBound: range.upperBound)
            @unknown default:
                return nil
            }
        } else {
            return nil
        }
        #else
        return nil
        #endif
    }
    #endif
}
