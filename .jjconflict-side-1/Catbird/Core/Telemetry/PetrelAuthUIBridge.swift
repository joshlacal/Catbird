import Foundation
import OSLog
import Petrel

/// Bridges Petrel auth events into Catbird UI state so auto-logout is visible and consistent.
enum PetrelAuthUIBridge {
    private static let logger = Logger(subsystem: "blue.catbird", category: "AuthUIBridge")

    static func enable() {
        // Use new typed auth event system - no string parsing needed
        PetrelAuthEvents.addObserver { event in
            switch event {
            case let .autoLogoutTriggered(did, reason):
                Task { @MainActor in
                    logger.error("UI handling auto logout did=\(did) reason=\(reason)")
                    await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(did: did, reason: reason)
                }

            case let .logoutStarted(did, reason):
                Task { @MainActor in
                    logger.info("Logout started did=\(did) reason=\(reason ?? "nil")")
                    await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(did: did, reason: reason)
                }

            case let .logoutNoAutoSwitch(did):
                Task { @MainActor in
                    logger.warning("No account to switch to after logout did=\(did)")
                    // User needs to log in - UI should show login screen
                    await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(did: did, reason: "no_accounts_available")
                }

            case let .refreshTokenInvalid(did, statusCode, error):
                Task { @MainActor in
                    logger.error("Refresh token invalid did=\(did) status=\(statusCode) error=\(error)")
                    // Token is invalid, session will be terminated
                }

            case let .sessionMissing(did, context):
                Task { @MainActor in
                    logger.warning("Session missing did=\(did) context=\(context)")
                }

            default:
                // Other auth events are informational, no UI action needed
                break
            }
        }
    }
}

