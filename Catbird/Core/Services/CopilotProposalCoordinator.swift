import Foundation
import Petrel

enum CopilotProposalError: LocalizedError, Equatable, Sendable {
    case unsupported
    case failed
    case accountChanged
    case staleTarget
    case requiresDedicatedFlow

    var errorDescription: String? {
        switch self {
        case .unsupported:
            String(localized: "That proposed action is not enabled in Catbird yet.", comment: "Error when Ask Catbird proposes an unsupported action.")
        case .failed:
            String(localized: "Catbird could not complete the confirmed action.", comment: "Error when a confirmed Ask Catbird action fails.")
        case .accountChanged:
            String(localized: "The active account changed since this action was proposed.", comment: "Error when active account changed before confirming an Ask Catbird action.")
        case .staleTarget:
            String(localized: "The target of this action is no longer available in the current context.", comment: "Error when proposed action target changed.")
        case .requiresDedicatedFlow:
            String(localized: "This action requires a dedicated confirmation flow.", comment: "Error when proposed action requires its own sheet.")
        }
    }
}

enum CopilotProposalCoordinator {

    static func proposal(
        action: String,
        payload: String? = nil,
        context: CopilotContext,
        accountDID: String
    ) throws -> CopilotProposal? {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAction.isEmpty else { return nil }

        let trimmedPayload = payload?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmedAction {
        // MARK: Profile Context Actions
        case "followActor":
            guard case .profile(let did, _, _) = context else { return nil }
            return .followActor(actorDID: did)

        case "unfollowActor":
            guard case .profile(let did, _, _) = context else { return nil }
            return .unfollowActor(actorDID: did)

        case "muteActor":
            guard case .profile(let did, _, _) = context else { return nil }
            return .muteActor(actorDID: did)

        case "unmuteActor":
            guard case .profile(let did, _, _) = context else { return nil }
            return .unmuteActor(actorDID: did)

        case "blockActor":
            guard case .profile(let did, _, _) = context else { return nil }
            return .blockActor(actorDID: did)

        case "unblockActor":
            guard case .profile(let did, _, _) = context else { return nil }
            return .unblockActor(actorDID: did)

        case "reportActor":
            guard case .profile(let did, _, _) = context else { return nil }
            return .reportActor(actorDID: did)

        case "addActorToList":
            guard case .profile(let did, _, _) = context else { return nil }
            return .addActorToList(actorDID: did)

        // MARK: Post Context Actions
        case "likePost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .likePost(uri: uri, cid: cid)

        case "unlikePost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .unlikePost(uri: uri, cid: cid)

        case "repostPost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .repostPost(uri: uri, cid: cid)

        case "unrepostPost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .unrepostPost(uri: uri, cid: cid)

        case "bookmarkPost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .bookmarkPost(uri: uri, cid: cid)

        case "unbookmarkPost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .unbookmarkPost(uri: uri, cid: cid)

        case "hidePost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .hidePost(uri: uri, cid: cid)

        case "unhidePost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .unhidePost(uri: uri, cid: cid)

        case "prepareReply":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty,
                  let text = trimmedPayload, !text.isEmpty else { return nil }
            return .prepareReply(uri: uri, cid: cid, text: text)

        case "prepareQuote":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty,
                  let text = trimmedPayload, !text.isEmpty else { return nil }
            return .prepareQuote(uri: uri, cid: cid, text: text)

        case "reportPost":
            guard case .post(let uri, let cid?, _, _, _) = context, !cid.isEmpty else { return nil }
            return .reportPost(uri: uri, cid: cid)

        case "deletePost":
            guard case .post(let uri, let cid?, let authorDID, _, _) = context,
                  !cid.isEmpty,
                  authorDID == accountDID else { return nil }
            return .deletePost(uri: uri, cid: cid)
        // MARK: Thread Context Actions
        case "muteThread":
            guard case .thread(let anchorURI) = context else { return nil }
            return .muteThread(uri: anchorURI)

        case "unmuteThread":
            guard case .thread(let anchorURI) = context else { return nil }
            return .unmuteThread(uri: anchorURI)

        // MARK: Feed Context Actions
        case "saveFeed":
            guard case .feed(let uri?, _) = context else { return nil }
            return .saveFeed(uri: uri)

        case "unsaveFeed":
            guard case .feed(let uri?, _) = context else { return nil }
            return .unsaveFeed(uri: uri)

        case "pinFeed":
            guard case .feed(let uri?, _) = context else { return nil }
            return .pinFeed(uri: uri)

        case "unpinFeed":
            guard case .feed(let uri?, _) = context else { return nil }
            return .unpinFeed(uri: uri)

        // MARK: Smart Filter and Post Draft Actions
        case "createSmartFilter":
            guard let rawText = trimmedPayload, !rawText.isEmpty else { return nil }
            let targetActorDID: String
            if case .profile(let did, _, _) = context {
                targetActorDID = did
            } else {
                targetActorDID = accountDID
            }
            guard let rule = try? SmartFilterRuleCompiler.compileDeterministically(
                rawText,
                accountDID: accountDID,
                targetActorDID: targetActorDID
            ) else {
                return nil
            }
            return .createSmartFilter(rule)

        case "enableSmartFilter", "setSmartFilterEnabled":
            guard case .smartFilter(let id, _) = context else { return nil }
            return .setSmartFilterEnabled(id: id, enabled: true)

        case "disableSmartFilter":
            guard case .smartFilter(let id, _) = context else { return nil }
            return .setSmartFilterEnabled(id: id, enabled: false)
        case "preparePostDraft":
            guard let text = trimmedPayload, !text.isEmpty else { return nil }
            return .preparePostDraft(text: text)

        default:
            return nil
        }
    }

