import Foundation

#if canImport(Sentry)
import Sentry
#endif

enum SentryService {
    static func start() {
        #if canImport(Sentry)
        guard let dsn = resolveDSN() else { return }

        SentrySDK.start { options in
            options.dsn = dsn

            #if DEBUG
            options.debug = false  // Even in debug, disable Sentry debug to reduce noise
            options.environment = "debug"
            options.tracesSampleRate = 0.1  // Reduced for debug builds
            options.profilesSampleRate = 0.05
            #elseif BETA
            options.debug = false
            options.environment = "beta"
            options.tracesSampleRate = 0.15
            options.profilesSampleRate = 0.1
            #else
            options.debug = false
            options.environment = "production"
            options.tracesSampleRate = 0.05  // Much lower for production
            options.profilesSampleRate = 0.02
            #endif

            options.enableAppHangTracking = true

            let bundle = Bundle.main
            let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
            let build = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? ""
            options.releaseName = "Catbird@\(version)+\(build)"

            // Filter out noisy/benign errors
            options.beforeSend = { event in
                return filterEvent(event)
            }
        }
        #endif
    }

    static func addBreadcrumb(level: String, category: String, message: String) {
        #if canImport(Sentry)
        let crumb = Breadcrumb(level: mapLevel(level), category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    static func captureMessage(_ message: String, level: String, category: String) {
        #if canImport(Sentry)
        let event = Event(level: mapLevel(level))
        event.message = SentryMessage(formatted: message)
        event.tags = ["category": category]
        SentrySDK.capture(event: event)
        #endif
    }

    static func captureMessage(_ message: String, level: String, category: String, extras: [String: Any]?) {
        #if canImport(Sentry)
        let event = Event(level: mapLevel(level))
        event.message = SentryMessage(formatted: message)
        event.tags = ["category": category]
        if let extras {
            // Filter extras to JSON-serializable values
            var filtered: [String: Any] = [:]
            for (k, v) in extras { filtered[k] = v }
            event.extra = filtered
        }
        SentrySDK.capture(event: event)
        #endif
    }

    // MARK: - Helpers

    private static func resolveDSN() -> String? {
        if let env = ProcessInfo.processInfo.environment["SENTRY_DSN"], !env.isEmpty { return env }
        if let dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String, !dsn.isEmpty { return dsn }
        // Fallback to hardcoded DSN
        return "https://8c18bec496916e4617cdfbe0eb76bc6d@o4505190177701888.ingest.us.sentry.io/4510009092341760"
    }

    #if canImport(Sentry)
    private static func filterEvent(_ event: Event) -> Event? {
        // Drop events that are clearly noise
        if let message = event.message?.formatted {
            // Filter out verbose debug messages
            if message.contains("🔍 DEBUG:") ||
               message.contains("Starting atomic account") ||
               message.contains("Session saved to temporary location") ||
               message.contains("Account moved to final location") ||
               message.contains("Session save verification") {
                return nil
            }

            // Filter out benign decoding errors
            if message.contains("Failed to decode") && (
                message.contains("optional") ||
                message.contains("unknown field") ||
                message.contains("missing key") ||
                message.contains("type mismatch")
            ) {
                return nil
            }

            // Filter out network connectivity issues (transient)
            if message.contains("Network Service") && (
                message.contains("Network error:") ||
                message.contains("timeout") ||
                message.contains("connection") ||
                message.contains("offline")
            ) {
                return nil
            }

            // Filter out common network errors by pattern matching
            let benignNetworkPatterns = [
                "The Internet connection appears to be offline",
                "The request timed out",
                "A server with the specified hostname could not be found",
                "The network connection was lost",
                "Could not connect to the server",
                "URLSessionTask completed with error"
            ]

            for pattern in benignNetworkPatterns {
                if message.contains(pattern) {
                    return nil
                }
            }

            // Filter out common system errors
            let benignSystemPatterns = [
                "Operation was cancelled",
                "The operation couldn't be completed",
                "Background task expired"
            ]

            for pattern in benignSystemPatterns {
                if message.contains(pattern) {
                    return nil
                }
            }

            // Filter out cancellation errors (user-initiated)
            if message.contains("cancelled") || message.contains("Task was cancelled") {
                return nil
            }

            // Filter out debug messages and specific patterns
            if message.contains("🔍 DEBUG:") {
                return nil
            }

            // Keep auth incidents but filter non-critical ones
            if message.contains("AUTH_INCIDENT") {
                if message.contains("AccountAutoSwitched") ||
                   message.contains("TokenRefresh") ||
                   message.contains("NetworkRetry") {
                    // Downgrade to breadcrumb only for non-critical auth events
                    return nil
                }
            }
        }

        // Filter by error category - keep only critical errors
        if let tags = event.tags, let category = tags["category"] {
            if category == "Petrel.Network" {
                // Only keep server errors (5xx) and authentication failures
                if let message = event.message?.formatted {
                    if !message.contains("500") &&
                       !message.contains("401") &&
                       !message.contains("403") &&
                       !message.contains("AUTH_LOGOUT") &&
                       !message.contains("authentication failed") {
                        return nil
                    }
                }
            }
        }

        // Apply rate limiting - sample non-critical events
        if event.level == .info || event.level == .debug {
            // Only send 10% of info/debug events
            if Int.random(in: 0..<10) != 0 {
                return nil
            }
        }

        return event
    }
    #endif

    #if canImport(Sentry)
    private static func mapLevel(_ level: String) -> SentryLevel {
        switch level {
        case "debug": return .debug
        case "info": return .info
        case "error": return .error
        default: return .info
        }
    }
    #endif
}
