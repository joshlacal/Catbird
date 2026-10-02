//
//  StarterPackService.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G56, G57, G73).
//

import Foundation
import Petrel
import OSLog

/// Service for starter pack operations including bulk following, member filtering,
/// starter pack creation/editing, and cloning starter packs into curated lists.
public final class StarterPackService: Sendable {
    public static let shared = StarterPackService()
    
    private let logger = Logger(subsystem: "blue.catbird", category: "StarterPackService")
    
    public init() {}
    
    // MARK: - Eligibility Filtering (G56)
    
    /// Determines whether a profile is eligible to be followed in a bulk-follow operation.
    /// Excludes:
    /// - Current signed-in account
    /// - Already followed accounts
    /// - Muted accounts (individually or by list)
    /// - Blocked / blocking accounts (individually, by list, or blockedBy)
    public func isEligibleToFollow(
        subject: AppBskyActorDefs.ProfileViewBasic,
        currentAccountDID: String
    ) -> Bool {
        isEligibleToFollow(did: subject.did, viewer: subject.viewer, currentAccountDID: currentAccountDID)
    }

    public func isEligibleToFollow(
        subject: AppBskyActorDefs.ProfileView,
        currentAccountDID: String
    ) -> Bool {
        isEligibleToFollow(did: subject.did, viewer: subject.viewer, currentAccountDID: currentAccountDID)
    }

    public func isEligibleToFollow(
        did: DID,
        viewer: AppBskyActorDefs.ViewerState?,
        currentAccountDID: String
    ) -> Bool {
        // Exclude signed-in user
        if did.didString() == currentAccountDID {
            return false
        }
        
        guard let viewer = viewer else {
            // No viewer state available — default to eligible
            return true
        }
        
        // Exclude already followed
        if viewer.following != nil {
            return false
        }
        
        // Exclude muted (individually or by list)
        if viewer.muted == true || viewer.mutedByList != nil {
            return false
        }
        
        // Exclude blocked / blocking
        if viewer.blocking != nil || viewer.blockingByList != nil || viewer.blockedBy == true {
            return false
        }
        
        return true
    }
    
    /// Filters a list of starter pack items to only those eligible for bulk follow.
    public func filterEligibleMembers(
        _ members: [AppBskyGraphDefs.ListItemView],
        currentAccountDID: String
    ) -> [AppBskyGraphDefs.ListItemView] {
        members.filter { isEligibleToFollow(subject: $0.subject, currentAccountDID: currentAccountDID) }
    }
    
    // MARK: - Follow Write Construction (G56)
    
    /// Builds `app.bsky.graph.follow` applyWrites Create operations with starter pack attribution (`via`).
    public func buildFollowWrites(
        subjectDIDs: [DID],
        starterPackUri: ATProtocolURI,
        starterPackCid: CID,
        createdAt: ATProtocolDate = ATProtocolDate(date: Date())
    ) throws -> [ComAtprotoRepoApplyWrites.Create] {
        let collection = try NSID(nsidString: AppBskyGraphFollow.typeIdentifier)
        let viaRef = ComAtprotoRepoStrongRef(uri: starterPackUri, cid: starterPackCid)
        
        return subjectDIDs.map { did in
            let followRecord = AppBskyGraphFollow(
                subject: did,
                createdAt: createdAt,
                via: viaRef
            )
            return ComAtprotoRepoApplyWrites.Create(
                collection: collection,
                rkey: nil,
                value: ATProtocolValueContainer.knownType(followRecord)
            )
        }
    }
    
    /// Builds `app.bsky.graph.follow` applyWrites Create operations with optional attribution.
    public func buildFollowWrites(
        subjectDIDs: [DID],
        via: ComAtprotoRepoStrongRef?,
        createdAt: ATProtocolDate = ATProtocolDate(date: Date())
    ) throws -> [ComAtprotoRepoApplyWrites.Create] {
        let collection = try NSID(nsidString: AppBskyGraphFollow.typeIdentifier)
        
        return subjectDIDs.map { did in
            let followRecord = AppBskyGraphFollow(
                subject: did,
                createdAt: createdAt,
                via: via
            )
            return ComAtprotoRepoApplyWrites.Create(
                collection: collection,
                rkey: nil,
                value: ATProtocolValueContainer.knownType(followRecord)
            )
        }
    }
    
    // MARK: - Batch Execution & Bulk Follow (G56)
    
