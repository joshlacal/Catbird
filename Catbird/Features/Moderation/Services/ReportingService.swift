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
    /// - Returns: Array of detailed labeler information
    func getSubscribedLabelers() async throws -> [AppBskyLabelerDefs.LabelerViewDetailed] {
        // First get the user's preferences to find which labelers they're subscribed to
        let response = try await client.app.bsky.actor.getPreferences(input: AppBskyActorGetPreferences.Parameters())
        
        // Extract labeler DIDs from preferences
        let labelerPrefs = response.data?.preferences.items.compactMap { item -> [DID]? in
            if case let .labelersPref(pref) = item {
                return pref.labelers.map { $0.did }
            }
            return nil
        }.flatMap { $0 } ?? []
        
        // If there are no labelers in preferences, return an empty array
        if labelerPrefs.isEmpty {
            return []
        }
        
        // Fetch detailed info about these labelers
        let params = AppBskyLabelerGetServices.Parameters(dids: labelerPrefs, detailed: true)
        let labelerResponse = try await client.app.bsky.labeler.getServices(input: params)
        
        // Extract the detailed labeler views
        return labelerResponse.data?.views.compactMap { view -> AppBskyLabelerDefs.LabelerViewDetailed? in
            if case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = view {
                return detailed
            }
            return nil
        } ?? []
    }
    
    /// Get information about the Bluesky moderation service (as a fallback)
    /// - Returns: Detailed information about the Bluesky moderation service
    func getBlueSkyModerationService() async throws -> AppBskyLabelerDefs.LabelerViewDetailed? {
        // The official Bluesky moderation service has a known DID
        let params = AppBskyLabelerGetServices.Parameters(
            dids: [try DID(didString: "did:plc:ar7c4by46qjdydhdevvrndac")],
            detailed: true
        )
        
        let response = try await client.app.bsky.labeler.getServices(input: params)
        
        return response.data?.views.first(where: { view in
            if case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = view,
               detailed.creator.handle.description == "moderation.bsky.app" {
                return true
            }
            return false
        }).flatMap { view in
            if case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = view {
                return detailed
            }
            return nil
        }
    }
}