    static func validate(
        _ proposal: CopilotProposal,
        context: CopilotContext,
        expectedAccountDID: String,
        currentAccountDID: String
    ) throws {
        guard expectedAccountDID == currentAccountDID else {
            throw CopilotProposalError.accountChanged
        }

        switch proposal {
        case .followActor(let targetDID),
             .unfollowActor(let targetDID),
             .muteActor(let targetDID),
             .unmuteActor(let targetDID),
             .blockActor(let targetDID),
             .unblockActor(let targetDID),
             .reportActor(let targetDID),
             .addActorToList(let targetDID):
            guard case .profile(let did, _, _) = context, did == targetDID else {
                throw CopilotProposalError.staleTarget
            }

        case .likePost(let uri, let cid),
             .unlikePost(let uri, let cid),
             .repostPost(let uri, let cid),
             .unrepostPost(let uri, let cid),
             .bookmarkPost(let uri, let cid),
             .unbookmarkPost(let uri, let cid),
             .hidePost(let uri, let cid),
             .unhidePost(let uri, let cid),
             .prepareReply(let uri, let cid, _),
             .prepareQuote(let uri, let cid, _),
             .reportPost(let uri, let cid),
             .deletePost(let uri, let cid):
            guard case .post(let postUri, let postCid, let authorDID, _, _) = context,
                  uri == postUri, cid == postCid else {
                throw CopilotProposalError.staleTarget
            }
            if case .deletePost = proposal {
                guard authorDID == expectedAccountDID else {
                    throw CopilotProposalError.staleTarget
                }
            }

        case .muteThread(let uri),
             .unmuteThread(let uri):
            guard case .thread(let anchorURI) = context, uri == anchorURI else {
                throw CopilotProposalError.staleTarget
            }

        case .saveFeed(let uri),
             .unsaveFeed(let uri),
             .pinFeed(let uri),
             .unpinFeed(let uri):
            guard case .feed(let feedUri?, _) = context, uri == feedUri else {
                throw CopilotProposalError.staleTarget
            }

        case .createSmartFilter(let rule):
            guard IntelligenceFeatureFlags.smartFilterStructuralRulesEnabled else {
                throw CopilotProposalError.unsupported
            }
            guard rule.accountDID == expectedAccountDID else {
                throw CopilotProposalError.staleTarget
            }
            if case .profile(let did, _, _) = context {
                guard rule.targetActorDID == did else {
                    throw CopilotProposalError.staleTarget
                }
            } else {
                guard rule.targetActorDID == expectedAccountDID else {
                    throw CopilotProposalError.staleTarget
                }
            }

        case .setSmartFilterEnabled(let id, _):
            guard IntelligenceFeatureFlags.smartFilterStructuralRulesEnabled else {
                throw CopilotProposalError.unsupported
            }
            guard case .smartFilter(let filterID, _) = context, id == filterID else {
                throw CopilotProposalError.staleTarget
            }
        case .preparePostDraft:
            break
        }
    }

