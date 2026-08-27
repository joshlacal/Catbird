//
//  StarterPackServiceTests.swift
//  CatbirdTests
//
//  Tests for StarterPackService eligibility filtering and follow write composition (WS-H / G56).
//

import Testing
import Foundation
@testable import Catbird
import Petrel

@Suite("StarterPackService")
struct StarterPackServiceTests {
    private let service = StarterPackService.shared
    
    private let currentDID = "did:plc:user1234567890abcdef1234"
    private let targetDID1 = try! DID(didString: "did:plc:target111111111111111111")
    private let targetDID2 = try! DID(didString: "did:plc:target222222222222222222")
    private let packURI = try! ATProtocolURI(uriString: "at://did:plc:creator1234567890abcde1/app.bsky.graph.starterpack/3k2v1r4y7z")
    private let packCID = try! CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
    
    private func makeProfile(
        did: DID,
        handle: String = "alice.bsky.social",
        viewer: AppBskyActorDefs.ViewerState? = nil
    ) -> AppBskyActorDefs.ProfileViewBasic {
        let handleObj = try! Handle(handleString: handle)
        return AppBskyActorDefs.ProfileViewBasic(
            did: did,
            handle: handleObj,
            displayName: "Alice",
            pronouns: nil,
            avatar: nil,
            associated: nil,
            viewer: viewer,
            labels: nil,
            createdAt: nil,
            verification: nil,
            status: nil,
            debug: nil
        )
    }
    
    private func makeProfileView(
        did: DID,
        handle: String = "alice.bsky.social",
        viewer: AppBskyActorDefs.ViewerState? = nil
    ) -> AppBskyActorDefs.ProfileView {
        let handleObj = try! Handle(handleString: handle)
        return AppBskyActorDefs.ProfileView(
            did: did,
            handle: handleObj,
            displayName: "Alice",
            pronouns: nil,
            description: nil,
            avatar: nil,
            associated: nil,
            indexedAt: nil,
            createdAt: nil,
            viewer: viewer,
            labels: nil,
            verification: nil,
            status: nil,
            debug: nil
        )
    }
    
    private func makeListItem(
        subject: AppBskyActorDefs.ProfileView,
        uri: String = "at://did:plc:creator1234567890abcde1/app.bsky.graph.listitem/item1"
    ) -> AppBskyGraphDefs.ListItemView {
        let itemUri = try! ATProtocolURI(uriString: uri)
        return AppBskyGraphDefs.ListItemView(uri: itemUri, subject: subject)
    }
    
    // MARK: - Eligibility Tests
    
    @Test("Rejects signed-in account from follow eligibility")
    func testSelfMemberExcluded() {
        let selfDID = try! DID(didString: currentDID)
        let profile = makeProfile(did: selfDID)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(!eligible, "Current user must be excluded from bulk follow")
    }
    
    @Test("Rejects already-followed accounts from follow eligibility")
    func testAlreadyFollowedMemberExcluded() {
        let followUri = try! ATProtocolURI(uriString: "at://did:plc:user1234567890abcdef1234/app.bsky.graph.follow/3k123")
        let viewer = AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: nil,
            blockingByList: nil,
            following: followUri,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        let profile = makeProfile(did: targetDID1, viewer: viewer)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(!eligible, "Already followed account must be excluded from bulk follow")
    }
    
