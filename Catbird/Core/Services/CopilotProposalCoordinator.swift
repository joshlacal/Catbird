import Foundation
import Petrel

enum CopilotProposalError: LocalizedError {
    case unsupported
    case failed

    var errorDescription: String? {
        switch self {
        case .unsupported: "That proposed action is not enabled in Catbird yet."
        case .failed: "Catbird could not complete the confirmed action."
        }
    }
}

enum CopilotProposalCoordinator {
    static func proposal(for prompt: String, context: CopilotContext) -> CopilotProposal? {
        let command = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !command.contains("?") else { return nil }

        switch context {
        case .profile(let did, _, _):
            if command == "follow this person" || command == "follow them" { return .follow(actorDID: did) }
            if command == "unfollow this person" || command == "unfollow them" { return .unfollow(actorDID: did) }
            if command == "mute this person" || command == "mute them" { return .mute(actorDID: did) }
            if command == "unmute this person" || command == "unmute them" { return .unmute(actorDID: did) }
        case .thread(let anchorURI), .post(let anchorURI, _, _):
            if command == "mute this thread" { return .muteThread(uri: anchorURI) }
        case .feed(let uri?, _):
            if command == "save this feed" { return .saveFeed(uri: uri) }
            if command == "unsave this feed" { return .unsaveFeed(uri: uri) }
        default:
            break
        }
        return nil
    }

    @MainActor
    static func executeConfirmed(_ proposal: CopilotProposal, appState: AppState) async throws {
        let succeeded: Bool
        switch proposal {
        case .follow(let did):
            succeeded = try await appState.follow(did: did)
        case .unfollow(let did):
            succeeded = try await appState.unfollow(did: did)
        case .mute(let did):
            succeeded = try await appState.graphManager.mute(did: did)
        case .unmute(let did):
            succeeded = try await appState.graphManager.unmute(did: did)
        case .muteThread(let uri):
            guard let parsedURI = try? ATProtocolURI(uriString: uri) else {
                throw CopilotProposalError.failed
            }
            succeeded = try await appState.graphManager.muteThread(threadRootUri: parsedURI)
        case .createSmartFilter(let rule):
            try await SmartFilterRuleStore.shared.save(rule)
            succeeded = true
        case .toggleSmartFilter(let id, let enabled):
            guard var rule = await SmartFilterRuleStore.shared.rules(for: appState.userDID)
                .first(where: { $0.id == id }) else { throw CopilotProposalError.failed }
            rule.isEnabled = enabled
            try await SmartFilterRuleStore.shared.save(rule)
            succeeded = true
        case .saveFeed, .unsaveFeed, .preparePostDraft:
            throw CopilotProposalError.unsupported
        }
        guard succeeded else { throw CopilotProposalError.failed }
    }

    static func confirmationText(for proposal: CopilotProposal) -> String {
        switch proposal {
        case .follow: "Follow this account?"
        case .unfollow: "Unfollow this account?"
        case .mute: "Mute this account?"
        case .unmute: "Unmute this account?"
        case .muteThread: "Mute this thread?"
        case .saveFeed: "Save this feed?"
        case .unsaveFeed: "Remove this saved feed?"
        case .createSmartFilter(let rule): "Save this Smart Filter?\n\(rule.rawText)"
        case .toggleSmartFilter(_, let enabled): enabled ? "Enable this Smart Filter?" : "Disable this Smart Filter?"
        case .preparePostDraft: "Prepare this text as a draft?"
        }
    }
}
