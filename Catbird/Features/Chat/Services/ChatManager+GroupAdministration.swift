import Foundation
import OSLog
import Petrel

/// Errors from group administration calls, surfaced inline in the settings
/// sheet — the global chat error alert can't present over that sheet.
enum GroupAdminError: LocalizedError {
  case noClient
  case network(code: Int)
  case emptyResponse
  case invalidDID
  case underlying(Error)

  var errorDescription: String? {
    switch self {
    case .noClient:
      return "You're not signed in. Please try again after signing in."
    case .network(let code):
      return "The request failed (HTTP \(code)). Please try again."
    case .emptyResponse:
      return "The server returned no data. Please try again."
    case .invalidDID:
      return "One of the selected accounts couldn't be resolved."
    case .underlying(let error):
      return error.localizedDescription
    }
  }
}

private let groupAdminLogger = Logger(subsystem: "blue.catbird", category: "ChatGroupAdmin")

// MARK: - Group Administration (chat.bsky.group.*)

extension ChatManager {
  /// Replaces (or inserts) the cached conversation with a server-returned copy
  /// so open views observing `conversations` refresh immediately.
  @MainActor
  private func applyUpdatedConversation(_ convo: ChatBskyConvoDefs.ConvoView) {
    if let index = conversations.firstIndex(where: { $0.id == convo.id }) {
      conversations[index] = convo
    } else {
      conversations.insert(convo, at: 0)
    }
    updateConversationsByStatus()
  }

  /// Re-fetches a conversation and updates the cache. Used after mutations
  /// whose responses don't carry the full updated ConvoView (join links).
  @MainActor
  func refreshConversation(convoId: String) async {
    if let convo = await getConversation(convoId: convoId) {
      applyUpdatedConversation(convo)
    }
  }

