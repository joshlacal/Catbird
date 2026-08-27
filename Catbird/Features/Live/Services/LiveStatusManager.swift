import Foundation
import Observation
import OSLog
import Petrel

enum LiveStatusError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidStreamURL(String)
    case missingStreamURL
    case concurrentModification
    case unauthorized
    case requestFailed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated"
        case .invalidStreamURL(let msg):
            return msg
        case .missingStreamURL:
            return "Missing stream URL"
        case .concurrentModification:
            return "Status was modified from another device. Please review and try again."
        case .unauthorized:
            return "Live status updates are not authorized for this account."
        case .requestFailed(let code, let message):
            if let message = message, !message.isEmpty {
                return "Request failed (\(code)): \(message)"
            }
            return "Request failed with HTTP \(code)"
        }
    }
}

@Observable
@MainActor
final class LiveStatusManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "LiveStatusManager")

    static let allowedApexDomains: Set<String> = [
        "twitch.tv",
        "stream.place",
        "bluecast.app",
        "youtube.com",
        "substack.com",
        "beehiiv.com",
        "skylight.social",
        "nba.com",
        "nba.smart.link",
        "espn.com"
    ]

    private(set) var currentStatus: AppBskyActorStatus?
    private(set) var currentCID: CID?
    private(set) var isPublishing: Bool = false
    var errorMessage: String?

    var hasActiveLiveStatus: Bool {
        guard let status = currentStatus, status.status == "app.bsky.actor.status#live" else {
            return false
        }
        guard let durationMinutes = status.durationMinutes else { return true }
        let createdAt = status.createdAt.date
        let expiresAt = createdAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return Date() < expiresAt
    }

    private weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    func configure(with appState: AppState) {
        self.appState = appState
    }

    // MARK: - Validation

    static func sanitizeLiveHost(_ hostname: String) -> String {
        let lower = hostname.lowercased()
        if lower == "nba.smart.link" {
            return "nba.smart.link"
        }

        let parts = lower.split(separator: ".")
        if parts.count >= 2 {
            // Check for two-part TLDs or regular domain.tld
            let lastTwo = parts.suffix(2).joined(separator: ".")
            if allowedApexDomains.contains(lastTwo) {
                return lastTwo
            }
            if parts.count >= 3 {
                let lastThree = parts.suffix(3).joined(separator: ".")
                if allowedApexDomains.contains(lastThree) {
                    return lastThree
                }
            }
            return lastTwo
        }
        return lower
    }

    static func validateStreamURL(_ urlString: String) -> (isValid: Bool, error: String?, apexDomain: String?) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return (false, "Please enter a valid URL", nil)
        }

        guard scheme == "https" else {
            return (false, "Only HTTPS stream links are allowed", nil)
        }

        let apex = sanitizeLiveHost(host)
        guard allowedApexDomains.contains(apex) else {
            return (false, "Host '\(host)' is not in the allowed live streaming hosts", apex)
        }

        return (true, nil, apex)
    }

    static func displayDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0 && remainingMinutes > 0 {
            return "\(hours)h \(remainingMinutes)m"
        } else if hours > 0 {
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        } else {
            return "\(minutes) minutes"
        }
    }

    private func isInvalidSwapError(_ error: Error) -> Bool {
        if let putError = error as? ATProtoError<ComAtprotoRepoPutRecord.Error>, putError.error == .invalidSwap {
            return true
        }
        if let deleteError = error as? ATProtoError<ComAtprotoRepoDeleteRecord.Error>, deleteError.error == .invalidSwap {
            return true
        }
        if let xrpcError = error as? ATProtoXRPCError, xrpcError.error == "InvalidSwap" {
            return true
        }
        if String(describing: error).contains("InvalidSwap") {
            return true
        }
        return (error as NSError).userInfo["error"] as? String == "InvalidSwap"
    }

    /// Builds the external embed for a live stream URL. When the URL card
    /// service is unavailable the embed falls back to the apex domain title.
    private func makeLiveEmbed(from card: URLCardResponse?, urlString: String, apexDomain: String?) -> AppBskyActorStatus.AppBskyActorStatusEmbedUnion {
        let title: String
        let description: String
        if let card {
            title = card.title.isEmpty ? (apexDomain ?? "Live Stream") : card.title
            description = card.description
        } else {
            title = apexDomain ?? "Live Stream"
            description = ""
        }
        return .appBskyEmbedExternal(AppBskyEmbedExternal(external: AppBskyEmbedExternal.External(
            uri: URI(uriString: urlString),
            title: title,
            description: description,
            thumb: nil,
            associatedRefs: nil
        )))
    }

    private func validateStatusCode(_ responseCode: Int) throws {
        guard (200 ... 299).contains(responseCode) else {
            if responseCode == 401 || responseCode == 403 {
                throw LiveStatusError.unauthorized
            }
            throw LiveStatusError.requestFailed(statusCode: responseCode, message: nil)
        }
    }

    private func handleMutationFailure(_ error: Error, warning: String) async throws -> Never {
        if isInvalidSwapError(error) {
            logger.warning("\(warning)")
            await fetchCurrentStatus()
            throw LiveStatusError.concurrentModification
        }
        throw error
    }

    // MARK: - API Operations

    @discardableResult
    func fetchCurrentStatus() async -> AppBskyActorStatus? {
        guard let appState = self.appState,
              let client = appState.atProtoClient else {
            return nil
        }
        let did = appState.userDID

        do {
            let input = ComAtprotoRepoGetRecord.Parameters(
                repo: try ATIdentifier(string: did),
                collection: try NSID(nsidString: "app.bsky.actor.status"),
                rkey: try RecordKey(keyString: "self")
            )
            let (code, data) = try await client.com.atproto.repo.getRecord(input: input)
            if (200 ... 299).contains(code), let data = data {
                self.currentCID = data.cid
                if let status = data.value.decoded(AppBskyActorStatus.self) {
                    self.currentStatus = status
                    return status
                }
            } else {
                self.currentStatus = nil
                self.currentCID = nil
            }
        } catch {
            logger.debug("No active status or error fetching status: \(error.localizedDescription)")
            self.currentStatus = nil
            self.currentCID = nil
        }
        return nil
    }

    func publishStatus(streamURL: URL, durationMinutes: Int) async throws {
        guard let appState = self.appState,
              let client = appState.atProtoClient else {
            throw LiveStatusError.notAuthenticated
        }
        let did = appState.userDID

        let validation = Self.validateStreamURL(streamURL.absoluteString)
        guard validation.isValid else {
            throw LiveStatusError.invalidStreamURL(validation.error ?? "Invalid stream URL")
        }

        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }

        // Fetch URL card preview metadata
        let card = try? await URLCardService.fetchURLCard(for: streamURL.absoluteString)
        let embedUnion = makeLiveEmbed(from: card, urlString: streamURL.absoluteString, apexDomain: validation.apexDomain)

        let createdAt = try ATProtocolDate(date: Date())
        let statusRecord = AppBskyActorStatus(
            status: "app.bsky.actor.status#live",
            embed: embedUnion,
            durationMinutes: durationMinutes,
            createdAt: createdAt
        )

        let input = ComAtprotoRepoPutRecord.Input(
            repo: try ATIdentifier(string: did),
            collection: try NSID(nsidString: "app.bsky.actor.status"),
            rkey: try RecordKey(keyString: "self"),
            record: ATProtocolValueContainer.knownType(statusRecord),
            swapRecord: currentCID
        )

        do {
            let (responseCode, output) = try await client.com.atproto.repo.putRecord(input: input)
            try validateStatusCode(responseCode)
            guard let output = output else {
                throw LiveStatusError.requestFailed(statusCode: responseCode, message: nil)
            }
            self.currentCID = output.cid
            self.currentStatus = statusRecord
            logger.info("Successfully published live status: duration=\(durationMinutes)m")

            appState.stateInvalidationBus.notify(.profileUpdated(did: did))
            NotificationCenter.default.post(name: NSNotification.Name("UserProfileUpdated"), object: nil)
        } catch {
            try await handleMutationFailure(error, warning: "PublishStatus failed with InvalidSwap; reloading status...")
        }
    }

    func updateStatus(streamURL: URL?, durationMinutes: Int?) async throws {
        guard let appState = self.appState,
              let client = appState.atProtoClient else {
            throw LiveStatusError.notAuthenticated
        }
        let did = appState.userDID

        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }

        // Fetch latest CID first
        await fetchCurrentStatus()

        let current = self.currentStatus
        let targetDuration = durationMinutes ?? current?.durationMinutes ?? 60
        let targetURL = streamURL?.absoluteString ?? current?.embed.flatMap { embed -> String? in
            if case .appBskyEmbedExternal(let ext) = embed {
                return ext.external.uri.uriString()
            }
            return nil
        }

        guard let finalURLString = targetURL, let finalURL = URL(string: finalURLString) else {
            throw LiveStatusError.missingStreamURL
        }

        let validation = Self.validateStreamURL(finalURL.absoluteString)
        guard validation.isValid else {
            throw LiveStatusError.invalidStreamURL(validation.error ?? "Invalid stream URL")
        }

        var embedUnion = current?.embed
        if streamURL != nil,
           let card = try? await URLCardService.fetchURLCard(for: finalURL.absoluteString) {
            embedUnion = makeLiveEmbed(from: card, urlString: finalURL.absoluteString, apexDomain: validation.apexDomain)
        }

        let createdAt = current?.createdAt ?? ATProtocolDate(date: Date())
        let updatedRecord = AppBskyActorStatus(
            status: "app.bsky.actor.status#live",
            embed: embedUnion,
            durationMinutes: targetDuration,
            createdAt: createdAt
        )

        let input = ComAtprotoRepoPutRecord.Input(
            repo: try ATIdentifier(string: did),
            collection: try NSID(nsidString: "app.bsky.actor.status"),
            rkey: try RecordKey(keyString: "self"),
            record: ATProtocolValueContainer.knownType(updatedRecord),
            swapRecord: currentCID
        )

        do {
            let (responseCode, output) = try await client.com.atproto.repo.putRecord(input: input)
            try validateStatusCode(responseCode)
            guard let output = output else {
                throw LiveStatusError.requestFailed(statusCode: responseCode, message: nil)
            }
            self.currentCID = output.cid
            self.currentStatus = updatedRecord
            logger.info("Successfully updated live status: duration=\(targetDuration)m")

            appState.stateInvalidationBus.notify(.profileUpdated(did: did))
            NotificationCenter.default.post(name: NSNotification.Name("UserProfileUpdated"), object: nil)
        } catch {
            try await handleMutationFailure(error, warning: "PutRecord failed with InvalidSwap; reloading status and asking user to retry")
        }
    }

    func stopLive() async throws {
        guard let appState = self.appState,
              let client = appState.atProtoClient else {
            throw LiveStatusError.notAuthenticated
        }
        let did = appState.userDID

        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }

        let input = ComAtprotoRepoDeleteRecord.Input(
            repo: try ATIdentifier(string: did),
            collection: try NSID(nsidString: "app.bsky.actor.status"),
            rkey: try RecordKey(keyString: "self"),
            swapRecord: currentCID
        )

        do {
            let (responseCode, _) = try await client.com.atproto.repo.deleteRecord(input: input)
            try validateStatusCode(responseCode)
            self.currentStatus = nil
            self.currentCID = nil
            logger.info("Successfully stopped live status and deleted record")

            appState.stateInvalidationBus.notify(.profileUpdated(did: did))
            NotificationCenter.default.post(name: NSNotification.Name("UserProfileUpdated"), object: nil)
        } catch {
            try await handleMutationFailure(error, warning: "DeleteRecord failed with InvalidSwap; reloading status")
        }
    }
}
