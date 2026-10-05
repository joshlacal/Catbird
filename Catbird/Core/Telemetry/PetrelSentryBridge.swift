import Foundation
import Petrel

enum PetrelSentryBridge {
    static func enable() {
        // Use new typed auth event system for auth-specific tracking
        PetrelAuthEvents.addObserver { event in
            let extras = authEventToExtras(event)
            let (level, message) = authEventToSentry(event)

            if level == "info" {
                // Info-level auth events are informational — record as breadcrumbs
                // to avoid creating Sentry issues for routine state changes.
                SentryService.addBreadcrumb(level: level, category: "Petrel.Authentication", message: message)
            } else {
                SentryService.captureMessage(message, level: level, category: "Petrel.Authentication", extras: extras)
            }
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

    // Account identifiers (DIDs) are deliberately left out of everything sent to Sentry:
    // crash and diagnostic data is declared as not linked to the user.

    private static func authEventToExtras(_ event: AuthEvent) -> [String: Any] {
        switch event {
        case let .autoLogoutTriggered(_, reason):
            return ["type": "AutoLogoutTriggered", "reason": reason]

        case let .logoutStarted(_, reason):
            return ["type": "LogoutStarted", "reason": reason ?? "unknown"]

        case .logoutNoAutoSwitch:
            return ["type": "LogoutNoAutoSwitch"]

        case .logoutAutoSwitched:
            return ["type": "LogoutAutoSwitched"]

        case let .refreshTokenInvalid(_, statusCode, error):
            return ["type": "RefreshTokenInvalid", "statusCode": statusCode, "error": error]

        case let .invalidClientMetadata(_, statusCode, error):
            return ["type": "InvalidClientMetadata", "statusCode": statusCode, "error": error]

        case let .invalidClient(_, statusCode, error):
            return ["type": "InvalidClient", "statusCode": statusCode, "error": error]

        case let .sessionMissing(_, context):
            return ["type": "SessionMissing", "context": context]

        case let .accountAutoSwitched(_, newDid, reason):
            return ["type": "AccountAutoSwitched", "hasNewAccount": newDid != nil, "reason": reason]

        case let .currentAccountChanged(previousDid, _):
            return ["type": "CurrentAccountChanged", "hadPreviousAccount": previousDid != nil]

        case let .dpopNonceMismatch(_, retryAttempt):
            return ["type": "DPoPNonceMismatch", "retryAttempt": retryAttempt]

        case let .startupInconsistentState(_, hasAccount, hasSession, hasDPoPKey):
            return ["type": "StartupInconsistentState", "hasAccount": hasAccount, "hasSession": hasSession, "hasDPoPKey": hasDPoPKey]

        case let .startupMissingSession(_, hasDPoPKey):
            return ["type": "StartupMissingSession", "hasDPoPKey": hasDPoPKey]

        case let .startupMissingDPoPKey(_, hasSession):
            return ["type": "StartupMissingDPoPKey", "hasSession": hasSession]

        case .startupStateHealthy:
            return ["type": "StartupStateHealthy"]

        case .logoutClearedCurrentAccount:
            return ["type": "LogoutClearedCurrentAccount"]

        case .accountNotFound:
            return ["type": "AccountNotFound"]

        case .setCurrentAccountNoSession:
            return ["type": "SetCurrentAccountNoSession"]

        case let .storageFailure(_, error):
            return ["type": "StorageFailure", "error": error]

        case .inconsistentStateMissingSession:
            return ["type": "InconsistentStateMissingSession"]

        case .inconsistentStateMissingAccount:
            return ["type": "InconsistentStateMissingAccount"]
        }
    }

    private static func authEventToSentry(_ event: AuthEvent) -> (level: String, message: String) {
        switch event {
        case let .autoLogoutTriggered(_, reason):
            return ("error", "Auto logout triggered: \(reason)")

        case .logoutStarted:
            return ("info", "Logout started")

        case .logoutNoAutoSwitch:
            return ("warning", "No account available after logout")

        case .logoutAutoSwitched:
            return ("info", "Account auto-switched after logout")

        case let .refreshTokenInvalid(_, statusCode, _):
            return ("error", "Refresh token invalid (status: \(statusCode))")

        case .invalidClientMetadata:
            return ("error", "Invalid client metadata")

        case .invalidClient:
            return ("error", "Invalid client")

        case let .sessionMissing(_, context):
            return ("warning", "Session missing in \(context)")

        case .accountAutoSwitched:
            return ("info", "Account auto-switched")

        case .currentAccountChanged:
            return ("info", "Current account changed")

        case let .dpopNonceMismatch(_, attempt):
            return ("warning", "DPoP nonce mismatch (attempt \(attempt))")

        case .startupInconsistentState:
            return ("warning", "Startup: inconsistent state")

        case .startupMissingSession:
            return ("warning", "Startup: missing session")

        case .startupMissingDPoPKey:
            return ("warning", "Startup: missing DPoP key")

        case .startupStateHealthy:
            return ("info", "Startup: auth state healthy")

        case .logoutClearedCurrentAccount:
            return ("info", "Logout cleared current account")

        case .accountNotFound:
            return ("warning", "Account not found")

        case .setCurrentAccountNoSession:
            return ("warning", "No session when setting current account")

        case let .storageFailure(_, error):
            return ("error", "Storage failure: \(error)")

        case .inconsistentStateMissingSession:
            return ("warning", "Inconsistent state: missing session")

        case .inconsistentStateMissingAccount:
            return ("warning", "Inconsistent state: missing account")
        }
    }
}