    /// Performs bulk follow in bounded batches (default 50 writes per applyWrites batch).
    /// Returns the number of successfully created follow records.
    @discardableResult
    public func bulkFollow(
        client: ATProtoClient,
        dids: [DID],
        via: ComAtprotoRepoStrongRef?,
        accountDID: String,
        batchSize: Int = 50
    ) async throws -> Int {
        guard !dids.isEmpty else { return 0 }
        
        let allCreates = try buildFollowWrites(subjectDIDs: dids, via: via)
        let repoIdentifier = try ATIdentifier(string: accountDID)
        
        var totalFollowed = 0
        let chunks = stride(from: 0, to: allCreates.count, by: batchSize).map {
            Array(allCreates[$0..<min($0 + batchSize, allCreates.count)])
        }
        
        for (chunkIndex, chunk) in chunks.enumerated() {
            logger.info("Executing bulk follow batch \(chunkIndex + 1)/\(chunks.count) with \(chunk.count) follows")
            
            let writes = chunk.map { ComAtprotoRepoApplyWrites.InputWritesUnion($0) }
            let input = ComAtprotoRepoApplyWrites.Input(
                repo: repoIdentifier,
                validate: true,
                writes: writes
            )
            
            let (responseCode, _) = try await client.com.atproto.repo.applyWrites(input: input)
            guard responseCode == 200 else {
                logger.error("applyWrites failed with response code \(responseCode)")
                throw NSError(
                    domain: "StarterPackService",
                    code: responseCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to apply follow writes (HTTP \(responseCode))"]
                )
            }
            
            totalFollowed += chunk.count
        }
        
        logger.info("Successfully completed bulk follow for \(totalFollowed) accounts")
        return totalFollowed
    }
    
    /// Follows all eligible members in a starter pack with proper `via` attribution.
    @discardableResult
    public func followAll(
        client: ATProtoClient,
        members: [AppBskyGraphDefs.ListItemView],
        starterPack: AppBskyGraphDefs.StarterPackView,
        currentAccountDID: String,
        batchSize: Int = 50
    ) async throws -> Int {
        let eligible = filterEligibleMembers(members, currentAccountDID: currentAccountDID)
        guard !eligible.isEmpty else {
            logger.info("No eligible members to follow in starter pack")
            return 0
        }
        
        let dids = eligible.map { $0.subject.did }
        let via = ComAtprotoRepoStrongRef(uri: starterPack.uri, cid: starterPack.cid)
        
        return try await bulkFollow(
            client: client,
            dids: dids,
            via: via,
            accountDID: currentAccountDID,
            batchSize: batchSize
        )
    }
    
    // MARK: - Member Pagination Helper (G56/G57/G73)
    
    /// Fetches all members for a list with pagination. Throws if any page fails to load.
    public func fetchAllMembers(
        client: ATProtoClient,
        listUri: ATProtocolURI,
        limitPerPage: Int = 100
    ) async throws -> [AppBskyGraphDefs.ListItemView] {
        var allItems: [AppBskyGraphDefs.ListItemView] = []
        var currentCursor: String? = nil
        var seenCursors = Set<String>()
        
        repeat {
            let input = AppBskyGraphGetList.Parameters(
                list: listUri,
                limit: limitPerPage,
                cursor: currentCursor
            )
            let (responseCode, data) = try await client.app.bsky.graph.getList(input: input)
            guard (200...299).contains(responseCode), let data = data else {
                throw NSError(
                    domain: "StarterPackService",
                    code: responseCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to fetch list members (HTTP \(responseCode))"]
                )
            }
            allItems.append(contentsOf: data.items)
            if let cursor = currentCursor {
                seenCursors.insert(cursor)
            }
            guard let nextCursor = data.cursor, !nextCursor.isEmpty, !seenCursors.contains(nextCursor) else {
                break
            }
            currentCursor = nextCursor
        } while true
        
        return allItems
    }
    
    // MARK: - Starter Pack Write Construction (G57)
    
