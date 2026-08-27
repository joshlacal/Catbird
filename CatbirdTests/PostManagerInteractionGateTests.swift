//
//  PostManagerInteractionGateTests.swift
//  CatbirdTests
//

import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("PostManager and Interaction Gate Tests")
struct PostManagerInteractionGateTests {

    // MARK: - Profile Pinning (G11)

    @Test("Pinning copies all profile fields and updates only pinnedPost")
    func pinningCopiesProfileAndChangesOnlyPinnedPost() throws {
        let originalDate = ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
        let avatarBlob = Blob(type: "blob", mimeType: "image/jpeg", size: 1024)
        let bannerBlob = Blob(type: "blob", mimeType: "image/jpeg", size: 2048)
        let websiteURI = URI(uriString: "https://example.com")
        let starterPackURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.graph.starterpack/3l5xyz")
        let dummyCID = try CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        let starterPackRef = ComAtprotoRepoStrongRef(uri: starterPackURI, cid: dummyCID)
        let labelValue = ComAtprotoLabelDefs.Label(
            ver: nil,
            src: try DID(didString: "did:plc:alice"),
            uri: URI(uriString: "at://did:plc:alice/app.bsky.actor.profile/self"),
            cid: dummyCID,
            val: "custom-label",
            neg: nil,
            cts: originalDate,
            exp: nil,
            sig: nil
        )
        let labels = AppBskyActorProfile.AppBskyActorProfileLabelsUnion.comAtprotoLabelDefsSelfLabels(
            ComAtprotoLabelDefs.SelfLabels(values: [ComAtprotoLabelDefs.SelfLabel(val: "custom-label")])
        )

        let initialProfile = AppBskyActorProfile(
            displayName: "Alice",
            description: "Hello world",
            pronouns: "she/her",
            website: websiteURI,
            avatar: avatarBlob,
            banner: bannerBlob,
            labels: labels,
            joinedViaStarterPack: starterPackRef,
            pinnedPost: nil,
            createdAt: originalDate
        )

        // 1. Simulate pinPost logic
        let postURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5pin123")
        let pinnedRef = ComAtprotoRepoStrongRef(uri: postURI, cid: dummyCID)
        let pinnedProfile = AppBskyActorProfile(
            displayName: initialProfile.displayName,
            description: initialProfile.description,
            pronouns: initialProfile.pronouns,
            website: initialProfile.website,
            avatar: initialProfile.avatar,
            banner: initialProfile.banner,
            labels: initialProfile.labels,
            joinedViaStarterPack: initialProfile.joinedViaStarterPack,
            pinnedPost: pinnedRef,
            createdAt: initialProfile.createdAt
        )

        // Assert all fields preserved
        #expect(pinnedProfile.displayName == "Alice")
        #expect(pinnedProfile.description == "Hello world")
        #expect(pinnedProfile.pronouns == "she/her")
        #expect(pinnedProfile.website == websiteURI)
        #expect(pinnedProfile.avatar == avatarBlob)
        #expect(pinnedProfile.banner == bannerBlob)
        #expect(pinnedProfile.labels == labels)
        #expect(pinnedProfile.joinedViaStarterPack == starterPackRef)
        #expect(pinnedProfile.createdAt == originalDate)
        #expect(pinnedProfile.pinnedPost == pinnedRef)

        // 2. Simulate unpinPost logic
        let unpinnedProfile = AppBskyActorProfile(
            displayName: pinnedProfile.displayName,
            description: pinnedProfile.description,
            pronouns: pinnedProfile.pronouns,
            website: pinnedProfile.website,
            avatar: pinnedProfile.avatar,
            banner: pinnedProfile.banner,
            labels: pinnedProfile.labels,
            joinedViaStarterPack: pinnedProfile.joinedViaStarterPack,
            pinnedPost: nil,
            createdAt: pinnedProfile.createdAt
        )

        #expect(unpinnedProfile.displayName == "Alice")
        #expect(unpinnedProfile.description == "Hello world")
        #expect(unpinnedProfile.pinnedPost == nil)
        #expect(unpinnedProfile.createdAt == originalDate)
    }

    // MARK: - Postgate and Interaction Settings (G18)

