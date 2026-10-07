import Foundation
import OSLog
import Petrel

/// Bridges scoped Petrel failures into Catbird after the emitting SDK storage locks release.
enum PetrelAuthUIBridge {
    private static let logger = Logger(subsystem: "blue.catbird", category: "AuthUIBridge")

    static func enable() {
        PetrelAuthEvents.addObserver { event in
            switch event {
            case let .gatewaySessionRejected(context, reason):
                await AppStateManager.shared.authentication.handleGatewaySessionFailure(
                    did: context.did, reason: reason
                ) { client in
                    await client.isCurrentGatewaySessionFailure(context)
                }
            // Legacy emitters have not been audited for lock-free delivery. Their
            // fallback validator may refresh; preserve their existing queued delivery.
            // Gateway clients ignore these unproven events, even when delivered late.
            case let .autoLogoutTriggered(did, reason):
                Task { @MainActor in
                    await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(did: did, reason: reason)
                }
            case let .logoutStarted(did, reason):
                Task { @MainActor in
                    await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(did: did, reason: reason)
                }
            case let .logoutNoAutoSwitch(did):
                Task { @MainActor in
                    await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(
                        did: did, reason: "no_accounts_available"
                    )
                }
            case .refreshTokenInvalid:
                logger.error("Refresh token rejected")
            case .sessionMissing:
                logger.warning("Session missing")
            default:
                break
            }
        }
    }
}
