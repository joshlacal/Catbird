import Foundation

#if canImport(Sentry)
import Sentry
#endif

enum SentryService {
    static func start() {
        #if canImport(Sentry)
        let configuration = telemetryConfiguration()
        guard configuration.backend == .glitchTip, let dsn = configuration.dsn else { return }
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        SentrySDK.start { options in
            configureOptions(options, dsn: dsn, version: version, build: build)
        }
        #endif
    }

    #if canImport(Sentry)
    /// Configure locally so privacy behavior can be verified without starting SDK transport.
    static func configureOptions(_ options: Options, dsn: String, version: String, build: String) {
        options.dsn = dsn
        options.debug = false
        #if DEBUG
        options.environment = "debug"
        #elseif BETA
        options.environment = "beta"
        #else
        options.environment = "production"
        #endif
        options.releaseName = "Catbird@\(version)+\(build)"
        options.dist = build
        options.sendDefaultPii = false
        options.enableCrashHandler = true
        options.enableAppHangTracking = true

        // GlitchTip receives minimized failure reports, without session/performance envelopes.
        options.tracesSampleRate = 0
        options.profilesSampleRate = 0
        options.enableAutoPerformanceTracing = false
        options.enablePerformanceV2 = false
        options.enablePersistingTracesWhenCrashing = false
        options.enableAppLaunchProfiling = false
        options.enableAutoSessionTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableNetworkTracking = false
        options.enableGraphQLOperationTracking = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableCoreDataTracing = false
        options.enableSwizzling = false
        options.tracePropagationTargets = []
        options.maxBreadcrumbs = 0
        options.beforeBreadcrumb = { _ in nil }
        options.beforeSendSpan = { _ in nil }
        options.sendClientReports = false
        options.enableMetricKit = false
        options.enableMetricKitRawPayload = false
        options.enableSpotlight = false
        #if os(iOS) || os(tvOS)
        options.enableUIViewControllerTracing = false
        options.enableUserInteractionTracing = false
        options.enablePreWarmedAppStartTracing = false
        options.attachScreenshot = false
        options.attachViewHierarchy = false
        options.reportAccessibilityIdentifier = false
        options.sessionReplay.sessionSampleRate = 0
        options.sessionReplay.onErrorSampleRate = 0
        #endif

        options.beforeSend = { event in
            guard event.type != "transaction", let filtered = filterEvent(event) else { return nil }
            return GlitchTipEventSanitizer.sanitize(redactEvent(filtered))
        }
    }
    #endif

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
        // The SDK shares breadcrumb objects between the scope and captured events.
        // Sanitize a new object so concurrent captures never mutate those shared objects.
        let redacted = Breadcrumb(level: crumb.level, category: crumb.category)
        redacted.timestamp = crumb.timestamp
        redacted.type = crumb.type
        redacted.origin = crumb.origin
        if let message = crumb.message {
            redacted.message = redactingAccountIdentifiers(message)
        }
        redacted.data = redactingAccountIdentifiers(in: crumb.data)
        return redacted
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

    private static func telemetryConfiguration() -> TelemetryConfiguration {
        TelemetryConfiguration.resolve(
            environment: ProcessInfo.processInfo.environment,
            info: Bundle.main.infoDictionary ?? [:]
        )
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