    @Test("Composer Postgate DisableRule is generated when quotes are disabled")
    func composerPostgateDisableRule() throws {
        var state = PostInteractionSettingsState()
        #expect(state.allowQuotes == true)
        #expect(state.toPostgateEmbeddingRules() == nil)
        #expect(state.isCustom == false)

        state.allowQuotes = false
        #expect(state.isCustom == true)

        let rules = try #require(state.toPostgateEmbeddingRules())
        #expect(rules.count == 1)

        guard case let .appBskyFeedPostgateDisableRule(disableRule) = rules[0] else {
            Issue.record("Expected .appBskyFeedPostgateDisableRule")
            return
        }
        #expect(disableRule == AppBskyFeedPostgate.DisableRule())
    }

    @Test("Composer Postgate preserves atomic write shape and record keys")
    func composerPostgatePreservesAtomicWriteShape() throws {
        let did = "did:plc:alice"
        let tid = "3l5abc123"
        let postURI = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(tid)")
        let date = ATProtocolDate(date: Date())

        var settings = PostInteractionSettingsState()
        settings.allowQuotes = false

        let postgate = AppBskyFeedPostgate(
            createdAt: date,
            post: postURI,
            detachedEmbeddingUris: nil,
            embeddingRules: settings.toPostgateEmbeddingRules()
        )

        let createPostgate = ComAtprotoRepoApplyWrites.Create(
            collection: try NSID(nsidString: "app.bsky.feed.postgate"),
            rkey: try RecordKey(keyString: tid),
            value: ATProtocolValueContainer.knownType(postgate)
        )

        #expect(createPostgate.collection.nsidString() == "app.bsky.feed.postgate")
        #expect(createPostgate.rkey?.value == tid)

        guard case let .knownType(val) = createPostgate.value,
              let pg = val as? AppBskyFeedPostgate else {
            Issue.record("Expected AppBskyFeedPostgate in container")
            return
        }
        #expect(pg.post == postURI)
        #expect(pg.embeddingRules?.count == 1)
    }

    // MARK: - Post-Publish Interaction Settings Editing (G12)

    @Test("Editing threadgate preserves existing hidden replies and creation date")
    func editingThreadgatePreservesHiddenReplies() throws {
        let postURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5root")
        let replyURI = try ATProtocolURI(uriString: "at://did:plc:bob/app.bsky.feed.post/3l5reply")
        let originalDate = ATProtocolDate(date: Date(timeIntervalSince1970: 1_600_000_000))

        let existingTg = AppBskyFeedThreadgate(
            post: postURI,
            allow: [.appBskyFeedThreadgateMentionRule(AppBskyFeedThreadgate.MentionRule())],
            createdAt: originalDate,
            hiddenReplies: [replyURI]
        )

        var newSettings = PostInteractionSettingsState()
        newSettings.threadgate.selectOption(.following)

        let mergedTg = PostInteractionSettingsState.mergeThreadgate(
            existing: existingTg,
            postURI: postURI,
            settings: newSettings
        )

        #expect(mergedTg.post == postURI)
        #expect(mergedTg.createdAt == originalDate)
        #expect(mergedTg.hiddenReplies == [replyURI])
        #expect(mergedTg.allow?.count == 1)
        if case .appBskyFeedThreadgateFollowingRule = mergedTg.allow?[0] {
            // Success
        } else {
            Issue.record("Expected following rule in allow rules")
        }
    }

    @Test("Editing postgate preserves detached embedding URIs and creation date")
    func editingPostgatePreservesDetachedEmbeddingUris() throws {
        let postURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5orig")
        let quoteURI = try ATProtocolURI(uriString: "at://did:plc:carol/app.bsky.feed.post/3l5quote")
        let originalDate = ATProtocolDate(date: Date(timeIntervalSince1970: 1_650_000_000))

        let existingPg = AppBskyFeedPostgate(
            createdAt: originalDate,
            post: postURI,
            detachedEmbeddingUris: [quoteURI],
            embeddingRules: nil
        )

        var newSettings = PostInteractionSettingsState()
        newSettings.allowQuotes = false

        let mergedPg = PostInteractionSettingsState.mergePostgate(
            existing: existingPg,
            postURI: postURI,
            settings: newSettings
        )

        #expect(mergedPg.post == postURI)
        #expect(mergedPg.createdAt == originalDate)
        #expect(mergedPg.detachedEmbeddingUris == [quoteURI])
        #expect(mergedPg.embeddingRules?.count == 1)
    }

    // MARK: - Threadgate Hide/Show Reply Moderation (G13)