    /// Builds writes for creating a starter pack and its backing reference list.
    public func buildStarterPackWrites(
        draft: StarterPackDraft,
        accountDID: String,
        listRkey: String,
        packRkey: String,
        createdAt: ATProtocolDate = ATProtocolDate(date: Date())
    ) throws -> (
        listCreate: ComAtprotoRepoApplyWrites.Create,
        itemCreates: [ComAtprotoRepoApplyWrites.Create],
        packCreate: ComAtprotoRepoApplyWrites.Create,
        listUri: ATProtocolURI,
        packUri: ATProtocolURI
    ) {
        guard draft.isValid else {
            throw NSError(
                domain: "StarterPackService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: draft.validationError ?? "Invalid starter pack draft"]
            )
        }
        
        let listCollection = try NSID(nsidString: AppBskyGraphList.typeIdentifier)
        let itemCollection = try NSID(nsidString: AppBskyGraphListitem.typeIdentifier)
        let packCollection = try NSID(nsidString: AppBskyGraphStarterpack.typeIdentifier)
        
        let listUri = try ATProtocolURI(uriString: "at://\(accountDID)/\(AppBskyGraphList.typeIdentifier)/\(listRkey)")
        let packUri = try ATProtocolURI(uriString: "at://\(accountDID)/\(AppBskyGraphStarterpack.typeIdentifier)/\(packRkey)")
        
        // 1. Backing list record (purpose: referencelist)
        let listRecord = AppBskyGraphList(
            purpose: .appbskygraphdefsreferencelist,
            name: draft.trimmedName,
            description: draft.trimmedDescription.isEmpty ? nil : draft.trimmedDescription,
            descriptionFacets: nil,
            avatar: nil,
            labels: nil,
            createdAt: createdAt
        )
        let listCreate = ComAtprotoRepoApplyWrites.Create(
            collection: listCollection,
            rkey: try RecordKey(keyString: listRkey),
            value: ATProtocolValueContainer.knownType(listRecord)
        )
        
        // 2. List items
        let itemCreates = draft.profiles.map { profile in
            let itemRecord = AppBskyGraphListitem(
                subject: profile.did,
                list: listUri,
                createdAt: createdAt
            )
            return ComAtprotoRepoApplyWrites.Create(
                collection: itemCollection,
                rkey: nil,
                value: ATProtocolValueContainer.knownType(itemRecord)
            )
        }
        
        // 3. Starter pack record
        let feedItems = draft.feeds.isEmpty ? nil : draft.feeds.map { AppBskyGraphStarterpack.FeedItem(uri: $0.uri) }
        let packRecord = AppBskyGraphStarterpack(
            name: draft.trimmedName,
            description: draft.trimmedDescription.isEmpty ? nil : draft.trimmedDescription,
            descriptionFacets: nil,
            list: listUri,
            feeds: feedItems,
            createdAt: createdAt
        )
        let packCreate = ComAtprotoRepoApplyWrites.Create(
            collection: packCollection,
            rkey: try RecordKey(keyString: packRkey),
            value: ATProtocolValueContainer.knownType(packRecord)
        )
        
        return (listCreate, itemCreates, packCreate, listUri, packUri)
    }
    
    /// Creates a complete starter pack: backing reference list, members, and starter pack record.
    public func createStarterPack(
        client: ATProtoClient,
        draft: StarterPackDraft,
        accountDID: String
    ) async throws -> ATProtocolURI {
        guard draft.isValid else {
            throw NSError(
                domain: "StarterPackService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: draft.validationError ?? "Invalid starter pack draft"]
            )
        }
        
        let listRkey = await TIDGenerator.next()
        let packRkey = await TIDGenerator.next()
        let createdAt = ATProtocolDate(date: Date())
        let (listCreate, itemCreates, packCreate, _, packUri) = try buildStarterPackWrites(
            draft: draft,
            accountDID: accountDID,
            listRkey: listRkey,
            packRkey: packRkey,
            createdAt: createdAt
        )
        
        let repoIdentifier = try ATIdentifier(string: accountDID)
        
        // Batch 1: Create backing list and first chunk of member list items
        var firstBatchWrites: [ComAtprotoRepoApplyWrites.InputWritesUnion] = [
            ComAtprotoRepoApplyWrites.InputWritesUnion(listCreate)
        ]
        
        let initialChunkCount = min(48, itemCreates.count)
        for i in 0..<initialChunkCount {
            firstBatchWrites.append(ComAtprotoRepoApplyWrites.InputWritesUnion(itemCreates[i]))
        }
        
        logger.info("Writing starter pack initial batch (list + \(initialChunkCount) items)")
        let (firstCode, _) = try await client.com.atproto.repo.applyWrites(
            input: .init(repo: repoIdentifier, validate: true, writes: firstBatchWrites)
        )
        guard firstCode == 200 else {
            throw NSError(
                domain: "StarterPackService",
                code: firstCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create backing list (HTTP \(firstCode))"]
            )
        }
        
        // Remaining member list items in batches of 50
        if itemCreates.count > initialChunkCount {
            let remainingItems = Array(itemCreates[initialChunkCount...])
            let chunks = stride(from: 0, to: remainingItems.count, by: 50).map {
                Array(remainingItems[$0..<min($0 + 50, remainingItems.count)])
            }
            
            for (chunkIdx, chunk) in chunks.enumerated() {
                logger.info("Writing member chunk \(chunkIdx + 1)/\(chunks.count) with \(chunk.count) items")
                let chunkWrites = chunk.map { ComAtprotoRepoApplyWrites.InputWritesUnion($0) }
                let (chunkCode, _) = try await client.com.atproto.repo.applyWrites(
                    input: .init(repo: repoIdentifier, validate: true, writes: chunkWrites)
                )
                guard chunkCode == 200 else {
                    throw NSError(
                        domain: "StarterPackService",
                        code: chunkCode,
                        userInfo: [NSLocalizedDescriptionKey: "Failed writing member list items (HTTP \(chunkCode))"]
                    )
                }
            }
        }
        
        // Final batch: create the starter pack record itself
        logger.info("Creating starterpack record: \(packUri.uriString())")
        let finalWrites = [ComAtprotoRepoApplyWrites.InputWritesUnion(packCreate)]
        let (finalCode, _) = try await client.com.atproto.repo.applyWrites(
            input: .init(repo: repoIdentifier, validate: true, writes: finalWrites)
        )
        guard finalCode == 200 else {
            throw NSError(
                domain: "StarterPackService",
                code: finalCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create starter pack record (HTTP \(finalCode))"]
            )
        }
        
        logger.info("Successfully created starter pack: \(packUri.uriString())")
        return packUri
    }
    
