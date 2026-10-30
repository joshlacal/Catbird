import Foundation
import OSLog
import Petrel

/// Errors that can occur during label appeal submission
enum LabelAppealError: LocalizedError, Equatable {
    case selfLabelNotAppealable
    case alreadyAppealed
    case subjectNotOwned
    case inactiveLabel
    case accountChanged
    case invalidDetails
    case invalidLabelSubject(String)
    
    var errorDescription: String? {
        switch self {
        case .selfLabelNotAppealable:
            return "Self-applied labels cannot be appealed."
        case .subjectNotOwned:
            return "You can only appeal labels on your own account or posts."
        case .inactiveLabel:
            return "This label is no longer active."
        case .accountChanged:
            return "Your account changed. Reopen the label to appeal it."
        case .invalidDetails:
            return "Enter an appeal reason of 1 to 300 characters."
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
        let targetDid = ReportingService.labelerServiceDID(labelerDid ?? ReportingService.officialBlueskyDID)
        await client.setServiceDID(targetDid, for: "com.atproto.moderation.createReport")
        return try await operation(client)
    }
}

/// Service for handling content reporting to AT Protocol moderation services (labelers)
@Observable
final class ReportingService {
    public static let officialBlueskyDID = "did:plc:ar7c4by46qjdydhdevvrndac"
    private static let logger = Logger(subsystem: "blue.catbird", category: "ReportingService")
    
    typealias ReportTransport = @Sendable (ComAtprotoModerationCreateReport.Input, String) async throws -> Bool
    private let client: ATProtoClient
    private let reportTransport: ReportTransport?
    private let activeAccountDID: @Sendable () async -> String?

    init(
        client: ATProtoClient,
        reportTransport: ReportTransport? = nil,
        activeAccountDID: (@Sendable () async -> String?)? = nil
    ) {
        self.client = client
        self.reportTransport = reportTransport
        self.activeAccountDID = activeAccountDID ?? { try? await client.getDid() }
    }

    static func labelerServiceDID(_ issuerDID: String) -> String {
        issuerDID.hasSuffix("#atproto_labeler") ? issuerDID : issuerDID + "#atproto_labeler"
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
        modTool: ComAtprotoModerationCreateReport.ModTool? = nil,
        expectedAccountDID: String? = nil
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
        
        let transport = reportTransport
        let accountDID = activeAccountDID
        let destination = Self.labelerServiceDID(labelerDid ?? Self.officialBlueskyDID)
        let continuity = expectedAccountDID != nil && transport == nil ? await client.authContinuitySnapshot() : nil
        if let expectedAccountDID, let continuity, continuity.did != expectedAccountDID {
            throw LabelAppealError.accountChanged
        }
        return try await ReportDispatcher.shared.execute(client: client, labelerDid: labelerDid) { client in
            try Task.checkCancellation()
            if let expectedAccountDID, await accountDID() != expectedAccountDID {
                throw LabelAppealError.accountChanged
            }
            if let transport { return try await transport(input, destination) }
            if let continuity {
                let result = try await client.performGeneratedRequestWithExactAuthContinuity(matching: continuity) {
                    try await Self.performReport(client: client, input: input, destination: destination)
                }
                switch result {
                case .performed(let success): return success
                case .continuityChanged: throw LabelAppealError.accountChanged
                }
            }
            return try await Self.performReport(client: client, input: input, destination: destination)
        }
    }
    
    private static func performReport(
        client: ATProtoClient, input: ComAtprotoModerationCreateReport.Input, destination: String
    ) async throws -> Bool {
            // This lexicon declares no error variants. Keep its generated input, but
            // preserve the XRPC body so AlreadyAppealed remains distinguishable.
            let request = try await client.networkService.createURLRequest(
                endpoint: "com.atproto.moderation.createReport",
                method: "POST",
                headers: ["Content-Type": "application/json", "Accept": "application/json"],
                body: try JSONEncoder().encode(input),
                queryItems: nil
            )
            try Task.checkCancellation()
            let (data, response) = try await client.networkService.performRequestReturningHTTPErrorResponses(
                request, skipTokenRefresh: false, additionalHeaders: ["atproto-proxy": destination]
            )
            if (200...299).contains(response.statusCode) { return true }
            if let error = ATProtoErrorParser.parseGeneric(data: data, statusCode: response.statusCode) {
                throw error
            }
            return false
    }