    @MainActor
    static func executeConfirmed(
        _ proposal: CopilotProposal,
        context: CopilotContext,
        expectedAccountDID: String,
        appState: AppState
    ) async throws {
        try validate(
            proposal,
            context: context,
            expectedAccountDID: expectedAccountDID,
            currentAccountDID: appState.userDID
        )

        guard proposal.disposition != .dedicatedFlow else {
            throw CopilotProposalError.requiresDedicatedFlow
        }

        let succeeded: Bool
        switch proposal {
        case .followActor(let did):
            let state = try await appState.graphManager.freshRelationshipState(did: did)
            if state.following {
                succeeded = true
            } else {
                succeeded = try await appState.follow(did: did)
            }
        case .unfollowActor(let did):
            let state = try await appState.graphManager.freshRelationshipState(did: did)
            if !state.following {
                succeeded = true
            } else {
                succeeded = try await appState.unfollow(did: did)
            }
        case .muteActor(let did):
            let state = try await appState.graphManager.freshRelationshipState(did: did)
            if state.muted {
                succeeded = true
            } else {
                succeeded = try await appState.graphManager.mute(did: did)
            }
        case .unmuteActor(let did):
            let state = try await appState.graphManager.freshRelationshipState(did: did)
            if !state.muted {
                succeeded = true
            } else {
                succeeded = try await appState.graphManager.unmute(did: did)
            }
        case .muteThread(let uri):
            guard let parsedURI = try? ATProtocolURI(uriString: uri) else {
                throw CopilotProposalError.failed
            }
            succeeded = try await appState.graphManager.muteThread(threadRootUri: parsedURI)
        case .unmuteThread(let uri):
            guard let parsedURI = try? ATProtocolURI(uriString: uri) else {
                throw CopilotProposalError.failed
            }
            succeeded = try await appState.graphManager.unmuteThread(threadRootUri: parsedURI)
        case .saveFeed(let uri):
            let prefs = try await appState.preferencesManager.getPreferences()
            prefs.addFeed(uri, pinned: false)
            try await appState.preferencesManager.saveAndSyncPreferences(prefs)
            succeeded = true
        case .unsaveFeed(let uri):
            let prefs = try await appState.preferencesManager.getPreferences()
            prefs.removeFeed(uri)
            try await appState.preferencesManager.saveAndSyncPreferences(prefs)
            succeeded = true
        case .pinFeed(let uri):
            let prefs = try await appState.preferencesManager.getPreferences()
            prefs.pinFeed(uri)
            try await appState.preferencesManager.saveAndSyncPreferences(prefs)
            succeeded = true
        case .unpinFeed(let uri):
            let prefs = try await appState.preferencesManager.getPreferences()
            prefs.unpinFeed(uri)
            try await appState.preferencesManager.saveAndSyncPreferences(prefs)
            succeeded = true
        case .createSmartFilter(let rule):
            try await SmartFilterRuleStore.shared.save(rule)
            succeeded = true
        case .setSmartFilterEnabled(let id, let enabled):
            guard var rule = await SmartFilterRuleStore.shared.rules(for: appState.userDID)
                .first(where: { $0.id == id }) else {
                throw CopilotProposalError.failed
            }
            rule.isEnabled = enabled
            try await SmartFilterRuleStore.shared.save(rule)
            succeeded = true
        case .likePost, .unlikePost,
             .repostPost, .unrepostPost,
             .bookmarkPost, .unbookmarkPost,
             .hidePost, .unhidePost:
            throw CopilotProposalError.unsupported
        case .blockActor, .unblockActor,
             .reportActor, .addActorToList,
             .prepareReply, .prepareQuote,
             .reportPost, .deletePost,
             .preparePostDraft:
            throw CopilotProposalError.requiresDedicatedFlow
        }
        guard succeeded else { throw CopilotProposalError.failed }
    }