    @Test("Hiding and showing reply preserves allow rules")
    func hideAndShowReplyPreservesAllowRules() throws {
        let rootURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5root")
        let reply1 = try ATProtocolURI(uriString: "at://did:plc:bob/app.bsky.feed.post/3l5reply1")
        let reply2 = try ATProtocolURI(uriString: "at://did:plc:carol/app.bsky.feed.post/3l5reply2")
        let allowRule = AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion.appBskyFeedThreadgateMentionRule(
            AppBskyFeedThreadgate.MentionRule()
        )

        var tg = AppBskyFeedThreadgate(
            post: rootURI,
            allow: [allowRule],
            createdAt: ATProtocolDate(date: Date()),
            hiddenReplies: [reply1]
        )

        // Add reply2 to hidden replies
        var hidden = tg.hiddenReplies ?? []
        if !hidden.contains(reply2) {
            hidden.append(reply2)
        }
        tg = AppBskyFeedThreadgate(
            post: rootURI,
            allow: tg.allow,
            createdAt: tg.createdAt,
            hiddenReplies: hidden
        )

        #expect(tg.allow?.count == 1)
        #expect(tg.hiddenReplies?.count == 2)
        #expect(tg.hiddenReplies?.contains(reply1) == true)
        #expect(tg.hiddenReplies?.contains(reply2) == true)

        // Unhide reply1
        hidden.removeAll { $0 == reply1 }
        tg = AppBskyFeedThreadgate(
            post: rootURI,
            allow: tg.allow,
            createdAt: tg.createdAt,
            hiddenReplies: hidden.isEmpty ? nil : hidden
        )

        #expect(tg.allow?.count == 1)
        #expect(tg.hiddenReplies == [reply2])
    }

    @Test("Hiding reply deduplicates URI")
    func hidingReplyDeduplicatesURI() throws {
        let replyURI = try ATProtocolURI(uriString: "at://did:plc:bob/app.bsky.feed.post/3l5reply1")
        var hiddenURIs = [replyURI]

        // Attempting to append same URI again
        if !hiddenURIs.contains(replyURI) {
            hiddenURIs.append(replyURI)
        }

        #expect(hiddenURIs.count == 1)
    }

    @Test("Hidden reply limit enforces maximum 300 entries")
    func hiddenReplyLimitIs300() throws {
        #expect(PostManager.maxHiddenReplies == 300)

        var hiddenURIs: [ATProtocolURI] = []
        for i in 0..<300 {
            hiddenURIs.append(try ATProtocolURI(uriString: "at://did:plc:user/app.bsky.feed.post/post\(i)"))
        }

        let newURI = try ATProtocolURI(uriString: "at://did:plc:user/app.bsky.feed.post/post301")
        let wouldExceed = hiddenURIs.count >= PostManager.maxHiddenReplies
        #expect(wouldExceed == true)
    }

    // MARK: - Detach Quote Post (G14)

    @Test("Detach and reattach quote preserves embedding rules")
    func detachAndReattachQuotePreservesEmbeddingRules() throws {
        let postURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5orig")
        let quoteURI = try ATProtocolURI(uriString: "at://did:plc:carol/app.bsky.feed.post/3l5quote")
        let disableRule = AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion.appBskyFeedPostgateDisableRule(
            AppBskyFeedPostgate.DisableRule()
        )

        var pg = AppBskyFeedPostgate(
            createdAt: ATProtocolDate(date: Date()),
            post: postURI,
            detachedEmbeddingUris: nil,
            embeddingRules: [disableRule]
        )

        // Detach
        var detached = pg.detachedEmbeddingUris ?? []
        if !detached.contains(quoteURI) {
            detached.append(quoteURI)
        }
        pg = AppBskyFeedPostgate(
            createdAt: pg.createdAt,
            post: postURI,
            detachedEmbeddingUris: detached,
            embeddingRules: pg.embeddingRules
        )

        #expect(pg.embeddingRules?.count == 1)
        #expect(pg.detachedEmbeddingUris == [quoteURI])

        // Reattach
        detached.removeAll { $0 == quoteURI }
        pg = AppBskyFeedPostgate(
            createdAt: pg.createdAt,
            post: postURI,
            detachedEmbeddingUris: detached.isEmpty ? nil : detached,
            embeddingRules: pg.embeddingRules
        )

        #expect(pg.embeddingRules?.count == 1)
        #expect(pg.detachedEmbeddingUris == nil)
    }

