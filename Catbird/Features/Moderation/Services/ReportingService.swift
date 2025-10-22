import Foundation
import Petrel

/// Service for handling content reporting to AT Protocol moderation services (labelers)
@Observable
final class ReportingService {
    private let client: ATProtoClient
    
    init(client: ATProtoClient) {
        self.client = client
    }
    
    /// Submit a report to a moderation service
    /// - Parameters:
    ///   - subject: The subject to report (post or user)
    ///   - reasonType: The type of violation being reported
    ///   - reason: Optional additional details about the report
    ///   - labelerDid: The DID of the labeler to send the report to
    /// - Returns: Success status of the report submission
    func submitReport(
        subject: ComAtprotoModerationCreateReport.InputSubjectUnion,
        reasonType: ComAtprotoModerationDefs.ReasonType,
        reason: String? = nil,
        labelerDid: String? = nil
    ) async throws -> Bool {
        let input = ComAtprotoModerationCreateReport.Input(
            reasonType: reasonType,
            reason: reason,
            subject: subject
        )
        
        if let labelerDid = labelerDid {
            // Set the proxy header to direct the report to the specified labeler
            await client.setReportLabeler(did: labelerDid)
        }
        
        let (responseCode, _) = try await client.com.atproto.moderation.createReport(input: input)
        await client.clearReportLabeler()
        
        return responseCode >= 200 && responseCode < 300
    }
    
    /// Create a subject for reporting a post
    /// - Parameters:
    ///   - uri: URI of the post to report
    ///   - cid: CID of the post to report
    /// - Returns: A report subject for the post
    func createPostSubject(uri: ATProtocolURI, cid: CID) throws -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        
            let strongRef = ComAtprotoRepoStrongRef(
                uri: uri,
                cid: cid
            )
            return .comAtprotoRepoStrongRef(strongRef)
        
    }
    
    /// Create a subject for reporting a user
    /// - Parameter did: DID of the user to report
    /// - Returns: A report subject for the user
    func createUserSubject(did: DID) -> ComAtprotoModerationCreateReport.InputSubjectUnion {
        let repoRef = ComAtprotoAdminDefs.RepoRef(did: did)
        return .comAtprotoAdminDefsRepoRef(repoRef)
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