    /// Create a subject for reporting or appealing a label
    func createLabelSubject(for label: ComAtprotoLabelDefs.Label) throws -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        let value = label.uri.uriString()
        if let cid = label.cid {
            guard let uri = try? ATProtocolURI(uriString: value),
                  value.hasPrefix("at://"), uri.authority.hasPrefix("did:"),
                  !uri.isSpace, uri.collection != nil, uri.recordKey != nil else {
                throw LabelAppealError.invalidLabelSubject("Expected a record URI and CID")
            }
            return createRecordSubject(uri: uri, cid: cid)
        }
        guard value.hasPrefix("did:"), let did = try? DID(didString: value) else {
            throw LabelAppealError.invalidLabelSubject("Expected an account DID")
        }
        return createUserSubject(did: did)
    }

    static func subjectOwnerDID(_ label: ComAtprotoLabelDefs.Label) -> String? {
        let value = label.uri.uriString()
        if value.hasPrefix("did:"), label.cid == nil, (try? DID(didString: value)) != nil {
            return value
        }
        if value.hasPrefix("at://"),
           let uri = try? ATProtocolURI(uriString: value),
           uri.authority.hasPrefix("did:"), !uri.isSpace,
           uri.collection != nil, uri.recordKey != nil {
            return uri.authority
        }
        return nil
    }

    static func canAppeal(_ label: ComAtprotoLabelDefs.Label, viewerDID: String) -> Bool {
        isLabelActive(label) && subjectOwnerDID(label) == viewerDID
            && (label.cid != nil || label.uri.uriString().hasPrefix("did:"))
            && !isSelfLabel(label, viewerDID: viewerDID)
    }

    /// Submit an appeal for a label applied by a third-party labeler
    func submitAppeal(
        label: ComAtprotoLabelDefs.Label,
        viewerDID: String? = nil,
        details: String? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let viewerDID, Self.subjectOwnerDID(label) == viewerDID else {
            throw LabelAppealError.subjectNotOwned
        }
        guard !Self.isSelfLabel(label, viewerDID: viewerDID) else {
            throw LabelAppealError.selfLabelNotAppealable
        }
        guard Self.isLabelActive(label) else { throw LabelAppealError.inactiveLabel }
        let reason = details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty, reason.count <= 300 else { throw LabelAppealError.invalidDetails }

        let subject = try createLabelSubject(for: label)
        let labelerDid = label.src.didString()
        
        do {
            return try await submitReport(
                subject: subject,
                reasonType: .toolsozonereportdefsreasonappeal,
                reason: reason,
                labelerDid: labelerDid,
                expectedAccountDID: viewerDID
            )
        } catch {
            if let xrpcError = error as? ATProtoXRPCError, xrpcError.error == "AlreadyAppealed" {
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
                labelerDid: Self.officialBlueskyDID,
                expectedAccountDID: userDID
            )
        } catch {
            if let xrpcError = error as? ATProtoXRPCError, xrpcError.error == "AlreadyAppealed" {
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
        if let exp = label.exp?.date, exp <= date {
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
    /// - Returns: Detailed labeler information with the Bluesky moderation service first. A lookup
    ///   that fails is logged and skipped, so one unreachable service never hides the others; the
    ///   result is empty only when nothing could be loaded.
    func getSubscribedLabelers() async throws -> [AppBskyLabelerDefs.LabelerViewDetailed] {
        var labelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
        
        // Always include the Bluesky moderation service first
        do {
            labelers.append(try await getBlueskyModerationService())
        } catch {
            Self.logger.error("Failed to load the Bluesky moderation service: \(error.localizedDescription, privacy: .public)")
        }
        
        do {
            // Find which labelers the user is subscribed to
            let response = try await client.app.bsky.actor.getPreferences(input: AppBskyActorGetPreferences.Parameters())
            
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
                let subscribedLabelers = labelerResponse.data?.views.compactMap { view -> AppBskyLabelerDefs.LabelerViewDetailed? in
                    if case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = view {
                        if detailed.creator.did.didString() == Self.officialBlueskyDID {
                            return nil
                        }
                        return detailed
                    }
                    return nil
                } ?? []
                
                labelers.append(contentsOf: subscribedLabelers)
            }
        } catch {
            Self.logger.error("Failed to load subscribed moderation services: \(error.localizedDescription, privacy: .public)")
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