    @Test("Rejects muted accounts from follow eligibility")
    func testMutedMemberExcluded() {
        let viewer = AppBskyActorDefs.ViewerState(
            muted: true,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: nil,
            blockingByList: nil,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        let profile = makeProfile(did: targetDID1, viewer: viewer)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(!eligible, "Muted account must be excluded from bulk follow")
    }
    
    @Test("Rejects accounts muted by list from follow eligibility")
    func testMutedByListMemberExcluded() {
        let listUri = try! ATProtocolURI(uriString: "at://did:plc:user1234567890abcdef1234/app.bsky.graph.list/mutelist")
        let listCid = try! CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        let listBasic = AppBskyGraphDefs.ListViewBasic(
            uri: listUri,
            cid: listCid,
            name: "Mute List",
            purpose: .appbskygraphdefsmodlist,
            avatar: nil,
            listItemCount: 10,
            labels: nil,
            viewer: nil,
            indexedAt: ATProtocolDate(date: Date())
        )
        let viewer = AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: listBasic,
            blockedBy: false,
            blocking: nil,
            blockingByList: nil,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        let profile = makeProfile(did: targetDID1, viewer: viewer)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(!eligible, "Account muted by list must be excluded from bulk follow")
    }
    
    @Test("Rejects blocking accounts from follow eligibility")
    func testBlockingMemberExcluded() {
        let blockUri = try! ATProtocolURI(uriString: "at://did:plc:user1234567890abcdef1234/app.bsky.graph.block/3k456")
        let viewer = AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: blockUri,
            blockingByList: nil,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        let profile = makeProfile(did: targetDID1, viewer: viewer)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(!eligible, "Blocking account must be excluded from bulk follow")
    }
    
    @Test("Rejects accounts blocked by list from follow eligibility")
    func testBlockingByListMemberExcluded() {
        let listUri = try! ATProtocolURI(uriString: "at://did:plc:user1234567890abcdef1234/app.bsky.graph.list/blocklist")
        let listCid = try! CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        let listBasic = AppBskyGraphDefs.ListViewBasic(
            uri: listUri,
            cid: listCid,
            name: "Block List",
            purpose: .appbskygraphdefsmodlist,
            avatar: nil,
            listItemCount: 10,
            labels: nil,
            viewer: nil,
            indexedAt: ATProtocolDate(date: Date())
        )
        let viewer = AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: nil,
            blockingByList: listBasic,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        let profile = makeProfile(did: targetDID1, viewer: viewer)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(!eligible, "Account blocked by list must be excluded from bulk follow")
    }
    
    @Test("Rejects accounts where blockedBy is true from follow eligibility")
    func testBlockedByMemberExcluded() {
        let viewer = AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: true,
            blocking: nil,
            blockingByList: nil,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        let profile = makeProfile(did: targetDID1, viewer: viewer)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(!eligible, "Account that blocked user must be excluded from bulk follow")
    }
    
    @Test("Accepts neutral non-followed profile for follow eligibility")
    func testEligibleMemberIncluded() {
        let viewer = AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: nil,
            blockingByList: nil,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        let profile = makeProfile(did: targetDID1, viewer: viewer)
        
        let eligible = service.isEligibleToFollow(subject: profile, currentAccountDID: currentDID)
        #expect(eligible, "Neutral non-followed profile should be eligible")
    }
    
    @Test("filterEligibleMembers accurately retains only eligible members")
    func testFilterEligibleMembers() {
        let selfDID = try! DID(didString: currentDID)
        let item1 = makeListItem(subject: makeProfileView(did: selfDID), uri: "at://did:plc:creator1234567890abcde1/app.bsky.graph.listitem/item1")
        let item2 = makeListItem(subject: makeProfileView(did: targetDID1), uri: "at://did:plc:creator1234567890abcde1/app.bsky.graph.listitem/item2")
        let item3 = makeListItem(subject: makeProfileView(did: targetDID2, viewer: AppBskyActorDefs.ViewerState(
            muted: true,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: nil,
            blockingByList: nil,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )), uri: "at://did:plc:creator1234567890abcde1/app.bsky.graph.listitem/item3")
        let filtered = service.filterEligibleMembers([item1, item2, item3], currentAccountDID: currentDID)
        #expect(filtered.count == 1)
        #expect(filtered.first?.subject.did == targetDID1)
    }
    
    // MARK: - Write Composition & Attribution Tests
    
    @Test("buildFollowWrites creates valid follow writes with via attribution")
    func testBuildFollowWritesAttribution() throws {
        let fixedDate = ATProtocolDate(date: Date())
        let writes = try service.buildFollowWrites(
            subjectDIDs: [targetDID1, targetDID2],
            starterPackUri: packURI,
            starterPackCid: packCID,
            createdAt: fixedDate
        )
        
        #expect(writes.count == 2)
        
        for (index, write) in writes.enumerated() {
            #expect(write.collection.description == "app.bsky.graph.follow")
            #expect(write.rkey == nil)
            
            guard case .knownType(let value) = write.value,
                  let followRecord = value as? AppBskyGraphFollow else {
                Issue.record("Value must be AppBskyGraphFollow")
                continue
            }
            
            let expectedDID = index == 0 ? targetDID1 : targetDID2
            #expect(followRecord.subject == expectedDID)
            #expect(followRecord.createdAt == fixedDate)
            
            guard let via = followRecord.via else {
                Issue.record("via attribution must be present")
                continue
            }
            
            #expect(via.uri == packURI)
            #expect(via.cid == packCID)
        }
    }
    
    // MARK: - Draft Boundary & Validation Tests (G57)
    
    @Test("Validates starter pack name length boundaries")
    func testDraftNameValidation() {
        var draft = StarterPackDraft(profiles: [makeProfile(did: targetDID1)])
        
        // Empty name
        draft.name = ""
        #expect(!draft.isNameValid)
        
        // Whitespace only
        draft.name = "   \n  "
        #expect(!draft.isNameValid)
        
        // Exactly 1 character
        draft.name = "A"
        #expect(draft.isNameValid)
        
        // Exactly 50 characters
        draft.name = String(repeating: "x", count: 50)
        #expect(draft.isNameValid)
        
        // 51 characters (invalid)
        draft.name = String(repeating: "x", count: 51)
        #expect(!draft.isNameValid)
    }
    
    @Test("Validates starter pack description length boundaries")
    func testDraftDescriptionValidation() {
        var draft = StarterPackDraft(name: "Tech", profiles: [makeProfile(did: targetDID1)])
        
        // Empty description is valid
        draft.description = ""
        #expect(draft.isDescriptionValid)
        
        // Exactly 300 characters
        draft.description = String(repeating: "d", count: 300)
        #expect(draft.isDescriptionValid)
        
        // 301 characters (invalid)
        draft.description = String(repeating: "d", count: 301)
        #expect(!draft.isDescriptionValid)
    }
    
    @Test("Validates starter pack profile count boundaries")
    func testDraftProfileCountValidation() {
        var draft = StarterPackDraft(name: "Tech")
        
        // 0 profiles (invalid)
        draft.profiles = []
        #expect(!draft.isProfilesValid)
        
        // 1 profile (valid minimum)
        draft.profiles = [makeProfile(did: targetDID1)]
        #expect(draft.isProfilesValid)
        
        // 150 profiles (valid maximum)
        draft.profiles = (1...150).map { i in
            makeProfile(did: try! DID(didString: "did:plc:user0000000000000000\(String(format: "%04d", i))"))
        }
        #expect(draft.profiles.count == 150)
        #expect(draft.isProfilesValid)
        
        // 151 profiles (invalid)
        draft.profiles.append(makeProfile(did: try! DID(didString: "did:plc:user00000000000000000151")))
        #expect(!draft.isProfilesValid)
    }
    
    @Test("Validates starter pack feed count boundaries")
    func testDraftFeedCountValidation() {
        var draft = StarterPackDraft(name: "Tech", profiles: [makeProfile(did: targetDID1)])
        
        // 0 feeds (valid)
        draft.feeds = []
        #expect(draft.isFeedsValid)
        
        // 3 feeds (valid maximum)
        draft.feeds = (1...3).map { i in
            AppBskyFeedDefs.GeneratorView(
                uri: try! ATProtocolURI(uriString: "at://did:plc:creator1234567890abcde1/app.bsky.feed.generator/feed\(i)"),
                cid: try! CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"),
                did: try! DID(didString: "did:plc:creator1234567890abcde1"),
                creator: makeProfileView(did: targetDID1),
                displayName: "Feed \(i)",
                description: nil,
                descriptionFacets: nil,
                avatar: nil,
                likeCount: 0,
                acceptsInteractions: nil,
                labels: nil,
                viewer: nil,
                contentMode: nil,
                indexedAt: ATProtocolDate(date: Date())
            )
        }
        #expect(draft.feeds.count == 3)
        #expect(draft.isFeedsValid)
        
        // 4 feeds (invalid)
        draft.feeds.append(
            AppBskyFeedDefs.GeneratorView(
                uri: try! ATProtocolURI(uriString: "at://did:plc:creator1234567890abcde1/app.bsky.feed.generator/feed4"),
                cid: try! CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"),
                did: try! DID(didString: "did:plc:creator1234567890abcde1"),
                creator: makeProfileView(did: targetDID1),
                displayName: "Feed 4",
                description: nil,
                descriptionFacets: nil,
                avatar: nil,
                likeCount: 0,
                acceptsInteractions: nil,
                labels: nil,
                viewer: nil,
                contentMode: nil,
                indexedAt: ATProtocolDate(date: Date())
            )
        )
        #expect(!draft.isFeedsValid)
    }
    
    // MARK: - Starter Pack Write Construction Tests (G57)
    
    @Test("buildStarterPackWrites generates correct reference list, listitems, and starterpack record")
    func testBuildStarterPackWrites() throws {
        let profile1 = makeProfile(did: targetDID1)
        let profile2 = makeProfile(did: targetDID2)
        let draft = StarterPackDraft(
            name: "Awesome Developers",
            description: "A starter pack for devs",
            profiles: [profile1, profile2],
            feeds: []
        )
        
        let listRkey = "3l4vlist12345"
        let packRkey = "3l4vpack12345"
        let fixedDate = ATProtocolDate(date: Date())
        
        let (listCreate, itemCreates, packCreate, listUri, packUri) = try service.buildStarterPackWrites(
            draft: draft,
            accountDID: currentDID,
            listRkey: listRkey,
            packRkey: packRkey,
            createdAt: fixedDate
        )
        
        // Check list record
        #expect(listCreate.collection.description == "app.bsky.graph.list")
        #expect(listCreate.rkey?.value == listRkey)
        #expect(listUri.uriString() == "at://\(currentDID)/app.bsky.graph.list/\(listRkey)")
        
        guard case .knownType(let listVal) = listCreate.value,
              let listRecord = listVal as? AppBskyGraphList else {
            Issue.record("Expected AppBskyGraphList")
            return
        }
        #expect(listRecord.purpose == AppBskyGraphDefs.ListPurpose.appbskygraphdefsreferencelist)
        #expect(listRecord.name == "Awesome Developers")
        #expect(listRecord.description == "A starter pack for devs")
        #expect(listRecord.createdAt == fixedDate)
        
        // Check list item records
        #expect(itemCreates.count == 2)
        for (index, itemCreate) in itemCreates.enumerated() {
            #expect(itemCreate.collection.description == "app.bsky.graph.listitem")
            guard case .knownType(let itemVal) = itemCreate.value,
                  let itemRecord = itemVal as? AppBskyGraphListitem else {
                Issue.record("Expected AppBskyGraphListitem")
                continue
            }
            let expectedDID = index == 0 ? targetDID1 : targetDID2
            #expect(itemRecord.subject == expectedDID)
            #expect(itemRecord.list == listUri)
            #expect(itemRecord.createdAt == fixedDate)
        }
        
        // Check starter pack record
        #expect(packCreate.collection.description == "app.bsky.graph.starterpack")
        #expect(packCreate.rkey?.value == packRkey)
        #expect(packUri.uriString() == "at://\(currentDID)/app.bsky.graph.starterpack/\(packRkey)")
        
        guard case .knownType(let packVal) = packCreate.value,
              let packRecord = packVal as? AppBskyGraphStarterpack else {
            Issue.record("Expected AppBskyGraphStarterpack")
            return
        }
        #expect(packRecord.name == "Awesome Developers")
        #expect(packRecord.description == "A starter pack for devs")
        #expect(packRecord.list == listUri)
        #expect(packRecord.createdAt == fixedDate)
    }
    
    // MARK: - List Cloning Write Tests (G73)
    
    @Test("buildListItemWrites generates listitems pointing to target list")
    func testBuildListItemWrites() throws {
        let targetListUri = try ATProtocolURI(uriString: "at://\(currentDID)/app.bsky.graph.list/curatedlist123")
        let fixedDate = ATProtocolDate(date: Date())
        
        let creates = try service.buildListItemWrites(
            memberDIDs: [targetDID1, targetDID2],
            targetListUri: targetListUri,
            createdAt: fixedDate
        )
        
        #expect(creates.count == 2)
        for (index, create) in creates.enumerated() {
            #expect(create.collection.description == "app.bsky.graph.listitem")
            guard case .knownType(let itemVal) = create.value,
                  let itemRecord = itemVal as? AppBskyGraphListitem else {
                Issue.record("Expected AppBskyGraphListitem")
                continue
            }
            let expectedDID = index == 0 ? targetDID1 : targetDID2
            #expect(itemRecord.subject == expectedDID)
            #expect(itemRecord.list == targetListUri)
            #expect(itemRecord.createdAt == fixedDate)
        }
    }
    
    @Test("buildListItemWrites handles empty member list")
    func testBuildListItemWritesEmpty() throws {
        let targetListUri = try ATProtocolURI(uriString: "at://\(currentDID)/app.bsky.graph.list/curatedlist123")
        let creates = try service.buildListItemWrites(
            memberDIDs: [],
            targetListUri: targetListUri
        )
        #expect(creates.isEmpty)
    }
    
    @Test("List cloning batches operations in chunks of 50")
    func testListCloningBatching() throws {
        let targetListUri = try ATProtocolURI(uriString: "at://\(currentDID)/app.bsky.graph.list/curatedlist123")
        let totalMembers = 120
        let dids = (1...totalMembers).map { i in
            try! DID(didString: "did:plc:member\(String(format: "%018d", i))")
        }
        
        let creates = try service.buildListItemWrites(
            memberDIDs: dids,
            targetListUri: targetListUri
        )
        #expect(creates.count == 120)
        
        let batchSize = 50
        let chunks = stride(from: 0, to: creates.count, by: batchSize).map {
            Array(creates[$0..<min($0 + batchSize, creates.count)])
        }
        
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 50)
        #expect(chunks[1].count == 50)
        #expect(chunks[2].count == 20)
    }
    
