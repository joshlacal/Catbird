import Foundation
import OSLog
import Petrel
import SwiftUI

enum ListError: Error, LocalizedError {
  case clientNotInitialized
  case invalidResponse
  case networkError(Error)
  case listNotFound
  case permissionDenied
  case memberAlreadyAdded
  case memberNotInList
  case unknown(Error)

  var errorDescription: String? {
    switch self {
    case .clientNotInitialized:
      return "ATProto client not initialized"
    case .invalidResponse:
      return "Invalid response from server"
    case .networkError(let error):
      return "Network error: \(error.localizedDescription)"
    case .listNotFound:
      return "List not found"
    case .permissionDenied:
      return "Permission denied"
    case .memberAlreadyAdded:
      return "User is already a member of this list"
    case .memberNotInList:
      return "User is not a member of this list"
    case .unknown(let error):
      return "Unknown error: \(error.localizedDescription)"
    }
  }
}

/// Manages list operations including creation, editing, member management, and discovery
@Observable
final class ListManager {
  // MARK: - Properties
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ListManager")
  private weak var client: ATProtoClient?
  private weak var appState: AppState?
  
  // Current state
  enum State: Equatable {
    case initializing
    case ready
    case loading
    case error(String)
    
    static func == (lhs: State, rhs: State) -> Bool {
      switch (lhs, rhs) {
      case (.initializing, .initializing): return true
      case (.ready, .ready): return true
      case (.loading, .loading): return true
      case (.error(let lhs), .error(let rhs)): return lhs == rhs
      default: return false
      }
    }
  }
  
  private(set) var state: State = .initializing
  
  // MARK: - Cache Properties
  
  // Cache of user's created lists
  @MainActor private(set) var userLists: [AppBskyGraphDefs.ListView] = []
  
  // Cache of list members by list URI
  @MainActor private(set) var listMembers: [String: [AppBskyActorDefs.ProfileView]] = [:]
  
  // Cache of list details by URI
  @MainActor private(set) var listDetails: [String: AppBskyGraphDefs.ListView] = [:]
  
  // Cache of user's list memberships (which lists they're in)
  @MainActor private(set) var userMemberships: Set<String> = []
  
  // Cache timestamps for staleness detection
  @MainActor private var lastUserListsUpdate: Date?
  @MainActor private var lastMembershipUpdate: Date?
  @MainActor private var listMemberUpdateTimes: [String: Date] = [:]
  @MainActor private var listDetailUpdateTimes: [String: Date] = [:]
  
  // Cache expiration time (15 minutes for lists, 5 minutes for members)
  private let listCacheExpirationTime: TimeInterval = 900
  private let memberCacheExpirationTime: TimeInterval = 300
  
  // Track operations in progress to prevent duplicates
  private var inProgressOperations: Set<String> = []
  
  // MARK: - Initialization
  
  init(client: ATProtoClient? = nil, appState: AppState? = nil) {
    self.client = client
    self.appState = appState
    self.state = client != nil ? .ready : .initializing
    logger.debug("ListManager initialized")
  }
  
  /// Update client reference when it changes
  func updateClient(_ client: ATProtoClient?) {
    self.client = client
    
    if client == nil {
      logger.info("Client reset - clearing all list caches")
      Task { @MainActor in
        clearAllCaches()
      }
      state = .initializing
    } else {
      state = .ready
    }
  }
  
  /// Update app state reference
  func updateAppState(_ appState: AppState?) {
    self.appState = appState
  }
  
  // MARK: - Cache Management
  
  /// Clear all cached data
  @MainActor
  private func clearAllCaches() {
    userLists.removeAll()
    listMembers.removeAll()
    listDetails.removeAll()
    userMemberships.removeAll()
    lastUserListsUpdate = nil
    lastMembershipUpdate = nil
    listMemberUpdateTimes.removeAll()
    listDetailUpdateTimes.removeAll()
  }
  
  /// Check if cache is stale for a given type
  @MainActor
  private func isCacheStale(for cacheType: CacheType, listURI: String? = nil) -> Bool {
    let lastUpdate: Date?
    let expirationTime: TimeInterval
    
    switch cacheType {
    case .userLists:
      lastUpdate = lastUserListsUpdate
      expirationTime = listCacheExpirationTime
    case .listMembers:
      guard let listURI = listURI else { return true }
      lastUpdate = listMemberUpdateTimes[listURI]
      expirationTime = memberCacheExpirationTime
    case .listDetails:
      guard let listURI = listURI else { return true }
      lastUpdate = listDetailUpdateTimes[listURI]
      expirationTime = listCacheExpirationTime
    case .userMemberships:
      lastUpdate = lastMembershipUpdate
      expirationTime = listCacheExpirationTime
    }
    
    guard let lastUpdate = lastUpdate else { return true }
    return Date().timeIntervalSince(lastUpdate) > expirationTime
  }
  
