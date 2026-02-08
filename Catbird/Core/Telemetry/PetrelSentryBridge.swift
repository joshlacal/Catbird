import Foundation
import Petrel

enum PetrelSentryBridge {
    static func enable() {
        // Use new typed auth event system for auth-specific tracking
        PetrelAuthEvents.addObserver { event in
            let extras = authEventToExtras(event)
            let (level, message) = authEventToSentry(event)
            SentryService.captureMessage(message, level: level, category: "Petrel.Authentication", extras: extras)
        }

        // Keep legacy log observer for non-auth breadcrumbs (network, general)
        // Note: Auth logs no longer trigger this due to LogManager optimization
        PetrelLog.addObserver { event in
            // Skip debug-level events to reduce Sentry breadcrumb overhead
            guard event.level != .debug else { return }

            let category: String
            switch event.category {
            case .network: category = "Petrel.Network"
            case .authentication: category = "Petrel.Authentication"
            case .general: category = "Petrel.General"
            }

            let lvl: String = {
                switch event.level {
                case .debug: return "debug"
                case .info: return "info"
                case .warning: return "warning"
                case .error: return "error"
                }
            }()

            // Add breadcrumb for all non-debug events
            SentryService.addBreadcrumb(level: lvl, category: category, message: event.message)

            // Promote errors to Sentry events
            if event.level == .error {
                SentryService.captureMessage(event.message, level: "error", category: category)
            }
        }
    }

    // MARK: - Auth Event Helpers

    private static func authEventToExtras(_ event: AuthEvent) -> [String: Any] {
        switch event {
        case let .autoLogoutTriggered(did, reason):
            return ["type": "AutoLogoutTriggered", "did": did, "reason": reason]

        case let .logoutStarted(did, reason):
            return ["type": "LogoutStarted", "did": did, "reason": reason ?? "unknown"]

        case let .logoutNoAutoSwitch(did):
            return ["type": "LogoutNoAutoSwitch", "did": did]

        case let .logoutAutoSwitched(previousDid, newDid):
            return ["type": "LogoutAutoSwitched", "previousDid": previousDid, "newDid": newDid]

        case let .refreshTokenInvalid(did, statusCode, error):
            return ["type": "RefreshTokenInvalid", "did": did, "statusCode": statusCode, "error": error]

        case let .invalidClientMetadata(did, statusCode, error):
            return ["type": "InvalidClientMetadata", "did": did, "statusCode": statusCode, "error": error]

        case let .invalidClient(did, statusCode, error):
            return ["type": "InvalidClient", "did": did, "statusCode": statusCode, "error": error]

        case let .sessionMissing(did, context):
            return ["type": "SessionMissing", "did": did, "context": context]

        case let .accountAutoSwitched(previousDid, newDid, reason):
            return ["type": "AccountAutoSwitched", "previousDid": previousDid, "newDid": newDid ?? "nil", "reason": reason]

        case let .currentAccountChanged(previousDid, newDid):
            return ["type": "CurrentAccountChanged", "previousDid": previousDid ?? "nil", "newDid": newDid]

        case let .dpopNonceMismatch(did, retryAttempt):
            return ["type": "DPoPNonceMismatch", "did": did, "retryAttempt": retryAttempt]

        case let .startupInconsistentState(did, hasAccount, hasSession, hasDPoPKey):
            return ["type": "StartupInconsistentState", "did": did, "hasAccount": hasAccount, "hasSession": hasSession, "hasDPoPKey": hasDPoPKey]

        case let .startupMissingSession(did, hasDPoPKey):
            return ["type": "StartupMissingSession", "did": did, "hasDPoPKey": hasDPoPKey]

        case let .startupMissingDPoPKey(did, hasSession):
            return ["type": "StartupMissingDPoPKey", "did": did, "hasSession": hasSession]

        case let .startupStateHealthy(did):
            return ["type": "StartupStateHealthy", "did": did]

        case let .logoutClearedCurrentAccount(previousDid):
            return ["type": "LogoutClearedCurrentAccount", "previousDid": previousDid]

        case let .accountNotFound(did):
            return ["type": "AccountNotFound", "did": did]

        case let .setCurrentAccountNoSession(did):
            return ["type": "SetCurrentAccountNoSession", "did": did]

        case let .storageFailure(did, error):
            return ["type": "StorageFailure", "did": did, "error": error]

        case let .inconsistentStateMissingSession(did):
            return ["type": "InconsistentStateMissingSession", "did": did]

        case let .inconsistentStateMissingAccount(did):
            return ["type": "InconsistentStateMissingAccount", "did": did]
        }
    }

    private static func authEventToSentry(_ event: AuthEvent) -> (level: String, message: String) {
        switch event {
        case let .autoLogoutTriggered(did, reason):
            return ("error", "Auto logout triggered for \(did): \(reason)")

        case let .logoutStarted(did, _):
            return ("info", "Logout started for \(did)")

        case .logoutNoAutoSwitch:
            return ("warning", "No account available after logout")

        case .logoutAutoSwitched:
            return ("info", "Account auto-switched after logout")

        case let .refreshTokenInvalid(did, statusCode, _):
            return ("error", "Refresh token invalid for \(did) (status: \(statusCode))")

        case let .invalidClientMetadata(did, _, _):
            return ("error", "Invalid client metadata for \(did)")

        case let .invalidClient(did, _, _):
            return ("error", "Invalid client for \(did)")

        case let .sessionMissing(did, context):
            return ("warning", "Session missing for \(did) in \(context)")

        case .accountAutoSwitched:
            return ("info", "Account auto-switched")

        case .currentAccountChanged:
            return ("info", "Current account changed")

        case let .dpopNonceMismatch(did, attempt):
            return ("warning", "DPoP nonce mismatch for \(did) (attempt \(attempt))")

        case let .startupInconsistentState(did, _, _, _):
            return ("warning", "Startup: inconsistent state for \(did)")

        case let .startupMissingSession(did, _):
            return ("warning", "Startup: missing session for \(did)")

        case let .startupMissingDPoPKey(did, _):
            return ("warning", "Startup: missing DPoP key for \(did)")

        case .startupStateHealthy:
            return ("info", "Startup: auth state healthy")

        case .logoutClearedCurrentAccount:
            return ("info", "Logout cleared current account")

        case let .accountNotFound(did):
            return ("warning", "Account not found: \(did)")

        case let .setCurrentAccountNoSession(did):
            return ("warning", "No session when setting current account: \(did)")

        case let .storageFailure(did, error):
            return ("error", "Storage failure for \(did): \(error)")

        case let .inconsistentStateMissingSession(did):
            return ("warning", "Inconsistent state: missing session for \(did)")

        case let .inconsistentStateMissingAccount(did):
            return ("warning", "Inconsistent state: missing account for \(did)")
        }
    }
}