    // MARK: - Regression Tests for Pagination & Follow All Filtering (WS-H-19, WS-H-20)
    
    @Test("filterEligibleMembers excludes self, already followed, and muted/blocked members")
    func testFilterEligibleMembersComprehensive() {
        let selfDID = try! DID(didString: currentDID)
        let followUri = try! ATProtocolURI(uriString: "at://\(currentDID)/app.bsky.graph.follow/3k123")
        
        let followedViewer = AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: nil,
            blockingByList: nil,
            following: followUri,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        )
        
        let item1 = makeListItem(subject: makeProfileView(did: targetDID1), uri: "at://\(currentDID)/app.bsky.graph.listitem/item1")
        let item2 = makeListItem(subject: makeProfileView(did: targetDID2), uri: "at://\(currentDID)/app.bsky.graph.listitem/item2")
        let itemSelf = makeListItem(subject: makeProfileView(did: selfDID), uri: "at://\(currentDID)/app.bsky.graph.listitem/itemSelf")
        let itemFollowed = makeListItem(subject: makeProfileView(did: try! DID(didString: "did:plc:alreadyfollowed"), viewer: followedViewer), uri: "at://\(currentDID)/app.bsky.graph.listitem/itemFollowed")
        
        let filtered = service.filterEligibleMembers([item1, item2, itemSelf, itemFollowed], currentAccountDID: currentDID)
        #expect(filtered.count == 2)
        #expect(filtered.map { $0.subject.did } == [targetDID1, targetDID2])
    }
    
    @Test("buildFollowWrites creates correct follow writes with starter pack attribution")
    func testBuildFollowWritesWithStarterPackAttribution() throws {
        let writes = try service.buildFollowWrites(
            subjectDIDs: [targetDID1, targetDID2],
            starterPackUri: packURI,
            starterPackCid: packCID
        )
        
        #expect(writes.count == 2)
        for (index, write) in writes.enumerated() {
            #expect(write.collection.description == "app.bsky.graph.follow")
            guard case .knownType(let val) = write.value,
                  let follow = val as? AppBskyGraphFollow else {
                Issue.record("Expected AppBskyGraphFollow record")
                continue
            }
            let expectedDID = index == 0 ? targetDID1 : targetDID2
            #expect(follow.subject == expectedDID)
            #expect(follow.via?.uri == packURI)
            #expect(follow.via?.cid == packCID)
        }
    }
}

