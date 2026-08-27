import Foundation
import Petrel

/// Represents actionable external intents received via custom URL scheme or Universal Links
public enum ExternalURLIntent: Equatable, Hashable, Sendable {
    case compose(text: String?)
    case verifyEmail(code: String)
    case groupChatJoin(code: String)

    /// Parses an incoming URL into an ExternalURLIntent if it matches supported intent patterns
    public static func parse(from url: URL) -> ExternalURLIntent? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }

        let scheme = (components.scheme ?? "").lowercased()
        let host = (components.host ?? "").lowercased()
        let path = components.path
        // Finding WS-G-11: Validate scheme and host. Only allow 'bluesky' scheme or HTTPS on trusted Bluesky hosts.
        let isBlueskyScheme = scheme == "bluesky"
        let isAllowedHTTPSHost = (scheme == "https") && (
            host == "bsky.app" ||
            host == "main.bsky.dev" ||
            host == "staging.bsky.app" ||
            host.hasSuffix(".bsky.app") ||
            host.hasSuffix(".bsky.dev")
        )
        guard isBlueskyScheme || isAllowedHTTPSHost else {
            return nil
        }

        // Check for group chat invite code: /chat/{7-10 alphanumeric} or /messages/join/{7-10 alphanumeric}
        // Can arrive as bluesky://chat/{code}, https://bsky.app/chat/{code}, bluesky://messages/join/{code}, etc.
        let fullPath: String
        if scheme == "bluesky" {
            // bluesky://chat/ABCDEFG -> host = "chat", path = "/ABCDEFG"
            // or bluesky://intent/compose -> host = "intent", path = "/compose"
            if !host.isEmpty && !path.isEmpty {
                fullPath = "/\(host)\(path)"
            } else if !host.isEmpty {
                fullPath = "/\(host)"
            } else {
                fullPath = path
            }
        } else {
            fullPath = path
        }

        // Group chat invite matching
        let trimmedPath = fullPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = trimmedPath.split(separator: "/").map(String.init)

        // Finding WS-G-12: Accept only /chat/{code} in two-segment branch, and /messages/join/{code} in three-segment branch.
        // Do not match /messages/{code} in two-segment branch as that hijacks real routes like /messages/settings or /messages/inbox.
        if segments.count == 2 && segments[0] == "chat" {
            let code = segments[1]
            if isValidChatInviteCode(code) {
                return .groupChatJoin(code: code)
            }
        } else if segments.count == 3 && segments[0] == "messages" && segments[1] == "join" {
            let code = segments[2]
            if isValidChatInviteCode(code) {
                return .groupChatJoin(code: code)
            }
        }
        // Intent matching: /intent/{type}
        if segments.count >= 2 && segments[0] == "intent" {
            let intentType = segments[1].lowercased()
            let queryItems = components.queryItems ?? []

            switch intentType {
            case "compose":
                // Prefilled text parameter (decode percent-encoding)
                let text = queryItems.first(where: { $0.name == "text" })?.value
                // Remote image / video parameters are rejected per spec
                return .compose(text: text)

            case "verify-email":
                if let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                    return .verifyEmail(code: code)
                }
                return nil

            default:
                return nil
            }
        }

        return nil
    }

    /// Validates 7-10 alphanumeric character group chat invite code
    public static func isValidChatInviteCode(_ code: String) -> Bool {
        guard code.count >= 7 && code.count <= 10 else { return false }
        let alphanumeric = CharacterSet.alphanumerics
        return code.unicodeScalars.allSatisfy { alphanumeric.contains($0) }
    }
}