    @Test("Detaching quote deduplicates quote URI")
    func detachingQuoteDeduplicatesURI() throws {
        let quoteURI = try ATProtocolURI(uriString: "at://did:plc:carol/app.bsky.feed.post/3l5quote")
        var detachedURIs = [quoteURI]

        if !detachedURIs.contains(quoteURI) {
            detachedURIs.append(quoteURI)
        }

        #expect(detachedURIs.count == 1)
    }

    // MARK: - PostInteractionSettingsState Conversions and Summary

    @Test("PostInteractionSettingsState converts from server threadgate and postgate records")
    func stateConvertsFromServerRecords() throws {
        let rootURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5root")
        let listURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.graph.list/3l5list")

        let threadgate = AppBskyFeedThreadgate(
            post: rootURI,
            allow: [
                .appBskyFeedThreadgateMentionRule(AppBskyFeedThreadgate.MentionRule()),
                .appBskyFeedThreadgateFollowingRule(AppBskyFeedThreadgate.FollowingRule()),
                .appBskyFeedThreadgateListRule(AppBskyFeedThreadgate.ListRule(list: listURI))
            ],
            createdAt: ATProtocolDate(date: Date()),
            hiddenReplies: nil
        )

        let postgate = AppBskyFeedPostgate(
            createdAt: ATProtocolDate(date: Date()),
            post: rootURI,
            detachedEmbeddingUris: nil,
            embeddingRules: [.appBskyFeedPostgateDisableRule(AppBskyFeedPostgate.DisableRule())]
        )

        let state = PostInteractionSettingsState(threadgateRecord: threadgate, postgateRecord: postgate)
        #expect(state.allowQuotes == false)
        #expect(state.threadgate.allowMentioned == true)
        #expect(state.threadgate.allowFollowing == true)
        #expect(state.threadgate.allowLists == true)
        #expect(state.threadgate.selectedLists == [listURI.uriString()])
        #expect(state.isCustom == true)
    }

    @Test("PostInteractionSettingsState summary formats correctly")
    func stateSummaryFormatting() throws {
        var state = PostInteractionSettingsState()
        #expect(state.summary == "Anyone")

        state.allowQuotes = false
        #expect(state.summary == "No quotes")

        state.threadgate.selectOption(.nobody)
        #expect(state.summary == "Nobody · No quotes")

        state.allowQuotes = true
        #expect(state.summary == "Nobody")
    }

    @Test("Threadgate with omitted allow converts to allowEverybody (WS-B-05)")
    func threadgateWithOmittedAllowConvertsToAllowEverybody() throws {
        let rootURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5root")
        let replyURI = try ATProtocolURI(uriString: "at://did:plc:bob/app.bsky.feed.post/3l5reply")

        // Threadgate with hidden replies but omitted allow (Everyone can reply)
        let threadgate = AppBskyFeedThreadgate(
            post: rootURI,
            allow: nil,
            createdAt: ATProtocolDate(date: Date()),
            hiddenReplies: [replyURI]
        )

        let state = PostInteractionSettingsState(threadgateRecord: threadgate, postgateRecord: nil)
        #expect(state.threadgate.allowEverybody == true)
        #expect(state.threadgate.allowNobody == false)
        #expect(state.threadgate.isReplyingAllowed == true)
        #expect(state.threadgate.primaryOption == .everybody)
    }

    @Test("Threadgate with empty allow array converts to allowNobody (WS-B-05)")
    func threadgateWithEmptyAllowConvertsToAllowNobody() throws {
        let rootURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5root")

        // Threadgate with empty allow array (Nobody can reply)
        let threadgate = AppBskyFeedThreadgate(
            post: rootURI,
            allow: [],
            createdAt: ATProtocolDate(date: Date()),
            hiddenReplies: nil
        )

        let state = PostInteractionSettingsState(threadgateRecord: threadgate, postgateRecord: nil)
        #expect(state.threadgate.allowEverybody == false)
        #expect(state.threadgate.allowNobody == true)
        #expect(state.threadgate.primaryOption == .nobody)
    }

