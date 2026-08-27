import Foundation
import Petrel

/// Errors that can occur during label appeal submission
enum LabelAppealError: LocalizedError, Equatable {
    case selfLabelNotAppealable
    case alreadyAppealed
    case invalidLabelSubject(String)
    
    var errorDescription: String? {
        switch self {
        case .selfLabelNotAppealable:
            return "Self-applied labels cannot be appealed."
        case .alreadyAppealed:
            return "This label has already been appealed and is currently under review."
        case .invalidLabelSubject(let msg):
            return "Invalid label subject: \(msg)"
        }
    }
}
/// Actor that serializes report requests requiring labeler proxy headers
actor ReportDispatcher {
    static let shared = ReportDispatcher()
    
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    
    private var waiters: [Waiter] = []
    private var isExecuting = false
    
    private func acquire(id: UUID) async throws {
        try Task.checkCancellation()
        if !isExecuting {
            isExecuting = true
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: id)
            }
        }
    }
    
    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
    
    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: ())
        } else {
            isExecuting = false
        }
    }
    
    func execute<T: Sendable>(
        client: ATProtoClient,
        labelerDid: String?,
        operation: @Sendable (ATProtoClient) async throws -> T
    ) async throws -> T {
        let id = UUID()
        try await acquire(id: id)
        defer { release() }
        try Task.checkCancellation()
        let targetDid = labelerDid ?? ReportingService.officialBlueskyDID
        await client.setServiceDID(targetDid, for: "com.atproto.moderation.createReport")
        return try await operation(client)
    }
}

/// Service for handling content reporting to AT Protocol moderation services (labelers)
@Observable
final class ReportingService {
    public static let officialBlueskyDID = "did:plc:ar7c4by46qjdydhdevvrndac"
    
    private let client: ATProtoClient
    
    init(client: ATProtoClient) {
        self.client = client
    }
    