  @MainActor
  func renameGroup(convoId: String, name: String) async throws {
    guard let client else { throw GroupAdminError.noClient }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    do {
      let input = ChatBskyGroupEditGroup.Input(convoId: convoId, name: trimmed)
      let (responseCode, response) = try await client.chat.bsky.group.editGroup(input: input)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      guard let convo = response?.convo else { throw GroupAdminError.emptyResponse }
      applyUpdatedConversation(convo)
      groupAdminLogger.debug("Renamed group \(convoId)")
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("renameGroup(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  @MainActor
  func addGroupMembers(convoId: String, memberDIDs: [String]) async throws {
    guard let client else { throw GroupAdminError.noClient }
    guard !memberDIDs.isEmpty else { return }

    let members: [DID]
    do {
      members = try memberDIDs.map { try DID(didString: $0) }
    } catch {
      throw GroupAdminError.invalidDID
    }

    do {
      let input = ChatBskyGroupAddMembers.Input(convoId: convoId, members: members)
      let (responseCode, response) = try await client.chat.bsky.group.addMembers(input: input)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      guard let convo = response?.convo else { throw GroupAdminError.emptyResponse }
      applyUpdatedConversation(convo)
      groupAdminLogger.debug("Added \(members.count) member(s) to group \(convoId)")
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("addGroupMembers(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  @MainActor
  func removeGroupMember(convoId: String, memberDID: String) async throws {
    guard let client else { throw GroupAdminError.noClient }

    let member: DID
    do {
      member = try DID(didString: memberDID)
    } catch {
      throw GroupAdminError.invalidDID
    }

    do {
      let input = ChatBskyGroupRemoveMembers.Input(convoId: convoId, members: [member])
      let (responseCode, response) = try await client.chat.bsky.group.removeMembers(input: input)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      guard let convo = response?.convo else { throw GroupAdminError.emptyResponse }
      applyUpdatedConversation(convo)
      groupAdminLogger.debug("Removed member from group \(convoId)")
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("removeGroupMember(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  /// Owner-only unlock; the lock direction lives on `lockConversation` in
  /// ChatManager since the leave flow depends on it.
  @MainActor
  func unlockConversation(convoId: String) async throws {
    guard let client else { throw GroupAdminError.noClient }

    do {
      let input = ChatBskyConvoUnlockConvo.Input(convoId: convoId)
      let (responseCode, response) = try await client.chat.bsky.convo.unlockConvo(input: input)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      if let convo = response?.convo {
        applyUpdatedConversation(convo)
      }
      groupAdminLogger.debug("Unlocked group \(convoId)")
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("unlockConversation(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  // MARK: Join Links

  /// Enables the group's join link, creating one on first use. The responses
  /// only carry the JoinLinkView, so the cached convo is re-fetched afterward.
  @MainActor
  func enableJoinLink(convoId: String) async throws -> ChatBskyGroupDefs.JoinLinkView {
    guard let client else { throw GroupAdminError.noClient }

    let hasExistingLink = conversations
      .first(where: { $0.id == convoId })?
      .groupMetadata?.joinLink != nil

    do {
      let joinLink: ChatBskyGroupDefs.JoinLinkView
      if hasExistingLink {
        let input = ChatBskyGroupEnableJoinLink.Input(convoId: convoId)
        let (responseCode, response) = try await client.chat.bsky.group.enableJoinLink(input: input)
        guard responseCode >= 200 && responseCode < 300 else {
          throw GroupAdminError.network(code: responseCode)
        }
        guard let link = response?.joinLink else { throw GroupAdminError.emptyResponse }
        joinLink = link
      } else {
        let input = ChatBskyGroupCreateJoinLink.Input(
          convoId: convoId, requireApproval: false, joinRule: .anyone)
        let (responseCode, response) = try await client.chat.bsky.group.createJoinLink(input: input)
        guard responseCode >= 200 && responseCode < 300 else {
          throw GroupAdminError.network(code: responseCode)
        }
        guard let link = response?.joinLink else { throw GroupAdminError.emptyResponse }
        joinLink = link
      }
      await refreshConversation(convoId: convoId)
      groupAdminLogger.debug("Enabled join link for group \(convoId)")
      return joinLink
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("enableJoinLink(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  @MainActor
  func disableJoinLink(convoId: String) async throws {
    guard let client else { throw GroupAdminError.noClient }

    do {
      let input = ChatBskyGroupDisableJoinLink.Input(convoId: convoId)
      let (responseCode, _) = try await client.chat.bsky.group.disableJoinLink(input: input)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      await refreshConversation(convoId: convoId)
      groupAdminLogger.debug("Disabled join link for group \(convoId)")
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("disableJoinLink(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  // MARK: Join Requests

  @MainActor
  func listJoinRequests(convoId: String) async throws -> [ChatBskyGroupDefs.JoinRequestView] {
    guard let client else { throw GroupAdminError.noClient }

    do {
      let params = ChatBskyGroupListJoinRequests.Parameters(convoId: convoId, limit: 100, cursor: nil)
      let (responseCode, response) = try await client.chat.bsky.group.listJoinRequests(input: params)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      guard let requests = response?.requests else { throw GroupAdminError.emptyResponse }
      return requests
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("listJoinRequests(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  @MainActor
  func approveJoinRequest(convoId: String, memberDID: String) async throws {
    guard let client else { throw GroupAdminError.noClient }

    let member: DID
    do {
      member = try DID(didString: memberDID)
    } catch {
      throw GroupAdminError.invalidDID
    }

    do {
      let input = ChatBskyGroupApproveJoinRequest.Input(convoId: convoId, member: member)
      let (responseCode, response) = try await client.chat.bsky.group.approveJoinRequest(input: input)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      if let convo = response?.convo {
        applyUpdatedConversation(convo)
      }
      groupAdminLogger.debug("Approved join request for group \(convoId)")
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("approveJoinRequest(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  @MainActor
  func rejectJoinRequest(convoId: String, memberDID: String) async throws {
    guard let client else { throw GroupAdminError.noClient }

    let member: DID
    do {
      member = try DID(didString: memberDID)
    } catch {
      throw GroupAdminError.invalidDID
    }

    do {
      let input = ChatBskyGroupRejectJoinRequest.Input(convoId: convoId, member: member)
      let (responseCode, _) = try await client.chat.bsky.group.rejectJoinRequest(input: input)
      guard responseCode >= 200 && responseCode < 300 else {
        throw GroupAdminError.network(code: responseCode)
      }
      await refreshConversation(convoId: convoId)
      groupAdminLogger.debug("Rejected join request for group \(convoId)")
    } catch let error as GroupAdminError {
      throw error
    } catch {
      groupAdminLogger.error("rejectJoinRequest(\(convoId)) failed: \(error.localizedDescription)")
      throw GroupAdminError.underlying(error)
    }
  }

  /// Best-effort: clears the unread badge on the owner's join request list.
  @MainActor
  func markJoinRequestsRead(convoId: String) async {
    guard let client else { return }
    do {
      let input = ChatBskyGroupUpdateJoinRequestsRead.Input(convoId: convoId)
      let (responseCode, _) = try await client.chat.bsky.group.updateJoinRequestsRead(input: input)
      if responseCode >= 200 && responseCode < 300 {
        await refreshConversation(convoId: convoId)
      }
    } catch {
      groupAdminLogger.warning("markJoinRequestsRead(\(convoId)) failed: \(error.localizedDescription)")
    }
  }
}
