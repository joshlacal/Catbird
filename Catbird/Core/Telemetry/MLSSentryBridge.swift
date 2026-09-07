//
//  MLSSentryBridge.swift
//  Catbird
//

import CatbirdMLSCore
import Foundation

#if canImport(Sentry)
import Sentry
#endif

public enum MLSSentryBridge {
    public static func enable() {
        MLSDiagnostics.reporter = { record in
            report(record)
        }
    }

    public static func report(_ record: MLSDiagnosticRecord) {
        // 1. Add breadcrumb for the decision/status trail in any subsequent Sentry report
        let breadcrumbMessage = formatBreadcrumb(record)
        let breadcrumbLevel: String
        switch record.event {
        case .sendFailed, .conversationLoadFailed, .decryptRefused:
            breadcrumbLevel = "error"
        case .streamPaused, .rejoinWaiting:
            breadcrumbLevel = "warning"
        case .sendRecovered, .streamResumed:
            breadcrumbLevel = "info"
        }
        SentryService.addBreadcrumb(
            level: breadcrumbLevel,
            category: "MLS.Chat",
            message: breadcrumbMessage
        )

        // 2. Sentry issue event for failures and waiting/retrying states
        guard shouldCaptureEvent(for: record) else { return }

        let level: String
        switch record.event {
        case .sendFailed, .conversationLoadFailed, .decryptRefused:
            level = "error"
        case .streamPaused, .rejoinWaiting:
            level = "warning"
        case .sendRecovered, .streamResumed:
            level = "info"
        }

        let issueTitle = "MLS: [\(record.event.rawValue)] \(record.code)"
        var tags: [String: String] = [
            "mls.event": record.event.rawValue,
            "mls.code": record.code
        ]
        if let convo = record.conversationIDPrefix {
            tags["mls.convo"] = convo
        }

        var extras: [String: Any] = [:]
        if let convo = record.conversationIDPrefix { extras["conversationIDPrefix"] = convo }
        if let epoch = record.epoch { extras["epoch"] = epoch }
        if let gen = record.generation { extras["generation"] = gen }
        if let sv = record.stateVersion { extras["stateVersion"] = sv }
        if let retry = record.retryAfter { extras["retryAfter"] = retry }
        if let attempt = record.attempt { extras["attempt"] = attempt }
        for (k, v) in record.detail {
            extras[k] = v
        }

        // Stable fingerprint: event + code ensures identical failures collapse into one Sentry issue
        let fingerprint = [record.event.rawValue, record.code]

        SentryService.captureEvent(
            message: issueTitle,
            level: level,
            category: "MLS.Chat",
            tags: tags,
            extras: extras,
            fingerprint: fingerprint
        )
    }

    private static func shouldCaptureEvent(for record: MLSDiagnosticRecord) -> Bool {
        switch record.event {
        case .sendFailed, .conversationLoadFailed, .decryptRefused, .streamPaused, .rejoinWaiting:
            return true
        case .sendRecovered, .streamResumed:
            return false
        }
    }

    private static func formatBreadcrumb(_ record: MLSDiagnosticRecord) -> String {
        var parts: [String] = ["[\(record.event.rawValue)]", "code=\(record.code)"]
        if let convo = record.conversationIDPrefix { parts.append("convo=\(convo)") }
        if let epoch = record.epoch { parts.append("epoch=\(epoch)") }
        if let gen = record.generation { parts.append("gen=\(gen)") }
        if let sv = record.stateVersion { parts.append("stateVersion=\(sv)") }
        if let attempt = record.attempt { parts.append("attempt=\(attempt)") }
        if let retry = record.retryAfter { parts.append(String(format: "retryAfter=%.1fs", retry)) }
        return parts.joined(separator: " ")
    }
}