    /// Updates an existing starter pack: updates metadata, feeds, and adds/removes backing list items.
    public func updateStarterPack(
        client: ATProtoClient,
        starterPack: AppBskyGraphDefs.StarterPackView,
        draft: StarterPackDraft,
        accountDID: String,
        batchSize: Int = 50
    ) async throws {
        guard starterPack.creator.did.didString() == accountDID else {
            throw NSError(
                domain: "StarterPackService",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Cannot edit a starter pack owned by another user."]
            )
        }
        guard draft.isValid else {
            throw NSError(
                domain: "StarterPackService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: draft.validationError ?? "Invalid starter pack draft"]
            )
        }
        guard let listUri = starterPack.list?.uri else {
            throw NSError(
                domain: "StarterPackService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Starter pack is missing its backing list URI."]
            )
        }
        
        let repoIdentifier = try ATIdentifier(string: accountDID)
        let itemCollection = try NSID(nsidString: AppBskyGraphListitem.typeIdentifier)
        
        // Fetch current members to calculate additions/deletions
        let currentMembers = try await fetchAllMembers(client: client, listUri: listUri)
        let currentDIDs = Set(currentMembers.map { $0.subject.did })
        let draftDIDs = Set(draft.profiles.map { $0.did })
        
        // Members to delete
        let membersToDelete = currentMembers.filter { !draftDIDs.contains($0.subject.did) }
        // Members to add
        let membersToAdd = draft.profiles.filter { !currentDIDs.contains($0.did) }
        
        var mutationWrites: [ComAtprotoRepoApplyWrites.InputWritesUnion] = []
        
        // Deletions
        for member in membersToDelete {
            if let rkey = member.uri.recordKey, let parsedRkey = try? RecordKey(keyString: rkey) {
                let delete = ComAtprotoRepoApplyWrites.Delete(collection: itemCollection, rkey: parsedRkey)
                mutationWrites.append(ComAtprotoRepoApplyWrites.InputWritesUnion(delete))
            }
        }
        
        // Additions
        let now = ATProtocolDate(date: Date())
        for profile in membersToAdd {
            let itemRecord = AppBskyGraphListitem(subject: profile.did, list: listUri, createdAt: now)
            let create = ComAtprotoRepoApplyWrites.Create(
                collection: itemCollection,
                rkey: nil,
                value: ATProtocolValueContainer.knownType(itemRecord)
            )
            mutationWrites.append(ComAtprotoRepoApplyWrites.InputWritesUnion(create))
        }
        
        // Apply member mutations in bounded batches
        if !mutationWrites.isEmpty {
            let chunks = stride(from: 0, to: mutationWrites.count, by: batchSize).map {
                Array(mutationWrites[$0..<min($0 + batchSize, mutationWrites.count)])
            }
            
            for (chunkIdx, chunk) in chunks.enumerated() {
                logger.info("Applying listitem mutation batch \(chunkIdx + 1)/\(chunks.count) (\(chunk.count) writes)")
                let (code, _) = try await client.com.atproto.repo.applyWrites(
                    input: .init(repo: repoIdentifier, validate: true, writes: chunk)
                )
                guard code == 200 else {
                    throw NSError(
                        domain: "StarterPackService",
                        code: code,
                        userInfo: [NSLocalizedDescriptionKey: "Failed updating member list items (HTTP \(code))"]
                    )
                }
            }
        }
        
