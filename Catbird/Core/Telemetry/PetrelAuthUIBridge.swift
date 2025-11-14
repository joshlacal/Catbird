import Foundation
import Petrel
import OSLog

/// Bridges Petrel auth incidents into Catbird UI state so auto-logout is visible and consistent.
enum PetrelAuthUIBridge {
    private static let logger = Logger(subsystem: "blue.catbird", category: "AuthUIBridge")

    static func enable() {
        PetrelLog.addObserver { event in
            guard event.category == .authentication else { return }

            // Only react to warnings/errors to minimize noise
            let isWarnOrError: Bool = (event.level == .warning || event.level == .error)
            if !isWarnOrError { return }

            // Parse AUTH_LOGOUT did=.. reason=..
            if event.message.hasPrefix("AUTH_LOGOUT ") {
                let (did, reason) = parseLogout(event.message)
                Task { @MainActor in
                    logger.error("UI handling auto logout did=\(did ?? "nil") reason=\(reason ?? "nil")")
                    await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(did: did, reason: reason)
                }
                return
            }

            // Parse structured incidents
            if event.message.hasPrefix("AUTH_INCIDENT ") {
                if let dict = parseIncident(event.message) {
                    let type = dict["type"] as? String
                    if type == "AutoLogoutTriggered" {
                        let did = dict["did"] as? String
                        let reason = dict["reason"] as? String
                        Task { @MainActor in
                            logger.error("UI handling AutoLogoutTriggered did=\(did ?? "nil") reason=\(reason ?? "nil")")
                            await AppStateManager.shared.authentication.handleAutoLogoutFromPetrel(did: did, reason: reason)
                        }
                    }
                }
                return
            }
        }
    }

    private static func parseLogout(_ message: String) -> (String?, String?) {
        // AUTH_LOGOUT did=... reason=...
        var did: String? = nil
        var reason: String? = nil
        let parts = message.split(separator: " ")
        for p in parts {
            if p.hasPrefix("did=") { did = String(p.dropFirst(4)) }
            if p.hasPrefix("reason=") { reason = String(p.dropFirst(7)) }
        }
        return (did, reason)
    }

    private static func parseIncident(_ message: String) -> [String: Any]? {
        let jsonPart = String(message.dropFirst("AUTH_INCIDENT ".count))
        guard let data = jsonPart.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}