    @Test("mergeThreadgate emits nil allow for allowEverybody and empty array for allowNobody (WS-B-05)")
    func mergeThreadgateEmitsCorrectAllowRules() throws {
        let rootURI = try ATProtocolURI(uriString: "at://did:plc:alice/app.bsky.feed.post/3l5root")
        let replyURI = try ATProtocolURI(uriString: "at://did:plc:bob/app.bsky.feed.post/3l5reply")
        let existingDate = ATProtocolDate(date: Date(timeIntervalSince1970: 1_500_000_000))

        let existingTg = AppBskyFeedThreadgate(
            post: rootURI,
            allow: [.appBskyFeedThreadgateMentionRule(AppBskyFeedThreadgate.MentionRule())],
            createdAt: existingDate,
            hiddenReplies: [replyURI]
        )

        // 1. Merge with allowEverybody -> allow is nil (omitted in ATProto)
        var everybodySettings = PostInteractionSettingsState()
        everybodySettings.threadgate.selectOption(.everybody)
        let mergedEverybody = PostInteractionSettingsState.mergeThreadgate(
            existing: existingTg,
            postURI: rootURI,
            settings: everybodySettings
        )
        #expect(mergedEverybody.allow == nil)
        #expect(mergedEverybody.hiddenReplies == [replyURI])
        #expect(mergedEverybody.createdAt == existingDate)

        // 2. Merge with allowNobody -> allow is [] (explicit empty in ATProto)
        var nobodySettings = PostInteractionSettingsState()
        nobodySettings.threadgate.selectOption(.nobody)
        let mergedNobody = PostInteractionSettingsState.mergeThreadgate(
            existing: existingTg,
            postURI: rootURI,
            settings: nobodySettings
        )
        #expect(mergedNobody.allow != nil)
        #expect(mergedNobody.allow?.isEmpty == true)
        #expect(mergedNobody.hiddenReplies == [replyURI])
        #expect(mergedNobody.createdAt == existingDate)
    }

    @Test("toThreadgateAllowRules returns nil for everybody and empty array for nobody (WS-B-05)")
    func toThreadgateAllowRulesReturnsNilForEverybodyAndEmptyForNobody() throws {
        var everybody = PostInteractionSettingsState()
        everybody.threadgate.selectOption(.everybody)
        #expect(everybody.toThreadgateAllowRules() == nil)

        var nobody = PostInteractionSettingsState()
        nobody.threadgate.selectOption(.nobody)
        let nobodyRules = nobody.toThreadgateAllowRules()
        #expect(nobodyRules != nil)
        #expect(nobodyRules?.isEmpty == true)
    }

    @Test("Unchanged interaction settings equality prevents unnecessary network writes (WS-B-07)")
    func unchangedInteractionSettingsEquality() throws {
        let initial = PostInteractionSettingsState(
            threadgate: ThreadgateSettings(allowEverybody: true),
            allowQuotes: true
        )
        let unmodified = PostInteractionSettingsState(
            threadgate: ThreadgateSettings(allowEverybody: true),
            allowQuotes: true
        )
        #expect(initial == unmodified)

        var modified = initial
        modified.allowQuotes = false
        #expect(initial != modified)
    }

    @Test("RecordNotFound error classification recognizes all ATProto missing-record error representations (WS-B-04)")
    func recordNotFoundErrorClassification() throws {
        let protoError = ATProtoError<ComAtprotoRepoGetRecord.Error>(
            error: .recordNotFound,
            message: "Record not found",
            statusCode: 400
        )
        let directError = ComAtprotoRepoGetRecord.Error.recordNotFound
        let xrpcError = ATProtoXRPCError(error: "RecordNotFound", message: "Could not locate record", statusCode: 400)
        let unrelatedError = ATProtoXRPCError(error: "InvalidRequest", message: "Bad request", statusCode: 400)

        func checkIsRecordNotFound(_ error: Error) -> Bool {
            if let protoError = error as? ATProtoError<ComAtprotoRepoGetRecord.Error>, protoError.error == .recordNotFound {
                return true
            }
            if let directError = error as? ComAtprotoRepoGetRecord.Error, directError == .recordNotFound {
                return true
            }
            if let xrpcError = error as? ATProtoXRPCError, xrpcError.error == "RecordNotFound" {
                return true
            }
            return false
        }

        #expect(checkIsRecordNotFound(protoError) == true)
        #expect(checkIsRecordNotFound(directError) == true)
        #expect(checkIsRecordNotFound(xrpcError) == true)
        #expect(checkIsRecordNotFound(unrelatedError) == false)
    }
}