        // Update starter pack record (preserving original createdAt and list URI)
        guard let packRkey = starterPack.uri.recordKey else {
            throw NSError(
                domain: "StarterPackService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Cannot determine starter pack record key."]
            )
        }
        
        let originalCreatedAt: ATProtocolDate
        if case .knownType(let recordValue) = starterPack.record,
           let starterpackRecord = recordValue as? AppBskyGraphStarterpack {
            originalCreatedAt = starterpackRecord.createdAt
        } else {
            originalCreatedAt = starterPack.indexedAt
        }
        
        let feedItems = draft.feeds.isEmpty ? nil : draft.feeds.map { AppBskyGraphStarterpack.FeedItem(uri: $0.uri) }
        let updatedPackRecord = AppBskyGraphStarterpack(
            name: draft.trimmedName,
            description: draft.trimmedDescription.isEmpty ? nil : draft.trimmedDescription,
            descriptionFacets: nil,
            list: listUri,
            feeds: feedItems,
            createdAt: originalCreatedAt
        )
        
        let packCollection = try NSID(nsidString: AppBskyGraphStarterpack.typeIdentifier)
        let (putCode, _) = try await client.com.atproto.repo.putRecord(
            input: .init(
                repo: repoIdentifier,
                collection: packCollection,
                rkey: try RecordKey(keyString: packRkey),
                validate: true,
                record: ATProtocolValueContainer.knownType(updatedPackRecord)
            )
        )
        guard putCode == 200 else {
            throw NSError(
                domain: "StarterPackService",
                code: putCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to update starter pack record (HTTP \(putCode))"]
            )
        }
        
        logger.info("Successfully updated starter pack: \(starterPack.uri.uriString())")
    }
    
    // MARK: - List Cloning (G73)
    
    /// Builds `app.bsky.graph.listitem` write operations for copying members to a target list.
    public func buildListItemWrites(
        memberDIDs: [DID],
        targetListUri: ATProtocolURI,
        createdAt: ATProtocolDate = ATProtocolDate(date: Date())
    ) throws -> [ComAtprotoRepoApplyWrites.Create] {
        let itemCollection = try NSID(nsidString: AppBskyGraphListitem.typeIdentifier)
        return memberDIDs.map { did in
            let item = AppBskyGraphListitem(subject: did, list: targetListUri, createdAt: createdAt)
            return ComAtprotoRepoApplyWrites.Create(
                collection: itemCollection,
                rkey: nil,
                value: ATProtocolValueContainer.knownType(item)
            )
        }
    }
    
    /// Copies all member profiles from a starter pack's list into a newly created curated list.
    @discardableResult
    public func copyMembersToCuratedList(
        client: ATProtoClient,
        sourceListUri: ATProtocolURI,
        targetListUri: ATProtocolURI,
        accountDID: String,
        batchSize: Int = 50
    ) async throws -> Int {
        logger.info("Fetching members to copy from \(sourceListUri.uriString()) to \(targetListUri.uriString())")
        let members = try await fetchAllMembers(client: client, listUri: sourceListUri)
        guard !members.isEmpty else { return 0 }
        
        let dids = members.map { $0.subject.did }
        let creates = try buildListItemWrites(memberDIDs: dids, targetListUri: targetListUri)
        let repoIdentifier = try ATIdentifier(string: accountDID)
        
        var totalCopied = 0
        let chunks = stride(from: 0, to: creates.count, by: batchSize).map {
            Array(creates[$0..<min($0 + batchSize, creates.count)])
        }
        
        for (chunkIdx, chunk) in chunks.enumerated() {
            logger.info("Copying listitem batch \(chunkIdx + 1)/\(chunks.count) with \(chunk.count) items")
            let writes = chunk.map { ComAtprotoRepoApplyWrites.InputWritesUnion($0) }
            let (code, _) = try await client.com.atproto.repo.applyWrites(
                input: .init(repo: repoIdentifier, validate: true, writes: writes)
            )
            guard code == 200 else {
                throw NSError(
                    domain: "StarterPackService",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "Failed copying list items batch (HTTP \(code))"]
                )
            }
            totalCopied += chunk.count
        }
        
        logger.info("Successfully copied \(totalCopied) members to list \(targetListUri.uriString())")
        return totalCopied
    }
}