    /// Submit a report to a moderation service
    /// - Parameters:
    ///   - subject: The subject to report (post, user, list, or feed generator)
    ///   - reasonType: The type of violation being reported
    ///   - reason: Optional additional details about the report
    ///   - labelerDid: The DID of the labeler to send the report to
    ///   - videoTimestampSeconds: Optional integer playback position in seconds (official labeler only)
    ///   - modTool: Optional direct ModTool payload
    /// - Returns: Success status of the report submission
    func submitReport(
        subject: ComAtprotoModerationCreateReport.InputSubjectUnion,
        reasonType: ComAtprotoModerationDefs.ReasonType,
        reason: String? = nil,
        labelerDid: String? = nil,
        videoTimestampSeconds: Int? = nil,
        modTool: ComAtprotoModerationCreateReport.ModTool? = nil
    ) async throws -> Bool {
        let isOfficial = (labelerDid == nil || labelerDid == Self.officialBlueskyDID)
        
        var finalModTool: ComAtprotoModerationCreateReport.ModTool? = modTool
        if finalModTool == nil, let seconds = videoTimestampSeconds, seconds >= 1, isOfficial {
            finalModTool = ComAtprotoModerationCreateReport.ModTool(
                name: "video",
                meta: .object(["videoTimestampSeconds": .number(seconds)])
            )
        }
        
        let input = ComAtprotoModerationCreateReport.Input(
            reasonType: reasonType,
            reason: reason,
            subject: subject,
            modTool: finalModTool
        )
        
        return try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerDid) { client in
            let (responseCode, _) = try await client.com.atproto.moderation.createReport(input: input)
            return responseCode >= 200 && responseCode < 300
        }
    }
    
    /// Create a subject for reporting or appealing a label
    func createLabelSubject(for label: ComAtprotoLabelDefs.Label) throws -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        if let cid = label.cid {
            let uri: ATProtocolURI
            let uriString = label.uri.uriString()
            if uriString.hasPrefix("at://"), let direct = try? ATProtocolURI(uriString: uriString) {
                uri = direct
            } else if !label.uri.authority.isEmpty && label.uri.authority != "invalid.invalid" {
                let path = label.uri.path ?? ""
                let formattedPath = path.hasPrefix("/") ? path : (path.isEmpty ? "" : "/\(path)")
                uri = try ATProtocolURI(uriString: "at://\(label.uri.authority)\(formattedPath)")
            } else {
                uri = try ATProtocolURI(uriString: uriString)
            }
            return createRecordSubject(uri: uri, cid: cid)
        } else {
            let uriString = label.uri.uriString()
            let didString: String
            if label.uri.isDID {
                didString = uriString
            } else if uriString.hasPrefix("did:") {
                didString = uriString
            } else if uriString.hasPrefix("at://") {
                let withoutPrefix = String(uriString.dropFirst(5))
                didString = withoutPrefix.components(separatedBy: "/").first ?? withoutPrefix
            } else if !label.uri.authority.isEmpty && label.uri.authority != "invalid.invalid" && label.uri.authority.hasPrefix("did:") {
                didString = label.uri.authority
            } else {
                didString = uriString
            }
            let did = try DID(didString: didString)
            return createUserSubject(did: did)
        }
    }
    
    /// Submit an appeal for a label applied by a third-party labeler
    func submitAppeal(
        label: ComAtprotoLabelDefs.Label,
        viewerDID: String? = nil,
        details: String? = nil
    ) async throws -> Bool {
        if let viewerDID = viewerDID, label.src.didString() == viewerDID {
            throw LabelAppealError.selfLabelNotAppealable
        }
        
        let subject = try createLabelSubject(for: label)
        let labelerDid = label.src.didString()
        
        do {
            return try await submitReport(
                subject: subject,
                reasonType: .toolsozonereportdefsreasonappeal,
                reason: details,
                labelerDid: labelerDid
            )
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("already") || msg.contains("duplicate") || msg.contains("alreadyappealed") {
                throw LabelAppealError.alreadyAppealed
            }
            throw error
        }
    }
    /// Submit an appeal for a taken-down account to official Bluesky moderation service
    func submitAccountAppeal(
        userDID: String,
        details: String? = nil
    ) async throws -> Bool {
        let did = try DID(didString: userDID)
        let subject = createUserSubject(did: did)
        do {
            return try await submitReport(
                subject: subject,
                reasonType: .toolsozonereportdefsreasonappeal,
                reason: details,
                labelerDid: Self.officialBlueskyDID
            )
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("already") || msg.contains("duplicate") || msg.contains("alreadyappealed") {
                throw LabelAppealError.alreadyAppealed
            }
            throw error
        }
    }
    
    /// Checks if a label is active (not negated and not expired)
    static func isLabelActive(_ label: ComAtprotoLabelDefs.Label, at date: Date = Date()) -> Bool {
        if label.neg == true {
            return false
        }
        if let exp = label.exp?.date, exp < date {
            return false
        }
        return true
    }
    
    /// Checks if a label is self-applied by the viewer
    static func isSelfLabel(_ label: ComAtprotoLabelDefs.Label, viewerDID: String) -> Bool {
        return label.src.didString() == viewerDID
    }
    
    /// Create a subject for reporting a post
    func createPostSubject(uri: ATProtocolURI, cid: CID) -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        let strongRef = ComAtprotoRepoStrongRef(
            uri: uri,
            cid: cid
        )
        return .comAtprotoRepoStrongRef(strongRef)
    }
    
    /// Create a subject for reporting a user
    func createUserSubject(did: DID) -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        let repoRef = ComAtprotoAdminDefs.RepoRef(did: did)
        return .comAtprotoAdminDefsRepoRef(repoRef)
    }
    
    /// Create a subject for reporting a feed generator
    func createFeedSubject(uri: ATProtocolURI, cid: CID) -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        let strongRef = ComAtprotoRepoStrongRef(
            uri: uri,
            cid: cid
        )
        return .comAtprotoRepoStrongRef(strongRef)
    }
    
    /// Create a subject for reporting a list
    func createListSubject(uri: ATProtocolURI, cid: CID) -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        let strongRef = ComAtprotoRepoStrongRef(
            uri: uri,
            cid: cid
        )
        return .comAtprotoRepoStrongRef(strongRef)
    }
    
    /// Create a subject for reporting any strongRef record
    func createRecordSubject(uri: ATProtocolURI, cid: CID) -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        let strongRef = ComAtprotoRepoStrongRef(
            uri: uri,
            cid: cid
        )
        return .comAtprotoRepoStrongRef(strongRef)
    }
    
    /// Checks whether a reason must be handled by the official Bluesky moderation service
    static func isBlueskyOnlyReason(_ reason: ComAtprotoModerationDefs.ReasonType) -> Bool {
        switch reason {
        case .toolsozonereportdefsreasonchildsafetycsam,
             .toolsozonereportdefsreasonchildsafetygroom,
             .toolsozonereportdefsreasonchildsafetyprivacy,
             .toolsozonereportdefsreasonchildsafetyharassment,
             .toolsozonereportdefsreasonchildsafetyother,
             .toolsozonereportdefsreasonviolenceextremistcontent:
            return true
        default:
            return false
        }
    }
    
    /// Checks whether a reason is Non-Consensual Intimate Imagery (NCII)
    static func isNCIIReason(_ reason: ComAtprotoModerationDefs.ReasonType) -> Bool {
        return reason == .toolsozonereportdefsreasonsexualncii
    }
    /// Get available labelers the user is subscribed to
    /// - Returns: Array of detailed labeler information, always including Bluesky moderation service first
    func getSubscribedLabelers() async throws -> [AppBskyLabelerDefs.LabelerViewDetailed] {
        var labelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
        
        // ALWAYS include Bluesky moderation service first - this is guaranteed to be available
        let blueskyMod = try await getBlueskyModerationService()
        labelers.append(blueskyMod)
        
        // Then get the user's preferences to find which labelers they're subscribed to
        let response = try await client.app.bsky.actor.getPreferences(input: AppBskyActorGetPreferences.Parameters())
        
        // Extract labeler DIDs from preferences
        let labelerPrefs = response.data?.preferences.items.compactMap { item -> [DID]? in
            if case let .labelersPref(pref) = item {
                return pref.labelers.map { $0.did }
            }
            return nil
        }.flatMap { $0 } ?? []
        
        // If there are subscribed labelers, fetch their details
        if !labelerPrefs.isEmpty {
            let params = AppBskyLabelerGetServices.Parameters(dids: labelerPrefs, detailed: true)
            let labelerResponse = try await client.app.bsky.labeler.getServices(input: params)
            
            // Extract the detailed labeler views, excluding Bluesky moderation (already added first)
            let blueskyDid = try DID(didString: "did:plc:ar7c4by46qjdydhdevvrndac")
            let subscribedLabelers = labelerResponse.data?.views.compactMap { view -> AppBskyLabelerDefs.LabelerViewDetailed? in
                if case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = view {
                    // Skip Bluesky moderation service (already at top of list)
                    if detailed.creator.did == blueskyDid {
                        return nil
                    }
                    return detailed
                }
                return nil
            } ?? []
            
            labelers.append(contentsOf: subscribedLabelers)
        }
        
        return labelers
    }
    
    /// Get information about the official Bluesky moderation service
    /// - Returns: Detailed information about the Bluesky moderation service
    /// - Throws: Error if the Bluesky moderation service cannot be retrieved
    func getBlueskyModerationService() async throws -> AppBskyLabelerDefs.LabelerViewDetailed {
        // The official Bluesky moderation service has a known DID
        let blueskyDid = try DID(didString: "did:plc:ar7c4by46qjdydhdevvrndac")
        let params = AppBskyLabelerGetServices.Parameters(
            dids: [blueskyDid],
            detailed: true
        )
        
        let response = try await client.app.bsky.labeler.getServices(input: params)
        
        // Find the Bluesky moderation service in the response
        guard let blueskyService = response.data?.views.first(where: { view in
            if case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = view {
                return detailed.creator.did == blueskyDid
            }
            return false
        }) else {
            throw NSError(
                domain: "ReportingService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve Bluesky moderation service"]
            )
        }
        
        // Extract the detailed view
        guard case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = blueskyService else {
            throw NSError(
                domain: "ReportingService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format for Bluesky moderation service"]
            )
        }
        
        return detailed
    }
}
