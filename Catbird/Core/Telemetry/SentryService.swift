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

            // Disable launch profiling - it initializes too early during +load
            // and can cause crashes in SentryFileManager during dyld initialization
            options.enableAppLaunchProfiling = false

            let bundle = Bundle.main
            let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
            let build = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? ""
            options.releaseName = "Catbird@\(version)+\(build)"

            // Crash and diagnostic data is declared as not linked to the user, so no
            // user identity is attached and account identifiers are scrubbed everywhere.
            options.sendDefaultPii = false

            // Filter out noisy/benign errors
            options.beforeSend = { event in
                guard let event = filterEvent(event) else { return nil }
                return redactEvent(event)
            }
            options.beforeBreadcrumb = { crumb in
                redactBreadcrumb(crumb)
            }
            options.beforeSendSpan = { span in
                if let description = span.spanDescription {
                    span.spanDescription = redactingAccountIdentifiers(description)
                }
                for (key, value) in span.data {
                    if let text = value as? String {
                        span.setData(value: redactingAccountIdentifiers(text), key: key)
                    }
                }
                return span
            }
        }
        #endif
    }

    static func addBreadcrumb(level: String, category: String, message: String) {
        #if canImport(Sentry)
        let crumb = Breadcrumb(level: mapLevel(level), category: category)
        crumb.message = redactingAccountIdentifiers(message)
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    static func captureMessage(_ message: String, level: String, category: String) {
        #if canImport(Sentry)
        let event = Event(level: mapLevel(level))
        event.message = SentryMessage(formatted: redactingAccountIdentifiers(message))
        event.tags = ["category": category]
        SentrySDK.capture(event: event)
        #endif
    }

    static func captureMessage(_ message: String, level: String, category: String, extras: [String: Any]?) {
        #if canImport(Sentry)
        let event = Event(level: mapLevel(level))
        event.message = SentryMessage(formatted: redactingAccountIdentifiers(message))
        event.tags = ["category": category]
        if let extras {
            // Filter extras to JSON-serializable values
            var filtered: [String: Any] = [:]
            for (k, v) in extras { filtered[k] = redactingAccountIdentifiers(in: v) }
            event.extra = filtered
        }
        SentrySDK.capture(event: event)
        #endif
    }

    static func captureEvent(
        message: String,
        level: String,
        category: String,
        tags: [String: String]? = nil,
        extras: [String: Any]? = nil,
        fingerprint: [String]? = nil
    ) {
        #if canImport(Sentry)
        let event = Event(level: mapLevel(level))
        event.message = SentryMessage(formatted: redactingAccountIdentifiers(message))
        var combinedTags = tags ?? [:]
        combinedTags["category"] = category
        event.tags = combinedTags
        if let extras {
            var filtered: [String: Any] = [:]
            for (k, v) in extras { filtered[k] = redactingAccountIdentifiers(in: v) }
            event.extra = filtered
        }
        if let fingerprint {
            event.fingerprint = fingerprint
        }
        SentrySDK.capture(event: event)
        #endif
    }

    // MARK: - Account Identifier Redaction

    /// Matches AT Protocol DIDs, including percent-encoded ones inside URLs.
    private static let accountIdentifierPattern = try? NSRegularExpression(
        pattern: "did(?::|%3A)(?:plc|web|key)(?::|%3A)[A-Za-z0-9._:%-]+",
        options: [.caseInsensitive]
    )

    /// Replaces every DID in `text` so diagnostics can't be tied back to an account.
    static func redactingAccountIdentifiers(_ text: String) -> String {
        guard let pattern = accountIdentifierPattern, text.range(of: "did", options: .caseInsensitive) != nil else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "did:redacted")
    }

    private static func redactingAccountIdentifiers(in value: Any) -> Any {
        if let text = value as? String {
            return redactingAccountIdentifiers(text)
        }
        return value
    }

    private static func redactingAccountIdentifiers(in dictionary: [String: Any]?) -> [String: Any]? {
        guard let dictionary else { return nil }
        return dictionary.mapValues { redactingAccountIdentifiers(in: $0) }
    }

    #if canImport(Sentry)
    private static func redactBreadcrumb(_ crumb: Breadcrumb) -> Breadcrumb {
        if let message = crumb.message {
            crumb.message = redactingAccountIdentifiers(message)
        }
        crumb.data = redactingAccountIdentifiers(in: crumb.data)
        return crumb
    }

    private static func redactEvent(_ event: Event) -> Event {
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: redactingAccountIdentifiers(message))
        }
        event.extra = redactingAccountIdentifiers(in: event.extra)
        event.user = nil
        event.breadcrumbs = event.breadcrumbs?.map { redactBreadcrumb($0) }
        event.exceptions?.forEach { exception in
            exception.value = redactingAccountIdentifiers(exception.value)
        }
        if let request = event.request {
            if let url = request.url {
                request.url = redactingAccountIdentifiers(url)
            }
            if let query = request.queryString {
                request.queryString = redactingAccountIdentifiers(query)
            }
        }
        return event
    }
    #endif

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
        case "warning": return .warning
        case "error": return .error
        default: return .info
        }
    }
    #endif
}