  enum CacheType {
    case userLists
    case listMembers
    case listDetails
    case userMemberships
  }
  
  // MARK: - Core List Operations
  
  /// Create a new list
  func createList(
    name: String,
    description: String?,
    purpose: AppBskyGraphDefs.ListPurpose,
    avatar: Data? = nil
  ) async throws -> AppBskyGraphDefs.ListView {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    let operationId = "create-list-\(UUID().uuidString)"
    defer { inProgressOperations.remove(operationId) }
    
    if inProgressOperations.contains(operationId) {
      throw ListError.unknown(NSError(domain: "ListManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation already in progress"]))
    }
    inProgressOperations.insert(operationId)
    
    logger.info("Creating list: \(name)")
    
    do {
      // First upload avatar if provided
      var avatarBlob: Blob?
      if let avatar = avatar {
        let (_, uploadData) = try await client.com.atproto.repo.uploadBlob(
          data: avatar,
          mimeType: "image/jpeg"
        )
        avatarBlob = uploadData?.blob
      }
      
      // Create the list record
      let listRecord = AppBskyGraphList(
        purpose: purpose,
        name: name,
        description: description,
        descriptionFacets: nil,
        avatar: avatarBlob,
        labels: nil,
        createdAt: ATProtocolDate(date: Date())
      )
      
      // Create the record in the repository
      let (responseCode, createData) = try await client.com.atproto.repo.createRecord(
        input: .init(
          repo: try ATIdentifier(string: appState?.userDID ?? ""),
          collection: try NSID(nsidString: "app.bsky.graph.list"),
          rkey: nil,
          validate: true,
          record: ATProtocolValueContainer.knownType(listRecord),
          swapCommit: nil
        )
      )
      
      guard responseCode == 200, let createData = createData else {
        throw ListError.invalidResponse
      }
      
      // Get the created list details
      let listView = try await getListDetails(createData.uri.description)
      
      // Update cache
      await MainActor.run {
        userLists.insert(listView, at: 0)
        listDetails[listView.uri.description] = listView
        listDetailUpdateTimes[listView.uri.description] = Date()
        lastUserListsUpdate = Date()
      }
      
      logger.info("Successfully created list: \(name)")
      return listView
      
    } catch {
      logger.error("Failed to create list: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  /// Update an existing list
  func updateList(
    listURI: String,
    name: String?,
    description: String?,
    avatar: Data?
  ) async throws -> AppBskyGraphDefs.ListView {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    logger.info("Updating list: \(listURI)")
    
    do {
      // Get current list record first
        let uri = try ATProtocolURI(uriString: listURI)
      let (responseCode, recordData) = try await client.com.atproto.repo.getRecord(
        input: .init(
          repo: try ATIdentifier(string: uri.authority),
          collection: try NSID(nsidString: uri.collection ?? ""),
          rkey: try RecordKey(keyString: uri.recordKey ?? ""),
          cid: nil
        )
      )
      
      guard responseCode == 200, let recordData = recordData else {
        throw ListError.listNotFound
      }
      
      // Parse current record
        guard case let .knownType(value) = recordData.value else {
        throw ListError.invalidResponse
      }
        
        guard let currentList = value as? AppBskyGraphList else {
        throw ListError.invalidResponse
      }
      
      // Upload new avatar if provided
      var avatarBlob: Blob? = currentList.avatar
      if let avatar = avatar {
        let (_, uploadData) = try await client.com.atproto.repo.uploadBlob(
          data: avatar,
          mimeType: "image/jpeg"
        )
        avatarBlob = uploadData?.blob
      }
      
      // Create updated record
      let updatedRecord = AppBskyGraphList(
        purpose: currentList.purpose,
        name: name ?? currentList.name,
        description: description ?? currentList.description,
        descriptionFacets: currentList.descriptionFacets,
        avatar: avatarBlob,
        labels: currentList.labels,
        createdAt: currentList.createdAt
      )
      
      // Update the record
      let (updateResponseCode, _) = try await client.com.atproto.repo.putRecord(
        input: .init(
          repo: try ATIdentifier(string: uri.authority),
          collection: try NSID(nsidString: uri.collection ?? ""),
          rkey: try RecordKey(keyString: uri.recordKey ?? ""),
          validate: true,
          record: ATProtocolValueContainer.knownType(updatedRecord),
          swapRecord: recordData.cid
        )
      )
      
      guard updateResponseCode == 200 else {
        throw ListError.invalidResponse
      }
      
      // Get updated list details
      let updatedListView = try await getListDetails(listURI)
      
      // Update cache
      await MainActor.run {
        listDetails[listURI] = updatedListView
        listDetailUpdateTimes[listURI] = Date()
        
        // Update in userLists if present
        if let index = userLists.firstIndex(where: { $0.uri.description == listURI }) {
          userLists[index] = updatedListView
        }
      }
      
      logger.info("Successfully updated list: \(listURI)")
      return updatedListView
      
    } catch {
      logger.error("Failed to update list: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  /// Delete a list
  func deleteList(_ listURI: String) async throws {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    logger.info("Deleting list: \(listURI)")
    
    do {
      let uri = try ATProtocolURI(uriString: listURI)
      
      let (responseCode, _) = try await client.com.atproto.repo.deleteRecord(
        input: .init(
          repo: try ATIdentifier(string: uri.authority),
          collection: try NSID(nsidString: uri.collection ?? ""),
          rkey: try RecordKey(keyString: uri.recordKey ?? ""),
          swapRecord: nil,
          swapCommit: nil
        )
      )
      
      guard responseCode == 200 else {
        throw ListError.invalidResponse
      }
      
      // Update cache
      await MainActor.run {
        userLists.removeAll { $0.uri.description == listURI }
        listDetails.removeValue(forKey: listURI)
        listMembers.removeValue(forKey: listURI)
        listDetailUpdateTimes.removeValue(forKey: listURI)
        listMemberUpdateTimes.removeValue(forKey: listURI)
      }
      
      logger.info("Successfully deleted list: \(listURI)")
      
    } catch {
      logger.error("Failed to delete list: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  // MARK: - List Member Management
  
  /// Add a user to a list
  func addMember(userDID: String, to listURI: String) async throws {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    let operationId = "add-member-\(userDID)-to-\(listURI)"
    defer { inProgressOperations.remove(operationId) }
    
    if inProgressOperations.contains(operationId) {
      return // Operation already in progress
    }
    inProgressOperations.insert(operationId)
    
    logger.info("Adding member \(userDID) to list \(listURI)")
    
    do {
      // Check if user is already in the list
      let members = try await getListMembers(listURI)
      if members.contains(where: { $0.did.didString() == userDID }) {
        throw ListError.memberAlreadyAdded
      }
      
      // Create list item record
      let listItem = AppBskyGraphListitem(
        subject: try DID(didString: userDID),
        list: try ATProtocolURI(uriString: listURI),
        createdAt: ATProtocolDate(date: Date())
      )
      
      let (responseCode, _) = try await client.com.atproto.repo.createRecord(
        input: .init(
          repo: try ATIdentifier(string: appState?.userDID ?? ""),
          collection: try NSID(nsidString: "app.bsky.graph.listitem"),
          rkey: nil,
          validate: true,
          record: ATProtocolValueContainer.knownType(listItem),
          swapCommit: nil
        )
      )
      
      guard responseCode == 200 else {
        throw ListError.invalidResponse
      }
      
      // Invalidate member cache for this list
      await MainActor.run {
        listMemberUpdateTimes.removeValue(forKey: listURI)
        listMembers.removeValue(forKey: listURI)
      }
      
      logger.info("Successfully added member \(userDID) to list \(listURI)")
      
    } catch {
      logger.error("Failed to add member to list: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  /// Remove a user from a list
  func removeMember(userDID: String, from listURI: String) async throws {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    let operationId = "remove-member-\(userDID)-from-\(listURI)"
    defer { inProgressOperations.remove(operationId) }
    
    if inProgressOperations.contains(operationId) {
      return // Operation already in progress
    }
    inProgressOperations.insert(operationId)
    
    logger.info("Removing member \(userDID) from list \(listURI)")
    
    do {
      // Find the listitem record for this user and list
      let (responseCode, recordsData) = try await client.com.atproto.repo.listRecords(
        input: .init(
          repo: try ATIdentifier(string: appState?.userDID ?? ""),
          collection: try NSID(nsidString: "app.bsky.graph.listitem"),
          limit: 100,
          cursor: nil
        )
      )
      
      guard responseCode == 200, let recordsData = recordsData else {
        throw ListError.invalidResponse
      }
      
        
      // Find the matching listitem record
      var targetRecord: ComAtprotoRepoListRecords.Record?
      for record in recordsData.records {
          
          if case let .knownType(listItemRecord) = record.value,
             let listItem = listItemRecord as? AppBskyGraphListitem,
           listItem.subject.didString() == userDID,
           listItem.list.description == listURI {
          targetRecord = record
          break
        }
      }

    guard let targetRecord = targetRecord else {
        throw ListError.memberNotInList
      }
      
      // Delete the listitem record
      let uri = try ATProtocolURI(uriString: targetRecord.uri.description)
      let (deleteResponseCode, _) = try await client.com.atproto.repo.deleteRecord(
        input: .init(
          repo: try ATIdentifier(string: uri.authority),
          collection: try NSID(nsidString: uri.collection ?? ""),
          rkey: try RecordKey(keyString: uri.recordKey ?? ""),
          swapRecord: nil,
          swapCommit: nil
        )
      )
      
      guard deleteResponseCode == 200 else {
        throw ListError.invalidResponse
      }
      
      // Invalidate member cache for this list
      await MainActor.run {
        listMemberUpdateTimes.removeValue(forKey: listURI)
        listMembers.removeValue(forKey: listURI)
      }
      
      logger.info("Successfully removed member \(userDID) from list \(listURI)")
      
    } catch {
      logger.error("Failed to remove member from list: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  // MARK: - Data Fetching
  
  /// Load user's created lists
  func loadUserLists(forceRefresh: Bool = false) async throws -> [AppBskyGraphDefs.ListView] {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    await MainActor.run { state = .loading }
    
    // Check cache first
    let cacheIsStale = await isCacheStale(for: .userLists)
    if !forceRefresh && !cacheIsStale {
      await MainActor.run { state = .ready }
      return await userLists
    }
    
    logger.info("Loading user lists")
    
    do {
      let (responseCode, listsData) = try await client.app.bsky.graph.getLists(
        input: .init(
          actor: try ATIdentifier(string: appState?.userDID ?? ""),
          limit: 100,
          cursor: nil
        )
      )
      
      guard responseCode == 200, let listsData = listsData else {
        throw ListError.invalidResponse
      }
      
      await MainActor.run {
        userLists = listsData.lists
        lastUserListsUpdate = Date()
        state = .ready
      }
      
      logger.info("Successfully loaded \(listsData.lists.count) user lists")
      return listsData.lists
      
    } catch {
      await MainActor.run { state = .error(error.localizedDescription) }
      logger.error("Failed to load user lists: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  /// Get detailed information about a specific list
  func getListDetails(_ listURI: String, forceRefresh: Bool = false) async throws -> AppBskyGraphDefs.ListView {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    // Check cache first
    let cacheIsStale = await isCacheStale(for: .listDetails, listURI: listURI)
    if !forceRefresh && !cacheIsStale {
      if let cached = await listDetails[listURI] {
        return cached
      }
    }
    
    logger.info("Getting list details for: \(listURI)")
    
    do {
      let (responseCode, listData) = try await client.app.bsky.graph.getList(
        input: .init(
          list: try ATProtocolURI(uriString: listURI),
          limit: 1,
          cursor: nil
        )
      )
      
      guard responseCode == 200, let listData = listData else {
        throw ListError.listNotFound
      }
      
      await MainActor.run {
        listDetails[listURI] = listData.list
        listDetailUpdateTimes[listURI] = Date()
      }
      
      return listData.list
      
    } catch {
      logger.error("Failed to get list details: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  /// Get members of a specific list
  func getListMembers(_ listURI: String, forceRefresh: Bool = false) async throws -> [AppBskyActorDefs.ProfileView] {
    guard let client = client else {
      throw ListError.clientNotInitialized
    }
    
    // Check cache first
    let cacheIsStale = await isCacheStale(for: .listMembers, listURI: listURI)
    if !forceRefresh && !cacheIsStale {
      if let cached = await listMembers[listURI] {
        return cached
      }
    }
    
    logger.info("Getting list members for: \(listURI)")
    
    do {
      let (responseCode, listData) = try await client.app.bsky.graph.getList(
        input: .init(
          list: try ATProtocolURI(uriString: listURI),
          limit: 100,
          cursor: nil
        )
      )
      
      guard responseCode == 200, let listData = listData else {
        throw ListError.listNotFound
      }
      
      let members = listData.items.map { $0.subject }
      
      await MainActor.run {
        listMembers[listURI] = members
        listMemberUpdateTimes[listURI] = Date()
      }
      
      logger.info("Successfully loaded \(members.count) members for list \(listURI)")
      return members
      
    } catch {
      logger.error("Failed to get list members: \(error.localizedDescription)")
      throw ListError.networkError(error)
    }
  }
  
  // MARK: - Convenience Methods
  
  /// Check if a user is a member of a specific list
  func isUserMember(userDID: String, of listURI: String) async throws -> Bool {
    let members = try await getListMembers(listURI)
    return members.contains { $0.did.didString() == userDID }
  }
  
  /// Get all lists that the current user has created
  var cachedUserLists: [AppBskyGraphDefs.ListView] {
    get async {
      await userLists
    }
  }
  
  /// Get cached members for a list (returns empty array if not cached)
  func getCachedMembers(for listURI: String) async -> [AppBskyActorDefs.ProfileView] {
    await listMembers[listURI] ?? []
  }
}