    static func confirmationText(for proposal: CopilotProposal, context: CopilotContext? = nil) -> String {
        switch proposal {
        case .followActor: String(localized: "Follow this account?", comment: "Ask Catbird action confirmation prompt.")
        case .unfollowActor: String(localized: "Unfollow this account?", comment: "Ask Catbird action confirmation prompt.")
        case .muteActor: String(localized: "Mute this account?", comment: "Ask Catbird action confirmation prompt.")
        case .unmuteActor: String(localized: "Unmute this account?", comment: "Ask Catbird action confirmation prompt.")
        case .blockActor: String(localized: "Block this account?", comment: "Ask Catbird action confirmation prompt.")
        case .unblockActor: String(localized: "Unblock this account?", comment: "Ask Catbird action confirmation prompt.")
        case .reportActor: String(localized: "Report this account?", comment: "Ask Catbird action confirmation prompt.")
        case .addActorToList: String(localized: "Add this account to a list?", comment: "Ask Catbird action confirmation prompt.")
        case .likePost: String(localized: "Like this post?", comment: "Ask Catbird action confirmation prompt.")
        case .unlikePost: String(localized: "Unlike this post?", comment: "Ask Catbird action confirmation prompt.")
        case .repostPost: String(localized: "Repost this post?", comment: "Ask Catbird action confirmation prompt.")
        case .unrepostPost: String(localized: "Remove repost?", comment: "Ask Catbird action confirmation prompt.")
        case .bookmarkPost: String(localized: "Bookmark this post?", comment: "Ask Catbird action confirmation prompt.")
        case .unbookmarkPost: String(localized: "Remove bookmark?", comment: "Ask Catbird action confirmation prompt.")
        case .hidePost: String(localized: "Hide this post?", comment: "Ask Catbird action confirmation prompt.")
        case .unhidePost: String(localized: "Unhide this post?", comment: "Ask Catbird action confirmation prompt.")
        case .prepareReply: String(localized: "Prepare reply?", comment: "Ask Catbird action confirmation prompt.")
        case .prepareQuote: String(localized: "Prepare quote post?", comment: "Ask Catbird action confirmation prompt.")
        case .reportPost: String(localized: "Report this post?", comment: "Ask Catbird action confirmation prompt.")
        case .deletePost: String(localized: "Delete this post?", comment: "Ask Catbird action confirmation prompt.")
        case .muteThread: String(localized: "Mute this thread?", comment: "Ask Catbird action confirmation prompt.")
        case .unmuteThread: String(localized: "Unmute this thread?", comment: "Ask Catbird action confirmation prompt.")
        case .saveFeed: String(localized: "Save this feed?", comment: "Ask Catbird action confirmation prompt.")
        case .unsaveFeed: String(localized: "Remove this saved feed?", comment: "Ask Catbird action confirmation prompt.")
        case .pinFeed: String(localized: "Pin this feed?", comment: "Ask Catbird action confirmation prompt.")
        case .unpinFeed: String(localized: "Unpin this feed?", comment: "Ask Catbird action confirmation prompt.")
        case .createSmartFilter(let rule):
            String(localized: "Save this Smart Filter?\n\(rule.rawText)", comment: "Ask Catbird confirmation prompt to save a Smart Filter — variable is filter rule text.")
        case .setSmartFilterEnabled(let id, let enabled):
            smartFilterConfirmationText(id: id, enabled: enabled, context: context)
        case .preparePostDraft:
            String(localized: "Prepare this text as a draft?", comment: "Ask Catbird action confirmation prompt.")
        }
    }

    private static func smartFilterConfirmationText(
        id: UUID,
        enabled: Bool,
        context: CopilotContext?
    ) -> String {
        if case .smartFilter(let filterID, let name) = context, filterID == id {
            return enabled
                ? String(localized: "Enable Smart Filter '\(name)'?", comment: "Ask Catbird confirmation prompt to enable a named Smart Filter.")
                : String(localized: "Disable Smart Filter '\(name)'?", comment: "Ask Catbird confirmation prompt to disable a named Smart Filter.")
        }
        return enabled
            ? String(localized: "Enable this Smart Filter?", comment: "Ask Catbird confirmation prompt to enable a Smart Filter.")
            : String(localized: "Disable this Smart Filter?", comment: "Ask Catbird confirmation prompt to disable a Smart Filter.")
    }
}
