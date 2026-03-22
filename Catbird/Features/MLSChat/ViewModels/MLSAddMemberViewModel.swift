import CatbirdMLSCore
import Foundation
import Observation
import OSLog
import Petrel

/// ViewModel for searching and adding members to an MLS group conversation
@Observable
final class MLSAddMemberViewModel {
  // MARK: - Properties

  private(set) var searchResults: [MLSParticipantViewModel] = []
  private(set) var participantOptInStatus: [String: Bool] = [:]
  private(set) var isSearching = false
  private(set) var isAddingMember = false
  private(set) var error: Error?
  private(set) var didAddMember = false

  var searchQuery = "" {
    didSet {
      guard searchQuery != oldValue else { return }
      searchTask?.cancel()
      searchTask = Task { @MainActor in
        do {
          try await Task.sleep(for: .milliseconds(300))
          await search()
        } catch {
          // Task cancelled
        }
      }
    }
  }

  private let conversationId: String
  private let conversationManager: MLSConversationManager
  private let existingMemberDIDs: Set<String>
  private var searchTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSAddMember")

  // MARK: - Init

  init(
    conversationId: String,
    conversationManager: MLSConversationManager,
    existingMemberDIDs: Set<String>
  ) {
    self.conversationId = conversationId
    self.conversationManager = conversationManager
    self.existingMemberDIDs = existingMemberDIDs
  }

  // MARK: - Search

  @MainActor
  private func search() async {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchResults = []
      participantOptInStatus = [:]
      return
    }

    isSearching = true
    defer { isSearching = false }

    do {
      let input = AppBskyActorSearchActorsTypeahead.Parameters(
        term: query,
        limit: 20
      )

      let (_, response) = try await conversationManager.apiClient.client
        .app.bsky.actor.searchActorsTypeahead(input: input)

      guard let actors = response?.actors else {
        searchResults = []
        return
      }

      let results = actors
        .filter { !existingMemberDIDs.contains($0.did.didString()) }
        .map { actor in
          MLSParticipantViewModel(
            id: actor.did.didString(),
            handle: actor.handle.description,
            displayName: actor.displayName,
            avatarURL: actor.finalAvatarURL()
          )
        }

      // Check MLS opt-in status
      let dids = results.compactMap { try? DID(didString: $0.id) }
      if !dids.isEmpty {
        do {
          let statuses = try await conversationManager.apiClient.getOptInStatus(dids: dids)
          for status in statuses {
            participantOptInStatus[status.did.didString()] = status.optedIn
          }
        } catch {
          logger.warning("Failed to check MLS opt-in status: \(error.localizedDescription)")
        }
      }

      searchResults = results
    } catch {
      logger.error("Search failed: \(error.localizedDescription)")
      searchResults = []
    }
  }

  // MARK: - Add Member

  @MainActor
  func addMember(_ did: String) async {
    isAddingMember = true
    error = nil
    defer { isAddingMember = false }

    do {
      try await Task.detached(priority: .userInitiated) {
        try await self.conversationManager.addMembers(
          convoId: self.conversationId,
          memberDids: [did]
        )
      }.value
      didAddMember = true
      logger.info("Successfully added member to conversation")
    } catch {
      self.error = error
      logger.error("Failed to add member: \(error.localizedDescription)")
    }
  }
}
