import Foundation
import Petrel

enum PetrelSentryBridge {
    static func enable() {
        // Hook Petrel logs into Sentry without adding Sentry to Petrel
        PetrelLog.addObserver { event in
            let category: String
            switch event.category {
            case .network: category = "Petrel.Network"
            case .authentication: category = "Petrel.Authentication"
            case .general: category = "Petrel.General"
            }

            // Always add breadcrumb for trace context
            let lvl: String = {
                switch event.level { case .debug: return "debug"; case .info: return "info"; case .warning: return "warning"; case .error: return "error" }
            }()
            SentryService.addBreadcrumb(level: lvl, category: category, message: event.message)

            // Promote to events selectively and enrich auth incidents
            let isAuth = (event.category == .authentication)
            let isWarnOrError = (event.level == .warning || event.level == .error)

            // Parse AUTH_INCIDENT payloads for rich context
            if event.message.hasPrefix("AUTH_INCIDENT ") {
                let jsonPart = String(event.message.dropFirst("AUTH_INCIDENT ".count))
                var extras: [String: Any] = [:]
                if let data = jsonPart.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    extras = obj
                }
                SentryService.captureMessage(event.message, level: "warning", category: category, extras: extras)
                return
            }

            // Parse AUTH_LOGOUT lines for reason/DID
            if event.message.hasPrefix("AUTH_LOGOUT ") {
                var extras: [String: Any] = [:]
                // Very simple token parsing: AUTH_LOGOUT did=... reason=...
                let parts = event.message.split(separator: " ")
                for p in parts {
                    if p.hasPrefix("did=") {
                        extras["did"] = String(p.dropFirst(4))
                    } else if p.hasPrefix("reason=") {
                        extras["reason"] = String(p.dropFirst(7))
                    }
                }
                SentryService.captureMessage(event.message, level: "error", category: category, extras: extras)
                return
            }

            // Otherwise, promote errors (all categories) and also auth warnings
            if event.level == .error {
                SentryService.captureMessage(event.message, level: "error", category: category)
            } else if isAuth && isWarnOrError {
                SentryService.captureMessage(event.message, level: lvl, category: category)
            }
        }
    }
}
