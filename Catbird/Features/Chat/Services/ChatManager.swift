#if os(iOS)
import UIKit
#endif
import Foundation
import OSLog
import Petrel
import PetrelCatbird
import SwiftUI

// PostEmbedData is now defined in UnifiedChat/Models/UnifiedEmbed.swift

/// Tracks requests owned by the notification/chat pollers, including caller-owned loads.
/// Suspension closes admission immediately; draining waits for their actual completion.
/// Safety: every mutable field is protected by `lock`; continuations resume outside it.
/// Retained for nonisolated legacy manager entry points until those managers adopt one actor.
final class AccountPollingBarrier: @unchecked Sendable {
  struct Ticket: Sendable {
    let id = UUID()
    let generation: UInt64
    let accountDID: String?
  }

  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var suspended = false
  private var suspendedAccountDID: String?
  private var active: Set<UUID> = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var isSuspended: Bool { lock.withLock { suspended } }
  var suspensionGeneration: UInt64? { lock.withLock { suspended ? generation : nil } }

  func begin(accountDID: String?) -> Ticket? {
    lock.withLock {
      guard !suspended else { return nil }
      let ticket = Ticket(generation: generation, accountDID: accountDID)
      active.insert(ticket.id)
      return ticket
    }
  }

  func isCurrent(_ ticket: Ticket, accountDID: String?) -> Bool {
    lock.withLock {
      !suspended && ticket.generation == generation && ticket.accountDID == accountDID
        && active.contains(ticket.id)
    }
  }

  func finish(_ ticket: Ticket) {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      active.remove(ticket.id)
      guard active.isEmpty else { return [] }
      let ready = waiters
      waiters.removeAll()
      return ready
    }
    for waiter in ready { waiter.resume() }
  }

  func invalidate() {
    lock.withLock { generation &+= 1 }
  }

  func suspend(accountDID: String?) {
    lock.withLock {
      guard !suspended else { return }
      suspended = true
      suspendedAccountDID = accountDID
      generation &+= 1
    }
  }

  func drain() async {
    await withCheckedContinuation { continuation in
      let alreadyDrained = lock.withLock {
        if active.isEmpty { return true }
        waiters.append(continuation)
        return false
      }
      if alreadyDrained { continuation.resume() }
    }
  }

  func resume(accountDID: String, generation expectedGeneration: UInt64) -> Bool {
    lock.withLock {
      guard suspended, active.isEmpty, suspendedAccountDID == accountDID,
        generation == expectedGeneration
      else { return false }
      suspended = false
      suspendedAccountDID = nil
      return true
    }
  }
}

/// Operational metadata only. No field accepts conversation IDs, message content,
/// cursor values, headers, URLs, or free-form error descriptions.
struct ChatHistoryLoadDiagnostic: Encodable {
  enum Phase: String, Encodable { case started, skipped, finished }
  enum Outcome: String, Encodable {
    case decodedEmpty, decodedPopulated, decodeFailed, httpFailure, requestFailure
    case cancelled, staleAccount, alreadyLoading, noClient, suspended
  }

  var requestID: UUID
  var relatedRequestID: UUID?
  var phase: Phase = .skipped
  var outcome: Outcome?
  var httpStatus: Int?
  var refresh: Bool
  var inputCursorPresent: Bool
  var outputCursorPresent: Bool?
  var receivedCount: Int?
  var userCount: Int?
  var systemCount: Int?
  var deletedCount: Int?
  var unknownCount: Int?
  var cachedBefore: Int
  var cachedAfter: Int
  var elapsedMilliseconds: Int64 = 0

  var logLine: String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

/// Manages chat operations for the Bluesky chat feature
@Observable
final class ChatManager: StateInvalidationSubscriber {
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatManager")
  private let historyDiagnosticLogger = Logger(subsystem: "blue.catbird", category: "ChatHistoryDiagnostics")

  // AT Protocol client reference
  private(set) var client: ATProtoClient?  // Made private(set) for controlled access

  // Conversations and messages
  var conversations: [ChatBskyConvoDefs.ConvoView] = []
  // Store original message views for reactions and other advanced features
  private(set) var originalMessagesMap: [String: [String: ChatBskyConvoDefs.MessageView]] = [:]  // [convoId: [messageId: MessageView]]
  private(set) var systemMessagesMap: [String: [String: ChatBskyConvoDefs.SystemMessageView]] = [:]  // [convoId: [messageId: SystemMessageView]]
  private(set) var relatedProfilesMap: [String: [String: ChatBskyActorDefs.ProfileViewBasic]] = [:]  // [convoId: [didString: ProfileViewBasic]]
  private(set) var loadingConversations: Bool = false
  /// True once a conversation-list load has finished (successfully or not)
  /// for the current account, so the list can tell "loading" from "empty".
  private(set) var hasAttemptedConversationsLoad: Bool = false
  /// True when the most recent conversation-list load failed.
  private(set) var lastConversationsLoadFailed: Bool = false
  private(set) var loadingMessages: [String: Bool] = [:]
  /// Shared by the first load and polling so overlapping callers observe the same request.
  enum MessageLoadState: Equatable {
    case idle
    case loading
    case loaded
    case interrupted
    case failed(ChatError)
  }
  private(set) var messageLoadStates: [String: MessageLoadState] = [:]

  typealias MessagePageLoader = @MainActor (
    ATProtoClient, ChatBskyConvoGetMessages.Parameters
  ) async throws -> (Int, ChatBskyConvoGetMessages.Output?)
  @ObservationIgnored private let messagePageLoader: MessagePageLoader
  var errorState: ChatError?

  // Search-related state
  private(set) var filteredConversations: [ChatBskyConvoDefs.ConvoView] = []
  private(set) var filteredProfiles: [ChatBskyActorDefs.ProfileViewBasic] = []
  private let actorSearchDebounceNanoseconds: UInt64 = 250_000_000
  @ObservationIgnored private var actorSearchTask: Task<Void, Never>?
  @ObservationIgnored private var pendingActorSearchQuery: String = ""
  
  // Message requests state
  private(set) var messageRequests: [ChatBskyConvoDefs.ConvoView] = []
  private(set) var acceptedConversations: [ChatBskyConvoDefs.ConvoView] = []

  // Conversation revision tracking for fine-grained observation (P137)
  private var convoRevisions: [String: Int] = [:]

  func conversationRevision(for convoId: String) -> Int {
    convoRevisions[convoId] ?? 0
  }

  func bumpConversationRevision(for convoId: String) {
    convoRevisions[convoId, default: 0] &+= 1
  }

  // Profile member signature cache (P145)
  private var profileSignatureCache: [String: String] = [:]

  // Chat tab visibility gating (P134)
  var isChatTabVisible: Bool = false {
    didSet {
      guard isChatTabVisible != oldValue else { return }
      if isChatTabVisible {
        startConversationsPolling()
        Task { @MainActor [weak self] in
          await self?.pollGetLog()
        }
      } else {
        startConversationsPolling()
      }
    }
  }

  func setChatTabVisible(_ visible: Bool) {
    isChatTabVisible = visible
  }

  // Log cursor and slow reconcile state (P134)
  private var logCursor: String?
  private var lastFullReconcileTime: Date = .distantPast
  private let fullReconcileInterval: TimeInterval = 300.0
  private var pausedPollingActiveConvoId: String?

  /// Messageability results from getConvoAvailability, keyed by the sorted
  /// member DIDs, so list rows don't re-query the same people.
  @ObservationIgnored private var availabilityCache: [String: Bool] = [:]

  /// The chat service caps message text at 1,000 graphemes
  /// (`chat.bsky.convo.defs#messageInput`).
  static let maxMessageGraphemes = 1000

  // Pagination control
  var conversationsCursor: String?
  private var messagesCursors: [String: String?] = [:]
  
  // Polling control
  private var conversationsPollingTask: Task<Void, Never>?
  private var messagePollingTasks: [String: Task<Void, Never>] = [:]
  private var isAppActive = true

  /// The conversation currently on screen (set by ConversationView via
  /// start/stopMessagePolling). Used to suppress foreground push banners
  /// for the thread the user is already reading.
  private(set) var activeConversationId: String?
  
  // Polling intervals (in seconds) - balanced for responsiveness and performance
  private let activeConversationPollInterval: TimeInterval = 5.0  // 5 seconds when viewing a conversation
  private let activeListPollInterval: TimeInterval = 30.0  // 30 seconds when viewing conversation list
  private let backgroundPollInterval: TimeInterval = 120.0  // 2 minutes when backgrounded
  private let maxPollBackoffInterval: TimeInterval = 300.0  // 5 minute cap after repeated rate limits

  // Rate-limit backoff: each HTTP 429 doubles the affected poll interval (capped
  // above); the next clean success returns the loop to its normal cadence
  private var conversationsPollBackoff: TimeInterval = 0
  private var messagePollBackoffs: [String: TimeInterval] = [:]

  // Callback for when unread count changes
  var onUnreadCountChanged: (() -> Void)?

  // Fired after every conversations poll tick, so AppState can refresh adjacent
  // state (unread badge, conversation list) off the single list poller
  var onConversationsPolled: (() -> Void)?

  // Reference to app state for notifications
  private weak var appState: AppState?

  @ObservationIgnored private var activeClientDid: String?
  @ObservationIgnored private let pollingBarrier = AccountPollingBarrier()
  @ObservationIgnored private var resumeConversationPolling = false
  @ObservationIgnored private var resumeMessagePolling: Set<String> = []
  @ObservationIgnored private var conversationLoadID: UUID?
  @ObservationIgnored private var messageLoadIDs: [String: UUID] = [:]

  private var pollingAccountDID: String? { appState?.userDID ?? activeClientDid }

  private func isCurrentPollingOperation(_ ticket: AccountPollingBarrier.Ticket, client: ATProtoClient) -> Bool {
    !Task.isCancelled && self.client === client
      && pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID)
  }

  @MainActor
  func suspendForAccountSwitch() async {
    if !pollingBarrier.isSuspended {
      resumeConversationPolling = conversationsPollingTask != nil
      resumeMessagePolling = Set(messagePollingTasks.keys)
    }
    pollingBarrier.suspend(accountDID: pollingAccountDID)
    let tasks = Array(messagePollingTasks.values) + [conversationsPollingTask, actorSearchTask].compactMap { $0 }
    for task in tasks { task.cancel() }
    conversationsPollingTask = nil
    messagePollingTasks.removeAll()
    actorSearchTask = nil
    for task in tasks { await task.value }
    await pollingBarrier.drain()
  }

  @MainActor
  func resumeAfterInterruptedAccountSwitch(accountDID: String) async -> Bool {
    guard let generation = pollingBarrier.suspensionGeneration,
      pollingAccountDID == accountDID, let client
    else { return false }
    let authenticatedDID = try? await client.getDid()
    guard self.client === client, pollingAccountDID == accountDID,
      authenticatedDID == accountDID, pollingBarrier.resume(accountDID: accountDID, generation: generation)
    else { return false }
    let conversationIDs = resumeMessagePolling
    let activeID = activeConversationId
    let backoffs = messagePollBackoffs
    if resumeConversationPolling { startConversationsPolling() }
    for id in conversationIDs { startMessagePolling(for: id) }
    activeConversationId = activeID
    messagePollBackoffs = backoffs
    resumeConversationPolling = false
    resumeMessagePolling.removeAll()
    return true
  }

  init(
    client: ATProtoClient? = nil,
    appState: AppState? = nil,
    messagePageLoader: @escaping MessagePageLoader = { client, parameters in
      try await client.chat.bsky.convo.getMessages(input: parameters)
    }
  ) {
    self.messagePageLoader = messagePageLoader
    self.client = client
    self.appState = appState
    logger.debug("ChatManager initialized")
    setupNotificationObservers()

    // Subscribe to state invalidation events if appState is provided
    if let appState = appState {
      appState.stateInvalidationBus.subscribe(self)
    }
  }

  // MARK: - Lifecycle Management
  
  deinit {
    stopAllPolling()
  }
  
  private func setupNotificationObservers() {
    #if os(iOS)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    #elseif os(macOS)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
    #endif
  }
  
  @objc private func appDidBecomeActive() {
    isAppActive = true
    logger.debug("App became active, resuming polling")
    Task { @MainActor [weak self] in
      self?.resumePolling()
    }
  }

  @objc private func appDidEnterBackground() {
    isAppActive = false
    logger.debug("App entered background, pausing polling")
    Task { @MainActor [weak self] in
      self?.pausePolling()
    }
  }

  /// Lightweight pause when app resigns active / enters background (P190)
  @MainActor
  func pausePolling() {
    isAppActive = false
    pausedPollingActiveConvoId = activeConversationId
    activeConversationId = nil
    conversationsPollingTask?.cancel()
    conversationsPollingTask = nil
    for (_, task) in messagePollingTasks {
      task.cancel()
    }
    messagePollingTasks.removeAll()
    logger.debug("ChatManager polling paused for inactive/background")
  }

  /// Lightweight resume when app returns to active (P190)
  @MainActor
  func resumePolling() {
    isAppActive = true
    if let convoId = pausedPollingActiveConvoId {
      pausedPollingActiveConvoId = nil
      startMessagePolling(for: convoId)
    } else {
      startConversationsPolling()
    }
    logger.debug("ChatManager polling resumed for active")
  }

  // Update client when auth changes
  @MainActor
  func updateClient(_ client: ATProtoClient?) async {
    guard !pollingBarrier.isSuspended else { return }
    pollingBarrier.invalidate()
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }
    let previousDid = activeClientDid
    self.client = client
    logger.debug("ChatManager client updated")

    guard let client else {
      guard pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }
      activeClientDid = nil
      clearChatData()
      logger.debug("Chat data cleared because client became nil")
      return
    }

    let nextDid = try? await client.getDid()
    guard isCurrentPollingOperation(ticket, client: client) else { return }

    if previousDid != nextDid {
      await MainActor.run {
        guard self.isCurrentPollingOperation(ticket, client: client) else { return }
        self.clearChatData()
      }
      guard isCurrentPollingOperation(ticket, client: client) else { return }
      logger.debug("Chat data cleared due to client change")
    }

    activeClientDid = nextDid

    // Start polling for the new or existing client
    startConversationsPolling()
  }
  
  /// Update app state reference and subscribe to state invalidation events
  func updateAppState(_ appState: AppState?) {
    guard !pollingBarrier.isSuspended else { return }
    self.appState = appState
    if let appState = appState {
      appState.stateInvalidationBus.subscribe(self)
      logger.debug("ChatManager subscribed to state invalidation bus")
    }
  }
  
  // MARK: - State Invalidation Handling
  
  /// Check if ChatManager is interested in a specific state invalidation event
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .accountSwitched, .chatMessageReceived:
      return true
    default:
      return false // ChatManager only cares about account switches and chat messages
    }
  }
  
  /// Handle state invalidation events from the central event bus
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }
    logger.debug("Chat handling state invalidation event: \(String(describing: event))")
    
    switch event {
    case .accountSwitched:
      // Account switching should clear and reload chat data
      await MainActor.run {
        guard self.pollingBarrier.isCurrent(ticket, accountDID: self.pollingAccountDID) else { return }
        logger.info("Account switched - clearing chat data and reloading")
        clearChatData()
        
        // Reload conversations if we have a client
        if client != nil {
          Task {
            await loadConversations(refresh: true)
          }
        }
      }
      
    case .chatMessageReceived:
      // New message received - refresh conversations to update unread counts
      await MainActor.run {
        guard self.pollingBarrier.isCurrent(ticket, accountDID: self.pollingAccountDID) else { return }
        if client != nil {
          Task {
            await loadConversations(refresh: true)
          }
        }
      }
      
    case .authenticationCompleted:
      // Authentication completed - reload conversations if needed
      await MainActor.run {
        guard self.pollingBarrier.isCurrent(ticket, accountDID: self.pollingAccountDID) else { return }
        if client != nil {
          Task {
            await loadConversations(refresh: true)
          }
        }
      }
      
    case .postCreated, .replyCreated, .threadUpdated:
      // These don't affect chat content
      break
      
    case .feedUpdated, .profileUpdated, .notificationsUpdated:
      // These don't affect chat content
      break
      
    case .postLiked, .postUnliked, .postReposted, .postUnreposted:
      // These don't affect chat content
      break
    case .feedListChanged:
      // Feed list changes don't affect chat content
      break
    }
  }
  
  /// Clear all chat data (called during account switching)
  private func clearChatData() {
    stopAllPolling()
    conversations = []
    conversationLoadID = nil
    messageLoadIDs.removeAll()
    originalMessagesMap = [:]
    systemMessagesMap = [:]
    relatedProfilesMap = [:]
    conversationsCursor = nil
    messagesCursors = [:]
    conversationsPollBackoff = 0
    messagePollBackoffs = [:]
    loadingConversations = false
    hasAttemptedConversationsLoad = false
    lastConversationsLoadFailed = false
    loadingMessages = [:]
    messageLoadStates = [:]
    errorState = nil
    profileSignatureCache = [:]
    availabilityCache = [:]
    filteredConversations = []
    filteredProfiles = []
    actorSearchTask?.cancel()
    actorSearchTask = nil
    pendingActorSearchQuery = ""
    messageRequests = []
    acceptedConversations = []
    logCursor = nil
    lastFullReconcileTime = .distantPast
    convoRevisions = [:]
    pausedPollingActiveConvoId = nil
    activeConversationId = nil
    logger.debug("Chat data cleared")
  }

  // MARK: - Conversation Loading

  /// Loads the conversation list. Background polls pass `userInitiated: false`
  /// (the default) so transient failures back off silently instead of
  /// alerting on every tick; pull-to-refresh and the first load pass `true`.
  @MainActor
  func loadConversations(refresh: Bool = false, userInitiated: Bool = false) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot load conversations: client is nil")
      errorState = .noClient
      return
    }

    // Skip if already loading
    if loadingConversations {
      logger.debug("Already loading conversations, skipping.")
      return
    }
    
    // Skip if user is currently authenticating to reduce noise during login flow
      let authState = AppStateManager.shared.authentication.state
    if case .authenticating = authState {
      logger.debug("Skipping conversation loading while user is authenticating")
      return
    }

    // If refreshing, cancel any ongoing load? (Consider Task management if needed)

    do {
      if userInitiated {
        loadingConversations = true
      }
      conversationLoadID = ticket.id
      defer {
        if conversationLoadID == ticket.id {
          if userInitiated {
            loadingConversations = false
          }
          conversationLoadID = nil
        }
      }

      // Reset cursor if refreshing
      let cursorToUse = refresh ? nil : conversationsCursor

      let params = ChatBskyConvoListConvos.Parameters(
        limit: 20,  // Consider making limit configurable or dynamic
        cursor: cursorToUse
      )

      logger.debug("Loading conversations with cursor: \(cursorToUse ?? "nil")")
         let (responseCode, response) = try await client.chat.bsky.convo.listConvos(input: params)
      guard isCurrentPollingOperation(ticket, client: client) else { return }
 
      guard responseCode >= 200 && responseCode < 300 else {
        // Insurance only: Petrel throws for non-400 client errors, so a 429
        // normally arrives on the thrown path (see the catch below).
        if responseCode == 429 {
          increaseConversationsPollBackoff()
        }
        setNetworkError(code: responseCode, context: "loadConversations")
        recordConversationsLoad(failed: true)
        loadingConversations = false
        return
      }

      guard let convosData = response else {
        logger.error("No data returned from conversations request")
        setEmptyResponseError(context: "loadConversations")
        recordConversationsLoad(failed: true)
        loadingConversations = false
        return
      }

      // Update state
      // Update state (P142: merge page 1 instead of replacing)
      if refresh {
        if conversations.count > convosData.convos.count {
          let page1IDs = Set(convosData.convos.map { $0.id })
          let tail = conversations.filter { !page1IDs.contains($0.id) }
          let merged = convosData.convos + tail
          if conversations != merged {
            conversations = merged
          }
          if conversationsCursor == nil {
            conversationsCursor = convosData.cursor
          }
        } else {
          if conversations != convosData.convos {
            conversations = convosData.convos
          }
          conversationsCursor = convosData.cursor
        }
      } else {
        // Avoid duplicates if loading more
        let existingIDs = Set(conversations.map { $0.id })
        let newConvos = convosData.convos.filter { !existingIDs.contains($0.id) }
        conversations.append(contentsOf: newConvos)
        conversationsCursor = convosData.cursor
      }

      conversationsPollBackoff = 0
      recordConversationsLoad(failed: false)

      // Update filtered lists based on status
      updateConversationsByStatus()

      logger.debug(
        "Loaded \(convosData.convos.count) conversations. New cursor: \(convosData.cursor ?? "nil")"
      )
      
      // Notify that unread count may have changed
      onUnreadCountChanged?()

      // Prefetch member profiles for the UI cache
      guard isCurrentPollingOperation(ticket, client: client) else { return }
      await syncConversationMemberProfiles(from: convosData.convos)
      guard isCurrentPollingOperation(ticket, client: client) else { return }

    } catch {
      guard isCurrentPollingOperation(ticket, client: client) else { return }
      // Rate limits surface as thrown errors (Petrel throws for non-400 client
      // errors); back off silently — a rate-limited background poll must not
      // alert the user on every tick.
      recordConversationsLoad(failed: true)
      if isRateLimitError(error) {
        increaseConversationsPollBackoff()
        loadingConversations = false
        return
      }
      logger.error("Error loading conversations: \(error.localizedDescription)")
      if userInitiated || UserFacingError.kind(of: error) == .signInRequired {
        setErrorState(error)
      } else {
        increaseConversationsPollBackoff()
      }
    }

    loadingConversations = false
  }

  @MainActor
  private func recordConversationsLoad(failed: Bool) {
    hasAttemptedConversationsLoad = true
    lastConversationsLoadFailed = failed
  }

  // MARK: - Messages Loading

  /// Loads a page of messages. The 5-second conversation poll passes
  /// `userInitiated: false` (the default) so a degraded chat service backs off
  /// quietly. Conversation views render failures through `messageLoadStates`.
  @MainActor
  func loadMessages(convoId: String, refresh: Bool = false, userInitiated: Bool = false) async {
    let started = ContinuousClock.now
    let cachedBefore = (originalMessagesMap[convoId]?.count ?? 0) + (systemMessagesMap[convoId]?.count ?? 0)
    var diagnostic = ChatHistoryLoadDiagnostic(
      requestID: UUID(), refresh: refresh,
      inputCursorPresent: !refresh && (messagesCursors[convoId] ?? nil) != nil,
      cachedBefore: cachedBefore, cachedAfter: cachedBefore
    )
    defer {
      let elapsed = started.duration(to: ContinuousClock.now).components
      diagnostic.elapsedMilliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
      if let line = diagnostic.logLine {
        historyDiagnosticLogger.notice("\(line, privacy: .public)")
      }
    }
    guard !Task.isCancelled else {
      diagnostic.outcome = .cancelled
      return
    }
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else {
      diagnostic.outcome = .suspended
      return
    }
    diagnostic.requestID = ticket.id
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      diagnostic.outcome = .noClient
      logger.error("Cannot load messages for \(convoId): client is nil")
      messageLoadStates[convoId] = .failed(.noClient)
      errorState = .noClient
      return
    }

    // Skip if already loading this conversation
    if loadingMessages[convoId] == true {
      diagnostic.outcome = .alreadyLoading
      diagnostic.relatedRequestID = messageLoadIDs[convoId]
      logger.debug("Already loading messages for \(convoId), skipping.")
      return
    }

    let previousLoadState = messageLoadStates[convoId] ?? .idle
    do {
      loadingMessages[convoId] = true
      messageLoadStates[convoId] = .loading
      messageLoadIDs[convoId] = ticket.id
      defer {
        if messageLoadIDs[convoId] == ticket.id {
          loadingMessages[convoId] = false
          messageLoadIDs[convoId] = nil
          // Cancellation or an invalidated account must not claim an empty success.
          if messageLoadStates[convoId] == .loading {
            messageLoadStates[convoId] = previousLoadState == .idle ? .interrupted : previousLoadState
          }
        }
      }

      // Reset cursor if refreshing
      let cursorToUse: String? = refresh ? nil : (messagesCursors[convoId] ?? nil)

      let params = ChatBskyConvoGetMessages.Parameters(
        convoId: convoId,
        limit: 30,  // Consider making limit configurable
        cursor: cursorToUse
      )

      logger.debug("Loading messages for \(convoId) with cursor: \(cursorToUse ?? "nil")")

      diagnostic.phase = .started
      if let line = diagnostic.logLine {
        historyDiagnosticLogger.notice("\(line, privacy: .public)")
      }
      diagnostic.phase = .finished
   
      let (responseCode, response) = try await messagePageLoader(client, params)
      diagnostic.httpStatus = responseCode
      guard isCurrentPollingOperation(ticket, client: client) else {
        diagnostic.outcome = Task.isCancelled ? .cancelled : .staleAccount
        return
      }
 
      guard responseCode >= 200 && responseCode < 300 else {
        diagnostic.outcome = .httpFailure
        // Insurance only: Petrel throws for non-400 client errors, so a 429
        // normally arrives on the thrown path (see the catch below).
        if responseCode == 429 {
          increaseMessagePollBackoff(for: convoId)
        }
        messageLoadStates[convoId] = .failed(.networkError(code: responseCode))
        setNetworkError(code: responseCode, context: "loadMessages(\(convoId))")
        loadingMessages[convoId] = false
        return
      }

      guard let messagesData = response else {
        // The generated getMessages wrapper returns 2xx + nil only from its decode catch.
        diagnostic.outcome = .decodeFailed
        logger.error("No data returned from messages request for \(convoId)")
        messageLoadStates[convoId] = .failed(.emptyResponse)
        setEmptyResponseError(context: "loadMessages(\(convoId))")
        loadingMessages[convoId] = false
        return
      }

      // Convert messages to original format for storage and collect deletions
      var originalMessages: [String: ChatBskyConvoDefs.MessageView] = [:]
      var systemMessages: [String: ChatBskyConvoDefs.SystemMessageView] = [:]
      var deletedMessageIds: Set<String> = []
      var messageCount = 0
      diagnostic.receivedCount = messagesData.messages.count
      diagnostic.outputCursorPresent = messagesData.cursor != nil
      diagnostic.userCount = 0
      diagnostic.systemCount = 0
      diagnostic.deletedCount = 0
      diagnostic.unknownCount = 0
      for messageUnion in messagesData.messages {
        switch messageUnion {
        case .chatBskyConvoDefsMessageView(let messageView):
          diagnostic.userCount = (diagnostic.userCount ?? 0) + 1
          originalMessages[messageView.id] = messageView
          messageCount += 1
        case .chatBskyConvoDefsDeletedMessageView(let deletedMessageView):
          diagnostic.deletedCount = (diagnostic.deletedCount ?? 0) + 1
          deletedMessageIds.insert(deletedMessageView.id)
        case .chatBskyConvoDefsSystemMessageView(let systemMessageView):
          diagnostic.systemCount = (diagnostic.systemCount ?? 0) + 1
          systemMessages[systemMessageView.id] = systemMessageView
          messageCount += 1
        case .unexpected(let data):
          diagnostic.unknownCount = (diagnostic.unknownCount ?? 0) + 1
          logger.warning(
            "Unexpected message type encountered in \(convoId): \(String(describing: data))")
          continue
        }
      }

      // Upsert original messages and remove deleted messages without erasing paginated history
      var existingOriginals = originalMessagesMap[convoId] ?? [:]
      for (id, messageView) in originalMessages {
        existingOriginals[id] = messageView
      }
      for deletedId in deletedMessageIds {
        existingOriginals.removeValue(forKey: deletedId)
      }
      if originalMessagesMap[convoId] != existingOriginals {
        originalMessagesMap[convoId] = existingOriginals
        bumpConversationRevision(for: convoId)
      }

      // Upsert system messages and remove deleted messages without erasing paginated history
      var existingSystems = systemMessagesMap[convoId] ?? [:]
      for (id, systemMessageView) in systemMessages {
        existingSystems[id] = systemMessageView
      }
      for deletedId in deletedMessageIds {
        existingSystems.removeValue(forKey: deletedId)
      }
      if systemMessagesMap[convoId] != existingSystems {
        systemMessagesMap[convoId] = existingSystems
        bumpConversationRevision(for: convoId)
      }

      // Merge relatedProfiles
      if let related = messagesData.relatedProfiles {
        var existingProfiles = relatedProfilesMap[convoId] ?? [:]
        for profile in related {
          existingProfiles[profile.did.didString()] = profile
        }
        if relatedProfilesMap[convoId] != existingProfiles {
          relatedProfilesMap[convoId] = existingProfiles
          bumpConversationRevision(for: convoId)
        }
      }
      if !refresh || messagesCursors[convoId] == nil {
        messagesCursors[convoId] = messagesData.cursor
      }
      messagePollBackoffs[convoId] = nil
      messageLoadStates[convoId] = .loaded
      diagnostic.outcome = messagesData.messages.isEmpty ? .decodedEmpty : .decodedPopulated
      diagnostic.cachedAfter = existingOriginals.count + existingSystems.count

      logger.debug(
        "Loaded \(messageCount) messages for conversation \(convoId). New cursor: \(messagesData.cursor ?? "nil")"
      )

      // Mark conversation as read only after successfully loading messages
      guard isCurrentPollingOperation(ticket, client: client) else { return }
      await markConversationAsRead(convoId: convoId)
      guard isCurrentPollingOperation(ticket, client: client) else { return }

    } catch {
      guard isCurrentPollingOperation(ticket, client: client) else {
        diagnostic.outcome = Task.isCancelled ? .cancelled : .staleAccount
        return
      }
      guard UserFacingError.kind(of: error) != .cancelled else {
        diagnostic.outcome = .cancelled
        return
      }
      diagnostic.outcome = .requestFailure
      if let networkError = error as? Petrel.NetworkError {
        switch networkError {
        case .responseError(let status), .serverError(let status, _):
          diagnostic.httpStatus = status
        default: break
        }
      } else if let statusError = error as? any HTTPStatusCarrying {
        diagnostic.httpStatus = statusError.httpStatusCode
      }
      if diagnostic.httpStatus != nil { diagnostic.outcome = .httpFailure }
      if case let Petrel.NetworkError.responseError(statusCode) = error {
        messageLoadStates[convoId] = .failed(.networkError(code: statusCode))
      } else {
        messageLoadStates[convoId] = .failed(.generalError(error))
      }
      // Rate limits surface as thrown errors (Petrel throws for non-400 client
      // errors); back off silently — a rate-limited background poll must not
      // alert the user on every tick.
      if isRateLimitError(error) {
        increaseMessagePollBackoff(for: convoId)
        loadingMessages[convoId] = false
        return
      }
      logger.error("Error loading messages for \(convoId): \(error.localizedDescription)")
      if userInitiated || UserFacingError.kind(of: error) == .signInRequired {
        setErrorState(error)
      } else {
        increaseMessagePollBackoff(for: convoId)
      }
    }

    loadingMessages[convoId] = false
  }

  /// Outcome of a `leaveConversation` call, so call sites can branch on the
  /// owner-must-lock case (chat.bsky.convo.leaveConvo `OwnerCannotLeave`).
  enum LeaveConversationResult: Equatable {
    case success
    /// The current user owns this group; the server requires locking it before leaving.
    case ownerMustLockFirst
    case failure
  }

  @MainActor
  @discardableResult
  func leaveConversation(convoId: String) async -> LeaveConversationResult {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return .failure }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot leave conversation \(convoId): client is nil")
      errorState = .noClient
      return .failure
    }

    let leaveInput = ChatBskyConvoLeaveConvo.Input(convoId: convoId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.leaveConvo(input: leaveInput)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return .failure }

      guard responseCode >= 200 && responseCode < 300 else {
        // Lexicon-defined errors arrive as HTTP 400 (the generated wrapper drops
        // the error body); for a group the current user owns, the 400 here is
        // `OwnerCannotLeave` — the owner must lock the group before leaving.
        if responseCode == 400, await isCurrentUserGroupOwner(convoId: convoId) {
          guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return .failure }
          logger.info("Leave blocked for owned group \(convoId); lock required before leaving")
          errorState = .ownerCannotLeave
          return .ownerMustLockFirst
        }
        guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return .failure }
        setInteractiveNetworkError(
          code: responseCode,
          context: "leaveConversation(\(convoId))",
          operation: "leave this conversation"
        )
        return .failure
      }

      // Remove conversation from local state
      if let index = conversations.firstIndex(where: { $0.id == convoId }) {
        conversations.remove(at: index)
        originalMessagesMap[convoId] = nil  // Clear original messages for this convo
        systemMessagesMap[convoId] = nil
        relatedProfilesMap[convoId] = nil
        updateConversationsByStatus()
        onUnreadCountChanged?()
        logger.debug("Left conversation \(convoId) successfully.")
      }
      return .success

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return .failure }
      logger.error("Error leaving conversation \(convoId): \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "leaveConversation(\(convoId))",
        operation: "leave this conversation"
      )
      return .failure
    }
  }

  /// Outcome of a `lockConversation` call. The generated wrapper drops the
  /// XRPC error body, so a 400 can't distinguish `ConvoLocked` (already
  /// locked) from a genuine rejection; the ambiguous case is reported so the
  /// lock-and-leave path can fall through to the authoritative leave call.
  enum LockConversationResult: Equatable {
    case locked
    /// HTTP 400 without local state confirming the lock — plausibly
    /// `ConvoLocked` from a remote lock this client hasn't polled yet.
    case possiblyAlreadyLocked
    case failure
  }

  @MainActor
  @discardableResult
  func lockConversation(convoId: String) async -> LockConversationResult {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return .failure }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot lock conversation \(convoId): client is nil")
      errorState = .noClient
      return .failure
    }

    let lockInput = ChatBskyConvoLockConvo.Input(convoId: convoId)
     do {
      let (responseCode, response) = try await client.chat.bsky.convo.lockConvo(input: lockInput)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return .failure }

      guard responseCode >= 200 && responseCode < 300 else {
        // `ConvoLocked` (already locked) also arrives as HTTP 400; treat an
        // already-locked group as success so lock-then-leave stays idempotent.
        if responseCode == 400 {
          if conversations.first(where: { $0.id == convoId })?.isLockedForSending == true {
            logger.debug("Conversation \(convoId) is already locked")
            return .locked
          }
          logger.info(
            "Lock returned 400 for \(convoId) without a locally-visible lock; possibly locked remotely")
          return .possiblyAlreadyLocked
        }
        setInteractiveNetworkError(
          code: responseCode,
          context: "lockConversation(\(convoId))",
          operation: "lock this group"
        )
        return .failure
      }

      // The response carries the updated ConvoView (lockStatus flipped)
      if let updatedConvo = response?.convo,
         let index = conversations.firstIndex(where: { $0.id == updatedConvo.id }) {
        conversations[index] = updatedConvo
        updateConversationsByStatus()
      }
      logger.debug("Conversation \(convoId) locked successfully.")
      return .locked

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return .failure }
      logger.error("Error locking conversation \(convoId): \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "lockConversation(\(convoId))",
        operation: "lock this group"
      )
      return .failure
    }
  }

  /// Owner leave path (social-app `leaveAndLockConvo`): the server rejects
  /// `leaveConvo` for group owners with `OwnerCannotLeave`, so lock the group
  /// first, then leave. A lock 400 with stale-unlocked local state proceeds to
  /// the leave anyway — the leave's own result is authoritative, and a genuine
  /// lock rejection would fail the leave too and surface there.
  @MainActor
  @discardableResult
  func lockAndLeaveConversation(convoId: String) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard await lockConversation(convoId: convoId) != .failure else { return false }
    guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
    return await leaveConversation(convoId: convoId) == .success
  }

  @MainActor
  func muteConversation(convoId: String) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot mute conversation: client is nil")
      errorState = .noClient
      return
    }

    let muteInput = ChatBskyConvoMuteConvo.Input(convoId: convoId)
     do {
      let (responseCode, response) = try await client.chat.bsky.convo.muteConvo(input: muteInput)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setInteractiveNetworkError(
          code: responseCode,
          context: "muteConversation(\(convoId))",
          operation: "mute this conversation"
        )
        return
      }

      // The response carries the updated ConvoView (muted flipped)
      if let updatedConvo = response?.convo {
        replaceConversation(updatedConvo)
      }
      logger.debug("Conversation \(convoId) muted successfully.")

      // Sync mute status to Nest (non-fatal)
      await syncMuteStatusToServer(convoId: convoId, muted: true)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }
      logger.error("Error muting conversation \(convoId): \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "muteConversation(\(convoId))",
        operation: "mute this conversation"
      )
    }
  }

  @MainActor
  func unmuteConversation(convoId: String) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot unmute conversation: client is nil")
      errorState = .noClient
      return
    }

    let unmuteInput = ChatBskyConvoUnmuteConvo.Input(convoId: convoId)
     do {
      let (responseCode, response) = try await client.chat.bsky.convo.unmuteConvo(input: unmuteInput)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setInteractiveNetworkError(
          code: responseCode,
          context: "unmuteConversation(\(convoId))",
          operation: "unmute this conversation"
        )
        return
      }

      // The response carries the updated ConvoView (muted flipped)
      if let updatedConvo = response?.convo {
        replaceConversation(updatedConvo)
      }
      logger.debug("Conversation \(convoId) unmuted successfully.")

      // Sync mute status to Nest (non-fatal)
      await syncMuteStatusToServer(convoId: convoId, muted: false)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }
      logger.error("Error unmuting conversation \(convoId): \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "unmuteConversation(\(convoId))",
        operation: "unmute this conversation"
      )
    }
  }

  /// Swaps a server-returned ConvoView into local state and refreshes the
  /// derived lists the conversation list renders from.
  @MainActor
  private func replaceConversation(_ convo: ChatBskyConvoDefs.ConvoView) {
    guard let index = conversations.firstIndex(where: { $0.id == convo.id }) else { return }
    conversations[index] = convo
    updateConversationsByStatus()
  }

  // MARK: - Mute Status Server Sync

  /// Service DID for routing custom Catbird endpoints through Nest.
  private static let nestServiceDID = CatbirdGatewayConfiguration.current.serviceDID

  /// Syncs the mute status of a conversation to Nest for server-side push filtering.
  /// This is non-fatal: the 15-minute background sync catches any missed updates.
  @MainActor
  private func syncMuteStatusToServer(convoId: String, muted: Bool) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else { return }

    let endpoint = "blue.catbird.bskychat.updateMuteStatus"
    await client.setServiceDID(Self.nestServiceDID, for: endpoint)
    guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }

    do {
      let input = BlueCatbirdBskychatUpdateMuteStatus.Input(convoId: convoId, muted: muted)
      let (responseCode, _) = try await client.blue.catbird.bskychat.updateMuteStatus(input: input)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }

      if (200 ... 299).contains(responseCode) {
        logger.debug("Synced mute status to server: convoId=\(convoId), muted=\(muted)")
      } else {
        logger.warning("Mute status sync returned HTTP \(responseCode) for convoId=\(convoId)")
      }
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return }
      logger.warning("Mute status sync failed for convoId=\(convoId): \(error.localizedDescription)")
    }
  }

  @MainActor
  func acceptConversation(convoId: String) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot accept conversation: client is nil")
      errorState = .noClient
      return false
    }

    let acceptInput = ChatBskyConvoAcceptConvo.Input(convoId: convoId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.acceptConvo(input: acceptInput)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "acceptConversation((convoId))")
        return false
      }

      logger.debug("Conversation \(convoId) accepted successfully.")
      // Refresh conversation list to reflect acceptance
      await loadConversations(refresh: true)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      return true

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Error accepting conversation \(convoId): \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  @MainActor
  func getConversation(convoId: String) async -> ChatBskyConvoDefs.ConvoView? {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return nil }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot get conversation: client is nil")
      errorState = .noClient
      return nil
    }

    let params = ChatBskyConvoGetConvo.Parameters(convoId: convoId)
     do {
      let (responseCode, response) = try await client.chat.bsky.convo.getConvo(input: params)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "getConversation((convoId))")
        return nil
      }

      guard let convoData = response else {
        logger.error("No data returned from get conversation request")
        setEmptyResponseError(context: "getConversation")
        return nil
      }

      logger.debug("Successfully retrieved conversation \(convoId)")
      return convoData.convo

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
      logger.error("Error getting conversation \(convoId): \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  /// Check if more messages are available for pagination
  func hasMoreMessages(for convoId: String) -> Bool {
    return (messagesCursors[convoId] ?? nil) != nil
  }

  /// Whether the given members can chat. `canChat` is `nil` when the answer
  /// is unknown (network failure, cancellation, account switch) — callers must
  /// not treat an unknown result as "can't be messaged". Failures are logged,
  /// not surfaced: this backs per-row checks in people lists.
  @MainActor
  func checkConversationAvailability(members: [String]) async -> (canChat: Bool?, existingConvo: ChatBskyConvoDefs.ConvoView?) {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return (nil, nil) }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot check conversation availability: client is nil")
      return (nil, nil)
    }

    do {
      let memberDIDs = try members.map { try DID(didString: $0) }
      let params = ChatBskyConvoGetConvoAvailability.Parameters(members: memberDIDs)
         
      let (responseCode, response) = try await client.chat.bsky.convo.getConvoAvailability(input: params)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return (nil, nil) }
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.warning("checkConversationAvailability: HTTP \(responseCode)")
        return (nil, nil)
      }

      guard let availability = response else {
        logger.error("No data returned from conversation availability request")
        return (nil, nil)
      }

      availabilityCache[Self.availabilityKey(for: members)] = availability.canChat
      logger.debug("Conversation availability check completed. Can chat: \(availability.canChat)")
      return (availability.canChat, availability.convo)

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return (nil, nil) }
      logger.error("Error checking conversation availability: \(error.localizedDescription)")
      return (nil, nil)
    }
  }

  /// Opens a profile's direct conversation after a fresh permission check.
  /// The source-account ticket remains held until all SDK work and acknowledgement finish.
  /// `nil` means unknown or interrupted; only confirmed refusal returns `false`.
  @MainActor
  func openProfileConversation(
    with userDID: String,
    expectedViewerDID: String
  ) async -> (canChat: Bool?, convoId: String?) {
    guard !Task.isCancelled, pollingAccountDID == expectedViewerDID,
      let client, let ticket = pollingBarrier.begin(accountDID: expectedViewerDID)
    else { return (nil, nil) }
    defer { pollingBarrier.finish(ticket) }

    do {
      let viewerDID = try DID(didString: expectedViewerDID)
      let recipientDID = try DID(didString: userDID)
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      guard viewerDID != recipientDID else { return (false, nil) }

      let authenticatedDID = await client.getCurrentAccount()?.did
      guard isCurrentPollingOperation(ticket, client: client),
        authenticatedDID == expectedViewerDID
      else { return (nil, nil) }
      errorState = nil

      let availability = await checkConversationAvailability(
        members: [expectedViewerDID, userDID], ticket: ticket, client: client
      )
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      guard let canChat = availability.canChat else {
        errorState = .operationFailed(operation: "check messaging availability")
        return (nil, nil)
      }
      guard canChat else {
        errorState = .recipientNotAccepting
        return (false, nil)
      }

      let convo: ChatBskyConvoDefs.ConvoView
      if let existing = availability.existingConvo {
        convo = existing
      } else {
        let params = ChatBskyConvoGetConvoForMembers.Parameters(members: [viewerDID, recipientDID])
        let (responseCode, response) = try await client.chat.bsky.convo.getConvoForMembers(input: params)
        guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
        guard responseCode >= 200 && responseCode < 300 else {
          setInteractiveNetworkError(
            code: responseCode, context: "openProfileConversation", operation: "open this conversation"
          )
          return (nil, nil)
        }
        guard let response else {
          errorState = .emptyResponse
          return (nil, nil)
        }
        convo = response.convo
      }

      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      if let index = conversations.firstIndex(where: { $0.id == convo.id }) {
        conversations[index] = convo
      } else {
        conversations.insert(convo, at: 0)
      }
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      updateConversationsByStatus()
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      onUnreadCountChanged?()
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      return (true, convo.id)
    } catch {
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      setInteractiveThrownError(error, context: "openProfileConversation", operation: "open this conversation")
      return (nil, nil)
    }
  }

  /// Fresh profile-action availability check using the caller's captured source-account lease.
  @MainActor
  private func checkConversationAvailability(
    members: [String],
    ticket: AccountPollingBarrier.Ticket,
    client: ATProtoClient
  ) async -> (canChat: Bool?, existingConvo: ChatBskyConvoDefs.ConvoView?) {
    guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
    do {
      let memberDIDs = try members.map { try DID(didString: $0) }
      let params = ChatBskyConvoGetConvoAvailability.Parameters(members: memberDIDs)
      let (responseCode, response) = try await client.chat.bsky.convo.getConvoAvailability(input: params)
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      guard responseCode >= 200 && responseCode < 300, let availability = response else {
        logger.warning("Profile conversation availability could not be confirmed (HTTP \(responseCode))")
        return (nil, nil)
      }
      availabilityCache[Self.availabilityKey(for: members)] = availability.canChat
      return (availability.canChat, availability.convo)
    } catch {
      guard isCurrentPollingOperation(ticket, client: client) else { return (nil, nil) }
      logger.error("Profile conversation availability check failed: \(error.localizedDescription)")
      return (nil, nil)
    }
  }

  /// Cached-first messageability check for list rows; `nil` means unknown.
  @MainActor
  func canMessage(members: [String]) async -> Bool? {
    if let cached = availabilityCache[Self.availabilityKey(for: members)] {
      return cached
    }
    return await checkConversationAvailability(members: members).canChat
  }

  private static func availabilityKey(for members: [String]) -> String {
    members.sorted().joined(separator: ",")
  }

  // MARK: - Message Actions

  @MainActor
  private func requireMessagingPolicy(source: AppState, convoId: String) throws {
    if let convo = conversation(withID: convoId) {
      try source.ageAccess.require(convo.isGroupConversation ? .groupMessaging : .directMessaging)
    } else {
      // A missing local conversation must not bypass either possible send boundary.
      try source.ageAccess.require(.directMessaging)
      try source.ageAccess.require(.groupMessaging)
    }
  }

  @MainActor
  private func requireMessagingAccess(
    source: AppState, client: ATProtoClient,
    ticket: AccountPollingBarrier.Ticket, convoId: String
  ) async throws {
    guard isCurrentPollingOperation(ticket, client: client), appState === source,
          source.atProtoClient === client, !source.isAccountSwitchSuspended else { throw CancellationError() }
    try requireMessagingPolicy(source: source, convoId: convoId)
    let did = try await client.getDid()
    guard isCurrentPollingOperation(ticket, client: client), appState === source,
          source.atProtoClient === client, !source.isAccountSwitchSuspended,
          did == source.userDID else { throw CancellationError() }
    try requireMessagingPolicy(source: source, convoId: convoId)
  }

  @MainActor
  func sendMessage(convoId: String, text: String) async -> Bool {
    return await sendMessage(convoId: convoId, text: text, embed: nil, replyTo: nil)
  }
  
  /// Send a message with optional embed and optional replyTo
  @MainActor
  func sendMessage(
    convoId: String,
    text: String,
    embed: ChatBskyConvoDefs.MessageInputEmbedUnion? = nil,
    replyTo: ChatBskyConvoDefs.ReplyRef? = nil
  ) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot send message to \(convoId): client or session is nil")
      errorState = .noClient
      return false
    }

    // Basic validation - allow empty text only if there's an embed (e.g., sharing a post)
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty || embed != nil else {
      logger.warning("Attempted to send empty message to \(convoId) without embed")
      return false
    }
    guard trimmedText.count <= Self.maxMessageGraphemes else {
      logger.warning("Attempted to send a \(trimmedText.count)-character message to \(convoId)")
      errorState = .messageTooLong
      return false
    }

    // Note: The UI handles optimistic updates, so we don't create them here
    // This prevents message duplication

    do {
      guard let source = appState else { throw AuthError.clientNotInitialized }
      try await requireMessagingAccess(source: source, client: client, ticket: ticket, convoId: convoId)
      // Build mention facets for @handles in chat (skip if text is empty)
      let facets = trimmedText.isEmpty ? [] : await buildChatFacets(for: trimmedText)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      let messageInput = ChatBskyConvoDefs.MessageInput(
        text: trimmedText,
        facets: facets.isEmpty ? nil : facets,
        embed: embed,
        replyTo: replyTo
      )

      let input = ChatBskyConvoSendMessage.Input(
        convoId: convoId,
        message: messageInput
      )

      logger.debug("Sending message to conversation \(convoId)\(embed != nil ? " with embed" : "")")
      try await requireMessagingAccess(source: source, client: client, ticket: ticket, convoId: convoId)
      let (responseCode, response) = try await client.chat.bsky.convo.sendMessage(input: input)
      guard isCurrentPollingOperation(ticket, client: client), appState === source else { return false }

      guard responseCode >= 200 && responseCode < 300 else {
        // `ConvoLocked` / `ConvoLockedByModeration` are the lexicon 400s for group
        // sends; the error body is dropped by the generated wrapper, so map from
        // the conversation's locally known lock state.
        let typedError: ChatError? =
          conversation(withID: convoId)?.isLockedForSending == true ? .conversationLocked : nil
        setInteractiveNetworkError(
          code: responseCode,
          context: "sendMessage(\(convoId))",
          typedError: typedError,
          operation: "send this message"
        )
        return false
      }

      guard let messageView = response else {
        setEmptyResponseError(context: "sendMessage(\(convoId))")
        return false
      }

      // Add the real message to our local state
      if var existingOriginals = originalMessagesMap[convoId] {
        existingOriginals[messageView.id] = messageView
        originalMessagesMap[convoId] = existingOriginals
      } else {
        originalMessagesMap[convoId] = [messageView.id: messageView]
      }

      // Update conversation list's last message preview
      await updateConversationLastMessage(convoId: convoId, messageView: messageView)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }

      logger.debug("Message sent successfully to conversation \(convoId)")
      return true

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Error sending message to \(convoId): \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "sendMessage(\(convoId))",
        operation: "send this message"
      )
      return false
    }
  }

  // MARK: - Chat Facets (Mentions, Links, Hashtags)
  @MainActor
  private func buildChatFacets(for text: String) async -> [AppBskyRichtextFacet] {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return [] }
    defer { pollingBarrier.finish(ticket) }

    var facets: [AppBskyRichtextFacet] = []

    // --- Link facets (via NSDataDetector) ---
    if let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let nsText = text as NSString
      let linkMatches = linkDetector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
      for match in linkMatches {
        guard let url = match.url,
              let swiftRange = Range(match.range, in: text) else { continue }
        let byteStart = text[text.startIndex..<swiftRange.lowerBound].utf8.count
        let byteEnd = byteStart + text[swiftRange].utf8.count
        // Ensure the URI has a scheme
        var uriString = url.absoluteString
        if url.scheme == nil {
          uriString = "https://\(uriString)"
        }
        let slice = AppBskyRichtextFacet.ByteSlice(byteStart: byteStart, byteEnd: byteEnd)
        let link = AppBskyRichtextFacet.Link(uri: URI(uriString: uriString))
        let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion.appBskyRichtextFacetLink(link)
        facets.append(AppBskyRichtextFacet(index: slice, features: [feature]))
      }
    }

    // --- Mention facets (@handle) ---
    if let client = client {
      let mentionPattern = #"(?<![a-zA-Z0-9])@([a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+)"#
      if let regex = try? NSRegularExpression(pattern: mentionPattern, options: []) {
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
          guard m.numberOfRanges > 1 else { continue }
          let fullRange = m.range(at: 0)
          let handleRange = m.range(at: 1)
          guard let swiftRange = Range(handleRange, in: text),
                let fullSwiftRange = Range(fullRange, in: text) else { continue }
          let handle = String(text[swiftRange])
          do {
            let params = AppBskyActorSearchActors.Parameters(q: handle, limit: 1)
            let (code, response) = try await client.app.bsky.actor.searchActors(input: params)
            guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return [] }
            if code >= 200 && code < 300, let profile = response?.actors.first,
               profile.handle.description.lowercased() == handle.lowercased() {
              let byteStart = text[text.startIndex..<fullSwiftRange.lowerBound].utf8.count
              let byteEnd = byteStart + text[fullSwiftRange].utf8.count
              let slice = AppBskyRichtextFacet.ByteSlice(byteStart: byteStart, byteEnd: byteEnd)
              let mention = AppBskyRichtextFacet.Mention(did: profile.did)
              let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion.appBskyRichtextFacetMention(mention)
              facets.append(AppBskyRichtextFacet(index: slice, features: [feature]))
            }
          } catch {
            guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return [] }
            logger.debug("Failed to resolve mention @\(handle): \(error.localizedDescription)")
          }
        }
      }
    }

    // --- Hashtag facets (#tag) ---
    let hashtagPattern = #"(?<![a-zA-Z0-9])#([^\s\p{P}][^\s]*[^\s\p{P}]|[^\s\p{P}])"#
    if let regex = try? NSRegularExpression(pattern: hashtagPattern, options: []) {
      let ns = text as NSString
      let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
      for m in matches {
        guard m.numberOfRanges > 1 else { continue }
        let fullRange = m.range(at: 0)
        let tagRange = m.range(at: 1)
        guard let fullSwiftRange = Range(fullRange, in: text),
              let tagSwiftRange = Range(tagRange, in: text) else { continue }
        let tag = String(text[tagSwiftRange])
        // Skip if the hashtag is inside a URL (overlaps with a link facet)
        let byteStart = text[text.startIndex..<fullSwiftRange.lowerBound].utf8.count
        let byteEnd = byteStart + text[fullSwiftRange].utf8.count
        let overlapsLink = facets.contains { facet in
          facet.index.byteStart <= byteStart && facet.index.byteEnd >= byteEnd
        }
        guard !overlapsLink else { continue }
        let slice = AppBskyRichtextFacet.ByteSlice(byteStart: byteStart, byteEnd: byteEnd)
        let tagFeature = AppBskyRichtextFacet.Tag(tag: tag)
        let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion.appBskyRichtextFacetTag(tagFeature)
        facets.append(AppBskyRichtextFacet(index: slice, features: [feature]))
      }
    }

    return facets
  }

  @MainActor
  func markConversationAsRead(convoId: String) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.debug("Cannot mark conversation \(convoId) as read: client is nil")
      return
    }

    // Only mark as read if there are unread messages locally
    guard let convoIndex = conversations.firstIndex(where: { $0.id == convoId }),
      conversations[convoIndex].unreadCount > 0
    else {
      // logger.debug("Conversation \(convoId) already marked as read locally or not found.")
      return
    }

    do {
      let input = ChatBskyConvoUpdateRead.Input(convoId: convoId, messageId: nil)  // messageId is optional
      logger.debug("Marking conversation \(convoId) as read")
   
      let (responseCode, response) = try await client.chat.bsky.convo.updateRead(input: input)
      guard isCurrentPollingOperation(ticket, client: client) else { return }
 
      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Error marking conversation \(convoId) as read: HTTP \(responseCode)")
        // Don't update local state if API call failed
        return
      }

      // Update local conversation read state immediately on success
      if let updatedConvoView = response?.convo {
        if let index = conversations.firstIndex(where: { $0.id == updatedConvoView.id }) {
          conversations[index] = updatedConvoView
          updateConversationsByStatus()
          logger.debug(
            "Successfully marked conversation \(convoId) as read and updated local state.")
          // Notify that unread count has changed
          onUnreadCountChanged?()
        }
      } else {
        // Fallback if response doesn't contain the updated convo view
        if conversations.firstIndex(where: { $0.id == convoId }) != nil {
          // Manually create a modified version or wait for next refresh
          // For simplicity, let's assume the next refresh will fix it,
          // but ideally, we'd update the unreadCount to 0 here.
          // conversations[index].unreadCount = 0 // This requires ConvoView to be mutable or recreated
          logger.debug(
            "Successfully marked conversation \(convoId) as read (API success, local state update pending refresh)."
          )
        }
      }

    } catch {
      guard isCurrentPollingOperation(ticket, client: client) else { return }
      logger.error("Error marking conversation \(convoId) as read: \(error.localizedDescription)")
      // Optionally set an error state specific to this action
    }
  }

  @MainActor
  func deleteMessageForSelf(convoId: String, messageId: String) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot delete message: client is nil")
      errorState = .noClient
      return false
    }

    let input = ChatBskyConvoDeleteMessageForSelf.Input(convoId: convoId, messageId: messageId)
     do {
      let (responseCode, _) = try await client.chat.bsky.convo.deleteMessageForSelf(input: input)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }

      guard responseCode >= 200 && responseCode < 300 else {
        // `MessageDeleteNotAllowed` is the lexicon 400 for this endpoint
        // (e.g. system messages can't be deleted).
        setInteractiveNetworkError(
          code: responseCode,
          context: "deleteMessageForSelf(\(messageId))",
          typedError: .messageDeleteNotAllowed,
          operation: "delete this message"
        )
        return false
      }

      // Remove message from local state
      if var originalMessages = originalMessagesMap[convoId] {
        originalMessages.removeValue(forKey: messageId)
        originalMessagesMap[convoId] = originalMessages
      }

      logger.debug("Message \(messageId) deleted successfully")
      return true

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Error deleting message \(messageId): \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "deleteMessageForSelf(\(messageId))",
        operation: "delete this message"
      )
      return false
    }
  }

  @MainActor
  func markAllConversationsAsRead() async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot mark all conversations as read: client is nil")
      errorState = .noClient
      return false
    }

     do {
        let (responseCode, _) = try await client.chat.bsky.convo.updateAllRead(input: .init())
        guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "markAllConversationsAsRead")
        return false
      }

      // Update local state - set all unread counts to 0
      for _ in conversations.indices {
        // Since ConvoView might be immutable, we'd need to refresh from server
        // For now, just refresh the conversation list
      }
      
      await loadConversations(refresh: true)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.debug("All conversations marked as read successfully")
      return true

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Error marking all conversations as read: \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  @MainActor
  func getConversationLog(cursor: String? = nil) async -> (logs: [ChatBskyConvoGetLog.OutputLogsUnion]?, cursor: String?) {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return (nil, nil) }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot get conversation log: client is nil")
      errorState = .noClient
      return (nil, nil)
    }

    let params = ChatBskyConvoGetLog.Parameters(cursor: cursor)
    do {
      let (responseCode, response) = try await client.chat.bsky.convo.getLog(input: params)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return (nil, nil) }

      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "getConversationLog")
        return (nil, nil)
      }

      guard let logData = response else {
        logger.error("No data returned from conversation log request")
        setEmptyResponseError(context: "getConversationLog")
        return (nil, nil)
      }

      logger.debug("Successfully retrieved conversation log with \(logData.logs.count) events")
      return (logData.logs, logData.cursor)

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return (nil, nil) }
      logger.error("Error getting conversation log: \(error.localizedDescription)")
      setErrorState(error)
      return (nil, nil)
    }
  }

  // MARK: - Delta Log Processing (P134)

  private func logCursorKey(for accountDID: String?) -> String? {
    guard let did = accountDID, !did.isEmpty else { return nil }
    return "chat.bsky.logCursor.\(did)"
  }

  private func getPersistedLogCursor() -> String? {
    guard let key = logCursorKey(for: pollingAccountDID) else { return nil }
    if let mem = logCursor { return mem }
    let saved = UserDefaults.standard.string(forKey: key)
    logCursor = saved
    return saved
  }

  private func persistLogCursor(_ cursor: String) {
    guard let key = logCursorKey(for: pollingAccountDID) else { return }
    logCursor = cursor
    UserDefaults.standard.set(cursor, forKey: key)
  }

  @MainActor
  func pollGetLog() async {
    guard let client = client, !pollingBarrier.isSuspended else { return }

    let currentCursor = getPersistedLogCursor()
    guard let currentCursor else {
      // First time: fetch latest cursor to establish cursor baseline
      let (_, cursor) = await getConversationLog(cursor: nil)
      if let cursor {
        persistLogCursor(cursor)
      }
      return
    }

    let (logs, newCursor) = await getConversationLog(cursor: currentCursor)
    if let newCursor, newCursor != currentCursor {
      persistLogCursor(newCursor)
    }

    if let logs, !logs.isEmpty {
      await applyLogEntries(logs)
      onUnreadCountChanged?()
      onConversationsPolled?()
    }
  }

  @MainActor
  private func applyLogEntries(_ entries: [ChatBskyConvoGetLog.OutputLogsUnion]) async {
    var convosNeedRefresh = false

    for entry in entries {
      switch entry {
      case .chatBskyConvoDefsLogCreateMessage(let log):
        switch log.message {
        case .chatBskyConvoDefsMessageView(let mv):
          var originals = originalMessagesMap[log.convoId] ?? [:]
          if originals[mv.id] != mv {
            originals[mv.id] = mv
            originalMessagesMap[log.convoId] = originals
            bumpConversationRevision(for: log.convoId)
          }
          if let idx = conversations.firstIndex(where: { $0.id == log.convoId }) {
            let existing = conversations[idx]
            let isCurrentViewer = mv.sender.did.didString() == pollingAccountDID
            let isViewing = activeConversationId == log.convoId
            let newUnread = (isCurrentViewer || isViewing) ? existing.unreadCount : existing.unreadCount + 1
            let updated = ChatBskyConvoDefs.ConvoView(
              id: existing.id,
              rev: log.rev,
              members: existing.members,
              lastMessage: .chatBskyConvoDefsMessageView(mv),
              muted: existing.muted,
              status: existing.status,
              unreadCount: newUnread
            )
            conversations[idx] = updated
            if idx > 0 {
              conversations.remove(at: idx)
              conversations.insert(updated, at: 0)
            }
            updateConversationsByStatus()
          } else {
            convosNeedRefresh = true
          }
        case .chatBskyConvoDefsDeletedMessageView(let dmv):
          if originalMessagesMap[log.convoId]?[dmv.id] != nil {
            originalMessagesMap[log.convoId]?.removeValue(forKey: dmv.id)
            bumpConversationRevision(for: log.convoId)
          }
        case .unexpected:
          convosNeedRefresh = true
        }

        if let related = log.relatedProfiles {
          var profiles = relatedProfilesMap[log.convoId] ?? [:]
          var changed = false
          for p in related {
            let did = p.did.didString()
            if profiles[did] != p {
              profiles[did] = p
              changed = true
            }
          }
          if changed {
            relatedProfilesMap[log.convoId] = profiles
            bumpConversationRevision(for: log.convoId)
          }
        }

      case .chatBskyConvoDefsLogDeleteMessage(let log):
        switch log.message {
        case .chatBskyConvoDefsDeletedMessageView(let dmv):
          if originalMessagesMap[log.convoId]?[dmv.id] != nil {
            originalMessagesMap[log.convoId]?.removeValue(forKey: dmv.id)
            bumpConversationRevision(for: log.convoId)
          }
          if let idx = conversations.firstIndex(where: { $0.id == log.convoId }),
             case .chatBskyConvoDefsMessageView(let last) = conversations[idx].lastMessage,
             last.id == dmv.id {
            convosNeedRefresh = true
          }
        case .chatBskyConvoDefsMessageView(let mv):
          if originalMessagesMap[log.convoId]?[mv.id] != nil {
            originalMessagesMap[log.convoId]?.removeValue(forKey: mv.id)
            bumpConversationRevision(for: log.convoId)
          }
          if let idx = conversations.firstIndex(where: { $0.id == log.convoId }),
             case .chatBskyConvoDefsMessageView(let last) = conversations[idx].lastMessage,
             last.id == mv.id {
            convosNeedRefresh = true
          }
        case .unexpected:
          convosNeedRefresh = true
        }

      case .chatBskyConvoDefsLogAddReaction(let log):
        switch log.message {
        case .chatBskyConvoDefsMessageView(let mv):
          var originals = originalMessagesMap[log.convoId] ?? [:]
          if originals[mv.id] != mv {
            originals[mv.id] = mv
            originalMessagesMap[log.convoId] = originals
            bumpConversationRevision(for: log.convoId)
          }
        default:
          convosNeedRefresh = true
        }
        if let related = log.relatedProfiles {
          var profiles = relatedProfilesMap[log.convoId] ?? [:]
          var changed = false
          for p in related {
            let did = p.did.didString()
            if profiles[did] != p {
              profiles[did] = p
              changed = true
            }
          }
          if changed {
            relatedProfilesMap[log.convoId] = profiles
            bumpConversationRevision(for: log.convoId)
          }
        }

      case .chatBskyConvoDefsLogRemoveReaction(let log):
        switch log.message {
        case .chatBskyConvoDefsMessageView(let mv):
          var originals = originalMessagesMap[log.convoId] ?? [:]
          if originals[mv.id] != mv {
            originals[mv.id] = mv
            originalMessagesMap[log.convoId] = originals
            bumpConversationRevision(for: log.convoId)
          }
        default:
          convosNeedRefresh = true
        }
        if let related = log.relatedProfiles {
          var profiles = relatedProfilesMap[log.convoId] ?? [:]
          var changed = false
          for p in related {
            let did = p.did.didString()
            if profiles[did] != p {
              profiles[did] = p
              changed = true
            }
          }
          if changed {
            relatedProfilesMap[log.convoId] = profiles
            bumpConversationRevision(for: log.convoId)
          }
        }

      case .chatBskyConvoDefsLogReadConvo(let log):
        if let idx = conversations.firstIndex(where: { $0.id == log.convoId }) {
          let existing = conversations[idx]
          if existing.unreadCount > 0 {
            conversations[idx] = ChatBskyConvoDefs.ConvoView(
              id: existing.id,
              rev: log.rev,
              members: existing.members,
              lastMessage: existing.lastMessage,
              muted: existing.muted,
              status: existing.status,
              unreadCount: 0
            )
            updateConversationsByStatus()
          }
        }

      case .chatBskyConvoDefsLogReadMessage(let log):
        if let idx = conversations.firstIndex(where: { $0.id == log.convoId }) {
          let existing = conversations[idx]
          if existing.unreadCount > 0 {
            conversations[idx] = ChatBskyConvoDefs.ConvoView(
              id: existing.id,
              rev: log.rev,
              members: existing.members,
              lastMessage: existing.lastMessage,
              muted: existing.muted,
              status: existing.status,
              unreadCount: 0
            )
            updateConversationsByStatus()
          }
        }

      case .chatBskyConvoDefsLogMuteConvo(let log):
        if let idx = conversations.firstIndex(where: { $0.id == log.convoId }) {
          let existing = conversations[idx]
          if !existing.muted {
            conversations[idx] = ChatBskyConvoDefs.ConvoView(
              id: existing.id,
              rev: log.rev,
              members: existing.members,
              lastMessage: existing.lastMessage,
              muted: true,
              status: existing.status,
              unreadCount: existing.unreadCount
            )
            updateConversationsByStatus()
          }
        } else {
          convosNeedRefresh = true
        }

      case .chatBskyConvoDefsLogUnmuteConvo(let log):
        if let idx = conversations.firstIndex(where: { $0.id == log.convoId }) {
          let existing = conversations[idx]
          if existing.muted {
            conversations[idx] = ChatBskyConvoDefs.ConvoView(
              id: existing.id,
              rev: log.rev,
              members: existing.members,
              lastMessage: existing.lastMessage,
              muted: false,
              status: existing.status,
              unreadCount: existing.unreadCount
            )
            updateConversationsByStatus()
          }
        } else {
          convosNeedRefresh = true
        }

      case .chatBskyConvoDefsLogLeaveConvo(let log):
        if let idx = conversations.firstIndex(where: { $0.id == log.convoId }) {
          conversations.remove(at: idx)
          updateConversationsByStatus()
        }
        convosNeedRefresh = true

      case .chatBskyConvoDefsLogBeginConvo, .chatBskyConvoDefsLogAcceptConvo:
        convosNeedRefresh = true

      default:
        logger.debug("Unknown getLog event encountered: \(String(describing: entry)), triggering full reconcile")
        convosNeedRefresh = true
      }
    }

    if convosNeedRefresh {
      await loadConversations(refresh: true)
    }
  }

  // MARK: - Reaction Actions (Live)
  @MainActor
  func toggleReaction(convoId: String, messageId: String, emoji: String) async throws {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { throw CancellationError() }
    defer { pollingBarrier.finish(ticket) }

    do {
      // Validate input parameters to prevent crashes
      guard !convoId.isEmpty, !messageId.isEmpty, !emoji.isEmpty else {
        logger.error("Invalid parameters for toggleReaction: convoId='\(convoId)', messageId='\(messageId)', emoji='\(emoji)'")
        return
      }
      
      // Safely check if the user has already reacted with this emoji
      guard let convoMessages = originalMessagesMap[convoId],
            let messageView = convoMessages[messageId] else { 
        logger.warning("Message not found in originalMessagesMap for convoId='\(convoId)', messageId='\(messageId)'")
        return 
      }

      // Get the current user's DID first
      let currentUserDid = try await client?.getDid()
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { throw CancellationError() }

      // Then use it in the contains check
      let hasReacted =
        messageView.reactions?.contains(where: {
          $0.value == emoji && $0.sender.did.didString() == currentUserDid
        }) ?? false

      if hasReacted {
        _ = await removeReaction(convoId: convoId, messageId: messageId, emoji: emoji)
        guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { throw CancellationError() }
      } else {
        _ = await addReaction(convoId: convoId, messageId: messageId, emoji: emoji)
        guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { throw CancellationError() }
      }
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { throw CancellationError() }
      logger.error("Error in toggleReaction: \(error.localizedDescription)")
      
      // Only set error state for non-cancellation errors to prevent alert loops
      if shouldShowError(error) {
        setErrorState(error)
      }
      
      // Re-throw only non-cancellation errors to maintain API contract while preventing loops
      if shouldShowError(error) {
        throw error
      }
      // For cancellation errors, we silently return without throwing
    }
  }

  @MainActor
  private func addReaction(convoId: String, messageId: String, emoji: String) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else { return false }
    do {
      guard let source = appState else { throw AuthError.clientNotInitialized }
      let input = ChatBskyConvoAddReaction.Input(
        convoId: convoId, messageId: messageId, value: emoji)
         try await requireMessagingAccess(source: source, client: client, ticket: ticket, convoId: convoId)
         let (responseCode, response) = try await client.chat.bsky.convo.addReaction(input: input)
         guard isCurrentPollingOperation(ticket, client: client), appState === source else { return false }
       guard responseCode >= 200 && responseCode < 300 else {
        let typedError = await addReactionTypedError(convoId: convoId, messageId: messageId)
        guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
        setInteractiveNetworkError(
          code: responseCode,
          context: "addReaction(\(messageId))",
          typedError: typedError,
          operation: "add this reaction"
        )
        return false
      }
      guard let updated = response?.message else {
        return false
      }
      await updateMessageInLocalState(updated)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      return true
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Failed to add reaction: \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "addReaction(\(messageId))",
        operation: "add this reaction"
      )
      return false
    }
  }

  @MainActor
  private func removeReaction(convoId: String, messageId: String, emoji: String) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else { return false }
    do {
      let input = ChatBskyConvoRemoveReaction.Input(
        convoId: convoId, messageId: messageId, value: emoji)
         let (responseCode, response) = try await client.chat.bsky.convo.removeReaction(input: input)
         guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
       guard responseCode >= 200 && responseCode < 300 else {
        // Locked convos block reaction changes; otherwise `ReactionNotAllowed`
        // is the lexicon 400 for removeReaction.
        let typedError: ChatError =
          conversation(withID: convoId)?.isLockedForSending == true
            ? .conversationLocked : .reactionNotAllowed
        setInteractiveNetworkError(
          code: responseCode,
          context: "removeReaction(\(messageId))",
          typedError: typedError,
          operation: "remove this reaction"
        )
        return false
      }
      guard let updated = response?.message else {
        return false
      }
      await updateMessageInLocalState(updated)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      return true
    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Failed to remove reaction: \(error.localizedDescription)")
      setInteractiveThrownError(
        error,
        context: "removeReaction(\(messageId))",
        operation: "remove this reaction"
      )
      return false
    }
  }

  // MARK: - Search Methods

  /// Search for conversations locally and fetch remote actor suggestions for starting new chats
  @MainActor
  func searchLocal(searchTerm: String, currentUserDID: String?) {
    guard !pollingBarrier.isSuspended else { return }
    logger.debug("Performing chat search for: \(searchTerm)")

    actorSearchTask?.cancel()

    let trimmedTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTerm.isEmpty else {
      filteredConversations = []
      filteredProfiles = []
      pendingActorSearchQuery = ""
      actorSearchTask = nil
      return
    }

    let normalizedSearch = trimmedTerm.lowercased()

    // Filter conversations based on three criteria:
    // 1. Member names/handles
    // 2. Last message content
    // 3. Messages in the conversation
    if let did = currentUserDID {
      filteredConversations = conversations.filter { convo in
        // 1. Check if any member matches (except current user)
        let otherMembers = convo.members.filter { $0.did.didString() != did }
        let memberMatches = otherMembers.contains { member in
          let nameMatch = member.displayName?.lowercased().contains(normalizedSearch) ?? false
          let handleMatch = member.handle.description.lowercased().contains(normalizedSearch)
          return nameMatch || handleMatch
        }

        if memberMatches {
          return true
        }

        // 2. Check last message
        if let lastMessage = convo.lastMessage {
          switch lastMessage {
          case .chatBskyConvoDefsMessageView(let messageView):
            if messageView.text.lowercased().contains(normalizedSearch) {
              return true
            }
          default:
            break
          }
        }

        // 3. Check message content in the loaded messages for this conversation
        if let convoMessages = originalMessagesMap[convo.id] {
          for messageView in convoMessages.values {
            if messageView.text.lowercased().contains(normalizedSearch) {
              return true
            }
          }
        }

        return false
      }
    } else {
      filteredConversations = []
    }

    // Reset profiles while we fetch remote suggestions
    filteredProfiles = []
    pendingActorSearchQuery = trimmedTerm

    guard trimmedTerm.count >= 2 else {
      return
    }

    let query = trimmedTerm
    let debounceDelay = actorSearchDebounceNanoseconds
    actorSearchTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: debounceDelay)
      guard !Task.isCancelled else { return }
      await self?.performRemoteActorSearch(query: query, currentUserDID: currentUserDID)
    }

      logger.debug("Chat search matched \(self.filteredConversations.count) conversations locally; awaiting remote contacts")
  }

  @MainActor
  private func performRemoteActorSearch(query: String, currentUserDID: String?) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    guard let client else {
      await MainActor.run { [self, query] in
        if self.pollingBarrier.isCurrent(ticket, accountDID: self.pollingAccountDID), self.pendingActorSearchQuery == query {
          self.filteredProfiles = []
        }
      }
      return
    }

    do {
      let params = AppBskyActorSearchActorsTypeahead.Parameters(q: query, limit: 25)
      let (responseCode, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)
      guard isCurrentPollingOperation(ticket, client: client) else { return }

      guard (200..<300).contains(responseCode) else {
        logger.error("Typeahead search failed with HTTP \(responseCode)")
        await MainActor.run { [query] in
          if self.pollingBarrier.isCurrent(ticket, accountDID: self.pollingAccountDID), self.pendingActorSearchQuery == query {
            self.filteredProfiles = []
          }
        }
        return
      }

      guard !Task.isCancelled else { return }

      let remoteProfiles = response?.actors ?? []
      let filteredResults = remoteProfiles.filter { profile in
        profile.did.didString() != currentUserDID
      }

      await MainActor.run { [self, query, filteredResults] in
        guard self.isCurrentPollingOperation(ticket, client: client), self.pendingActorSearchQuery == query else { return }
          self.filteredProfiles = filteredResults.map { profile in
              ChatBskyActorDefs.ProfileViewBasic(
                    did: profile.did,
                    handle: profile.handle,
                    displayName: profile.displayName,
                    avatar: profile.avatar,
                    associated: profile.associated,
                    viewer: profile.viewer,
                    labels: profile.labels,
                    createdAt: profile.createdAt,
                    chatDisabled: profile.associated?.chat?.allowIncoming == "none"
                        || (profile.associated?.chat?.allowIncoming == "following" && profile.viewer?.followedBy == nil),
                    verification: profile.verification,
                    kind: nil
                )
          }
        self.logger.debug("Typeahead search returned \(filteredResults.count) contacts for query: \(query)")
      }
    } catch {
      guard isCurrentPollingOperation(ticket, client: client) else { return }
      guard !(error is CancellationError) else { return }
      logger.error("Typeahead search error: \(error.localizedDescription)")
      await MainActor.run { [self, query] in
        if self.pollingBarrier.isCurrent(ticket, accountDID: self.pollingAccountDID), self.pendingActorSearchQuery == query {
          self.filteredProfiles = []
        }
      }
    }
  }

  // MARK: - Helper Methods

  /// Synchronizes member profiles from loaded conversations directly into ProfileCacheDatabase (P145).
  /// Uses member data already present in ConvoView without making redundant getProfiles XRPC calls,
  /// and writes in a single batch transaction only for members whose signatures changed.
  @MainActor
  private func syncConversationMemberProfiles(from convos: [ChatBskyConvoDefs.ConvoView]) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    var profilesToWrite: [(did: String, handle: String, displayName: String?, avatarURL: String?)] = []

    for convo in convos {
      for member in convo.members {
        let did = member.did.didString()
        let handle = member.handle.description
        let displayName = member.displayName
        let avatarURL = member.avatar?.uriString()
        let signature = "\(handle)|\(displayName ?? "")|\(avatarURL ?? "")"

        if profileSignatureCache[did] != signature {
          profileSignatureCache[did] = signature
          profilesToWrite.append((did: did, handle: handle, displayName: displayName, avatarURL: avatarURL))
        }
      }
    }

    guard !profilesToWrite.isEmpty else { return }
    guard let client = self.client else { return }
    guard isCurrentPollingOperation(ticket, client: client) else { return }
    await ProfileCacheDatabase.shared.write(profiles: profilesToWrite)
  }

  // MARK: - Message Conversion (Legacy ExyteChat methods removed)
  // Message creation is now handled by BlueskyMessageAdapter in UnifiedChat/Models/

  /// Updates a specific message within the originalMessagesMap based on an updated MessageView.
  @MainActor
  private func updateMessageInLocalState(_ updatedMessageView: ChatBskyConvoDefs.MessageView) async {
    // Find the conversation containing this message and update the original message view
    for (convoId, messages) in originalMessagesMap {
      if messages[updatedMessageView.id] != nil {
        var updatedMessages = messages
        updatedMessages[updatedMessageView.id] = updatedMessageView
        originalMessagesMap[convoId] = updatedMessages

        logger.debug("Updated message \(updatedMessageView.id) in local state for convo \(convoId)")
        return
      }
    }
    logger.warning("Could not find message \(updatedMessageView.id) in local state to update.")
  }

  /// Updates the `lastMessage` of a conversation after a send and moves it to
  /// the top of the list, matching the server's most-recent-activity order.
  @MainActor
  private func updateConversationLastMessage(
    convoId: String, messageView: ChatBskyConvoDefs.MessageView
  ) {
    guard let index = conversations.firstIndex(where: { $0.id == convoId }) else { return }
    let convo = conversations.remove(at: index)
    let updatedConvo = ChatBskyConvoDefs.ConvoView(
      id: convo.id,
      rev: convo.rev,
      members: convo.members,
      lastMessage: .chatBskyConvoDefsMessageView(messageView),
      lastReaction: convo.lastReaction,
      muted: convo.muted,
      status: convo.status,
      unreadCount: convo.unreadCount,
      kind: convo.kind
    )
    conversations.insert(updatedConvo, at: 0)
    updateConversationsByStatus()
  }

  // MARK: - Actor Management Methods

  @MainActor
  func exportChatAccountData() async -> Data? {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return nil }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot export chat account data: client is nil")
      errorState = .noClient
      return nil
    }

     do {
      let (responseCode, output) = try await client.chat.bsky.actor.exportAccountData()
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "exportChatAccountData")
        return nil
      }

      logger.debug("Successfully exported chat account data")
      // The output wraps the raw JSON Lines export body
      return output?.data

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
      logger.error("Error exporting chat account data: \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  /// Deletes the account's chat data on the server. Returns `true` once the
  /// server has confirmed the deletion and local chat state is cleared.
  @MainActor
  func deleteChatAccount() async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot delete chat account: client is nil")
      errorState = .noClient
      return false
    }

     do {
      let (responseCode, _) = try await client.chat.bsky.actor.deleteAccount()
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "deleteChatAccount")
        return false
      }

      // Clear all local chat data after successful deletion
      if let key = logCursorKey(for: pollingAccountDID) {
        UserDefaults.standard.removeObject(forKey: key)
      }
      clearChatData()
      updateConversationsByStatus()
      onUnreadCountChanged?()
      logger.debug("Successfully deleted chat account")
      return true

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Error deleting chat account: \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  // MARK: - Moderation Methods

  @MainActor
  func getActorMetadata(actor: String) async -> ChatBskyModerationGetActorMetadata.Output? {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return nil }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot get actor metadata: client is nil")
      errorState = .noClient
      return nil
    }

    do {
      let params = ChatBskyModerationGetActorMetadata.Parameters(
        actor: try DID(didString: actor)
      )
         
      let (responseCode, response) = try await client.chat.bsky.moderation.getActorMetadata(input: params)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "getActorMetadata((actor))")
        return nil
      }

      logger.debug("Successfully retrieved actor metadata for \(actor)")
      return response

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
      logger.error("Error getting actor metadata for \(actor): \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  @MainActor
  func getMessageContext(convoId: String, messageId: String, before: Int? = nil, after: Int? = nil) async -> ChatBskyModerationGetMessageContext.Output? {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return nil }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot get message context: client is nil")
      errorState = .noClient
      return nil
    }

    let params = ChatBskyModerationGetMessageContext.Parameters(
      convoId: convoId,
      messageId: messageId,
      before: before,
      after: after
    )
     do {
      let (responseCode, response) = try await client.chat.bsky.moderation.getMessageContext(input: params)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "getMessageContext((messageId))")
        return nil
      }

      logger.debug("Successfully retrieved message context for \(messageId)")
      return response

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return nil }
      logger.error("Error getting message context for \(messageId): \(error.localizedDescription)")
      setErrorState(error)
      return nil
    }
  }

  @MainActor
  func updateActorAccess(actor: String, allowAccess: Bool, ref: String? = nil) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot update actor access: client is nil")
      errorState = .noClient
      return false
    }

    do {
      let input = ChatBskyModerationUpdateActorAccess.Input(
        actor: try DID(didString: actor),
        allowAccess: allowAccess,
        ref: ref
      )
         
      let responseCode = try await client.chat.bsky.moderation.updateActorAccess(input: input)
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "updateActorAccess((actor))")
        return false
      }

      logger.debug("Successfully updated actor access for \(actor) to \(allowAccess)")
      return true

    } catch {
      guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
      logger.error("Error updating actor access for \(actor): \(error.localizedDescription)")
      setErrorState(error)
      return false
    }
  }

  // MARK: - Message Requests Management
  
  /// Updates the message requests and accepted conversations lists based on status
  @MainActor
  func updateConversationsByStatus() {
    messageRequests = conversations.filter { $0.status?.rawValue == "request" }
    acceptedConversations = conversations.filter { $0.status?.rawValue == "accepted" || $0.status == nil }
    
      logger.debug("Updated conversation lists: \(self.messageRequests.count) requests, \(self.acceptedConversations.count) accepted")
  }
  
  /// Loads conversations with a specific status filter
  @MainActor
  func loadMessageRequests(refresh: Bool = false) async {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return }
    defer { pollingBarrier.finish(ticket) }

    guard let client = client else {
      logger.error("Cannot load message requests: client is nil")
      errorState = .noClient
      return
    }

    guard !loadingConversations else { return }
    do {
      loadingConversations = true
      conversationLoadID = ticket.id
      defer {
        if conversationLoadID == ticket.id {
          loadingConversations = false
          conversationLoadID = nil
        }
      }
      errorState = nil

      let cursorToUse = refresh ? nil : conversationsCursor

      let params = ChatBskyConvoListConvos.Parameters(
        limit: 20,
        cursor: cursorToUse,
        readState: nil,
        status: "request"  // Filter for requests only
      )

      logger.debug("Loading message requests with cursor: \(cursorToUse ?? "nil")")
         let (responseCode, response) = try await client.chat.bsky.convo.listConvos(input: params)
      guard isCurrentPollingOperation(ticket, client: client) else { return }
 
      guard responseCode >= 200 && responseCode < 300 else {
        setNetworkError(code: responseCode, context: "loadMessageRequests")
        loadingConversations = false
        return
      }

      guard let convosData = response else {
        logger.error("No data returned from message requests request")
        setEmptyResponseError(context: "loadMessageRequests")
        loadingConversations = false
        return
      }

      // Update message requests specifically
      if refresh {
        messageRequests = convosData.convos
      } else {
        let existingIDs = Set(messageRequests.map { $0.id })
        let newRequests = convosData.convos.filter { !existingIDs.contains($0.id) }
        messageRequests.append(contentsOf: newRequests)
      }

      logger.debug("Loaded \(convosData.convos.count) message requests")

    } catch {
      guard isCurrentPollingOperation(ticket, client: client) else { return }
      logger.error("Error loading message requests: \(error.localizedDescription)")
      setErrorState(error)
    }

    loadingConversations = false
  }
  
  /// Accepts a message request and moves it to accepted conversations
  @MainActor
  func acceptMessageRequest(convoId: String) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    let success = await acceptConversation(convoId: convoId)
    guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
    if success {
      // Move conversation from requests to accepted
      if let requestIndex = messageRequests.firstIndex(where: { $0.id == convoId }) {
        let conversation = messageRequests.remove(at: requestIndex)
        // Update status to accepted (this would normally come from server)
        // Note: We can't modify the struct directly, so we'll rely on the next refresh
        acceptedConversations.insert(conversation, at: 0)
        
        // Also update the main conversations list
        if let mainIndex = conversations.firstIndex(where: { $0.id == convoId }) {
          conversations.remove(at: mainIndex)
          conversations.insert(conversation, at: 0)
        }
      }
    }
    return success
  }
  
  /// Declines a message request
  @MainActor
  func declineMessageRequest(convoId: String) async -> Bool {
    guard let ticket = pollingBarrier.begin(accountDID: pollingAccountDID) else { return false }
    defer { pollingBarrier.finish(ticket) }

    guard await leaveConversation(convoId: convoId) == .success else { return false }
    guard !Task.isCancelled, pollingBarrier.isCurrent(ticket, accountDID: pollingAccountDID) else { return false }
    // Remove from message requests
    messageRequests.removeAll { $0.id == convoId }
    // Note: leaveConversation already removes from main conversations list
    return true
  }
  
  /// Gets the count of unread message requests
  var unreadMessageRequestsCount: Int {
    messageRequests.reduce(0) { $0 + $1.unreadCount }
  }
  
  /// Gets the total count of message requests
  var messageRequestsCount: Int {
    messageRequests.count
  }
  
  /// Gets the total count of unread messages across all conversations
  var totalUnreadCount: Int {
    conversations.reduce(0) { $0 + $1.unreadCount }
  }
  
  // MARK: - Polling Methods
  
  /// Starts polling for conversation updates
  func startConversationsPolling() {
    guard !pollingBarrier.isSuspended else { return }
    stopConversationsPolling()

    conversationsPollingTask = Task { [weak self] in
      guard let self = self else { return }

      while !Task.isCancelled {
        let pollStatus = await MainActor.run { () -> (shouldPoll: Bool, interval: TimeInterval) in
          guard self.isAppActive, !self.pollingBarrier.isSuspended else {
            return (false, self.backgroundPollInterval)
          }
          if self.activeConversationId != nil {
            return (true, self.activeConversationPollInterval)
          }
          if self.isChatTabVisible {
            return (true, self.activeListPollInterval)
          }
          let hasBadgeConsumer = self.onUnreadCountChanged != nil || self.onConversationsPolled != nil
          if hasBadgeConsumer {
            return (true, 60.0)
          }
          // Polling gated off: neither chat tab nor active conversation is visible, and no badge consumers need it
          return (false, 60.0)
        }

        do {
          try await Task.sleep(nanoseconds: UInt64(pollStatus.interval * 1_000_000_000))
        } catch {
          break
        }

        guard !Task.isCancelled else { break }

        guard pollStatus.shouldPoll else { continue }

        let shouldSkip = await MainActor.run {
          !self.isAppActive || self.pollingBarrier.isSuspended
        }
        if shouldSkip { continue }

        // Use getLog cursor events rather than full snapshot listConvos
        await self.pollGetLog()

        // Slow reconcile if 5+ minutes passed
        let needsReconcile = await MainActor.run { () -> Bool in
          guard !Task.isCancelled, !self.pollingBarrier.isSuspended else { return false }
          return Date().timeIntervalSince(self.lastFullReconcileTime) >= self.fullReconcileInterval
        }
        if needsReconcile {
          await self.loadConversations(refresh: true)
          await MainActor.run {
            self.lastFullReconcileTime = Date()
          }
        }
      }
    }

    logger.debug("Started conversations polling")
  }
  
  /// Stops polling for conversation updates
  func stopConversationsPolling() {
    resumeConversationPolling = false
    conversationsPollingTask?.cancel()
    conversationsPollingTask = nil
    logger.debug("Stopped conversations polling")
  }
  
  /// Starts polling for messages in a specific conversation
  func startMessagePolling(for convoId: String) {
    guard !pollingBarrier.isSuspended else { return }
    stopMessagePolling(for: convoId)
    activeConversationId = convoId
    // Re-arm conversation polling so it immediately adapts to the 5s active conversation cadence
    startConversationsPolling()
    logger.debug("Started message polling for conversation \(convoId)")
  }
  
  /// Stops polling for messages in a specific conversation
  func stopMessagePolling(for convoId: String) {
    resumeMessagePolling.remove(convoId)
    messagePollingTasks[convoId]?.cancel()
    messagePollingTasks[convoId] = nil
    messagePollBackoffs[convoId] = nil
    if activeConversationId == convoId {
      activeConversationId = nil
      startConversationsPolling()
    }
    logger.debug("Stopped message polling for conversation \(convoId)")
  }
  
  /// Stops all polling tasks
  func stopAllPolling() {
    stopConversationsPolling()
    resumeMessagePolling.removeAll()
    
    for convoId in messagePollingTasks.keys {
      stopMessagePolling(for: convoId)
    }

    logger.debug("Stopped all polling tasks")
  }

  // MARK: - Rate-Limit Backoff

  /// Whether a thrown Petrel error is rate-limit-shaped (HTTP 429).
  private func isRateLimitError(_ error: Error) -> Bool {
    if case let Petrel.NetworkError.responseError(statusCode) = error, statusCode == 429 {
      return true
    }
    return false
  }

  /// Doubles the conversations poll interval after a rate limit, up to the cap.
  private func increaseConversationsPollBackoff() {
    let current = max(conversationsPollBackoff, activeListPollInterval)
    conversationsPollBackoff = min(current * 2, maxPollBackoffInterval)
    logger.warning(
      "Rate limited (429) on listConvos, backing conversations polling off to \(self.conversationsPollBackoff)s")
  }

  /// Doubles the message poll interval for a conversation after a rate limit, up to the cap.
  private func increaseMessagePollBackoff(for convoId: String) {
    let current = max(messagePollBackoffs[convoId] ?? 0, activeConversationPollInterval)
    let backoff = min(current * 2, maxPollBackoffInterval)
    messagePollBackoffs[convoId] = backoff
    logger.warning(
      "Rate limited (429) on getMessages for \(convoId), backing message polling off to \(backoff)s")
  }

  // MARK: - Supporting Types
  
  struct PendingMessage {
    let tempId: String
    let convoId: String
    let text: String
    let timestamp: Date
    var retryCount: Int = 0
  }
  
  enum MessageDeliveryStatus: Equatable {
    case sending
    case sent
    case delivered
    case failed(Error?)
    
    static func == (lhs: MessageDeliveryStatus, rhs: MessageDeliveryStatus) -> Bool {
      switch (lhs, rhs) {
      case (.sending, .sending), (.sent, .sent), (.delivered, .delivered):
        return true
      case (.failed, .failed):
        return true
      default:
        return false
      }
    }
  }

  // MARK: - Error Enum

  enum ChatError: Error, LocalizedError, Equatable {
    case noClient
    case networkError(code: Int)
    case emptyResponse
    case generalError(Error)
    case ownerCannotLeave
    case conversationLocked
    case messageDeleteNotAllowed
    case reactionNotAllowed
    case reactionLimitReached
    /// Message text exceeds `maxMessageGraphemes`.
    case messageTooLong
    /// The other person's chat settings don't allow a conversation with you.
    case recipientNotAccepting
    /// One or more selected people can't be added to a new group.
    case groupMembersUnavailable
    /// A validation failure whose text is already user-readable.
    case invalidInput(String)
    /// Generic user-readable failure for an interactive operation that doesn't
    /// map to a lexicon-defined error. `operation` is a verb phrase, e.g.
    /// "send this message".
    case operationFailed(operation: String)

    var errorDescription: String? {
      switch self {
      case .noClient:
        return NSLocalizedString("Sign in to use Messages.", comment: "Chat error")
      case .networkError(let code):
        switch code {
        case 401:
          return NSLocalizedString("Your session expired. Sign in again.", comment: "Chat error")
        case 403:
          return NSLocalizedString("You don’t have permission to do that.", comment: "Chat error")
        case 400:
          return NSLocalizedString("This action isn’t allowed right now.", comment: "Chat error")
        case 429:
          return NSLocalizedString("Too many requests. Wait a moment and try again.", comment: "Chat error")
        default:
          return NSLocalizedString(
            "Couldn’t reach Bluesky chat. Check your connection and try again.", comment: "Chat error")
        }
      case .emptyResponse:
        return NSLocalizedString(
          "Bluesky chat didn’t respond. Try again.", comment: "Chat error")
      case .generalError(let error):
        return UserFacingError.message(for: error, action: "reach Bluesky chat")
          ?? NSLocalizedString("Something went wrong. Try again.", comment: "Chat error")
      case .ownerCannotLeave:
        return NSLocalizedString(
          "You own this group, so you need to lock it before you can leave.",
          comment: "Chat error")
      case .conversationLocked:
        return NSLocalizedString(
          "This conversation is locked. New messages and reactions are disabled.",
          comment: "Chat error")
      case .messageDeleteNotAllowed:
        return NSLocalizedString("This message can’t be deleted.", comment: "Chat error")
      case .reactionNotAllowed:
        return NSLocalizedString(
          "Reactions aren’t allowed on this message.", comment: "Chat error")
      case .reactionLimitReached:
        return NSLocalizedString(
          "You’ve reached the maximum number of reactions for this message.",
          comment: "Chat error")
      case .messageTooLong:
        return NSLocalizedString(
          "Messages can be up to 1,000 characters.", comment: "Chat error")
      case .recipientNotAccepting:
        return NSLocalizedString(
          "This person isn’t accepting messages from you.", comment: "Chat error")
      case .groupMembersUnavailable:
        return NSLocalizedString(
          "Some of these people can’t be added to a group.", comment: "Chat error")
      case .invalidInput(let message):
        return message
      case .operationFailed(let operation):
        return String(
          format: NSLocalizedString("Couldn’t %@. Please try again.", comment: "Chat error"),
          operation)
      }
    }

    // Equatable conformance for potential UI state comparison
    static func == (lhs: ChatError, rhs: ChatError) -> Bool {
      switch (lhs, rhs) {
      case (.noClient, .noClient):
        return true
      case (.networkError(let lCode), .networkError(let rCode)):
        return lCode == rCode
      case (.emptyResponse, .emptyResponse):
        return true
      case (.generalError(let lError), .generalError(let rError)):
        // Comparing underlying errors can be tricky, often comparing descriptions is sufficient for UI
        return lError.localizedDescription == rError.localizedDescription
      case (.ownerCannotLeave, .ownerCannotLeave),
           (.conversationLocked, .conversationLocked),
           (.messageDeleteNotAllowed, .messageDeleteNotAllowed),
           (.reactionNotAllowed, .reactionNotAllowed),
           (.reactionLimitReached, .reactionLimitReached),
           (.messageTooLong, .messageTooLong),
           (.recipientNotAccepting, .recipientNotAccepting),
           (.groupMembersUnavailable, .groupMembersUnavailable):
        return true
      case (.invalidInput(let lMessage), .invalidInput(let rMessage)):
        return lMessage == rMessage
      case (.operationFailed(let lOperation), .operationFailed(let rOperation)):
        return lOperation == rOperation
      default:
        return false
      }
    }
  }
  
  // MARK: - Error Handling Helpers
  
  /// Helper method to determine if an error should be shown to the user
  private func shouldShowError(_ error: Error) -> Bool {
    // Don't show cancellation errors to users - these are expected during normal operation
    if error is CancellationError {
      logger.debug("Ignoring cancellation error: \(error.localizedDescription)")
      return false
    }
    
    // Filter out transient network errors that occur during background polling
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .networkConnectionLost, .notConnectedToInternet,
           .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
        logger.debug("Ignoring transient network error during polling: \(error.localizedDescription)")
        return false
      default:
        break
      }
    }
    
    // Check if the error description contains transient error indicators (case insensitive)
    let errorDescription = error.localizedDescription.lowercased()
    if errorDescription.contains("cancelled") || errorDescription.contains("canceled") {
      logger.debug("Ignoring cancellation-related error: \(error.localizedDescription)")
      return false
    }
    
    // Filter out retry-related errors - these are transient and will recover
    if errorDescription.contains("retry") || errorDescription.contains("timeout") {
      logger.debug("Ignoring transient error during polling: \(error.localizedDescription)")
      return false
    }
    
    return true
  }
  
  /// Helper method to safely set error state for network errors, filtering transient issues
  private func setNetworkError(code: Int, context: String) {
    // Only show errors that require user action
    // Auth errors (401, 403) need user to re-authenticate
    if code == 401 || code == 403 {
      logger.error("\(context): Authentication error (HTTP \(code))")
      errorState = .networkError(code: code)
      return
    }
    
    // Server errors (5xx) and other errors are transient during polling
    // Log them for debugging but don't spam the user
    if code >= 500 {
      logger.warning("\(context): Transient server error (HTTP \(code)), will retry on next poll")
    } else {
      logger.warning("\(context): Network error (HTTP \(code)), will retry on next poll")
    }
    // Don't set errorState for transient errors during background polling
  }
  
  /// Error surfacing for user-initiated operations (leave, lock, send, delete,
  /// reactions). Unlike `setNetworkError` — used by poll loops, which stay
  /// silent for non-auth codes — interactive failures always surface to the
  /// user. Lexicon-defined errors arrive as HTTP 400, whose body Petrel's
  /// generated wrappers drop, so callers pass the typed error they can infer
  /// from operation context and local conversation state; everything else
  /// falls back to a generic user-readable failure message.
  @MainActor
  private func setInteractiveNetworkError(
    code: Int, context: String, typedError: ChatError? = nil, operation: String
  ) {
    if code == 401 || code == 403 {
      logger.error("\(context): Authentication error (HTTP \(code))")
      errorState = .networkError(code: code)
      return
    }

    if code == 400, let typedError {
      logger.error("\(context): \(String(describing: typedError)) (HTTP 400)")
      errorState = typedError
      return
    }

    logger.error("\(context): HTTP \(code)")
    errorState = .operationFailed(operation: operation)
  }

  /// Thrown-path counterpart to `setInteractiveNetworkError`. Petrel throws
  /// for every non-400 failure (402–499 as `responseError`, exhausted-retry
  /// 5xx, unrecoverable 401s as `authenticationRequired`, plus transport
  /// errors), so user-initiated operations route thrown errors here to keep
  /// the always-surface contract; only genuine cancellation stays silent.
  @MainActor
  private func setInteractiveThrownError(_ error: Error, context: String, operation: String) {
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
      logger.debug("\(context): cancelled, not surfacing")
      return
    }
    if case let Petrel.NetworkError.responseError(statusCode) = error {
      setInteractiveNetworkError(code: statusCode, context: context, operation: operation)
      return
    }
    if case Petrel.NetworkError.authenticationRequired = error {
      errorState = .networkError(code: 401)
      return
    }
    errorState = .operationFailed(operation: operation)
  }

  /// Looks up a conversation in local state by id.
  @MainActor
  private func conversation(withID convoId: String) -> ChatBskyConvoDefs.ConvoView? {
    conversations.first(where: { $0.id == convoId })
  }

  /// Whether the current user is the owner of the given group conversation,
  /// based on locally-loaded member roles.
  @MainActor
  private func isCurrentUserGroupOwner(convoId: String) async -> Bool {
    guard let convo = conversation(withID: convoId) else { return false }
    let currentUserDID: String?
    if let activeClientDid {
      currentUserDID = activeClientDid
    } else {
      currentUserDID = try? await client?.getDid()
    }
    guard let currentUserDID else { return false }
    return convo.isOwnedGroupConversation(currentUserDID: currentUserDID)
  }

  /// Best-available mapping for a failed addReaction (the XRPC error name is
  /// not exposed by the generated wrapper): a locked convo blocks reactions
  /// outright; otherwise, if the user already has reactions on this message,
  /// the add-only `ReactionLimitReached` is the plausible cause — a blanket
  /// `ReactionNotAllowed` would have rejected their earlier reactions too.
  @MainActor
  private func addReactionTypedError(convoId: String, messageId: String) async -> ChatError {
    if conversation(withID: convoId)?.isLockedForSending == true {
      return .conversationLocked
    }
    let currentUserDid = try? await client?.getDid()
    let existingReactions = originalMessagesMap[convoId]?[messageId]?.reactions?.filter {
      $0.sender.did.didString() == currentUserDid
    } ?? []
    return existingReactions.isEmpty ? .reactionNotAllowed : .reactionLimitReached
  }

  /// Helper method to safely set error state for empty responses during polling
  private func setEmptyResponseError(context: String) {
    // Empty responses during polling are transient - server may be temporarily overloaded
    // Log for debugging but don't spam user
    logger.warning("\(context): Empty response from server, will retry on next poll")
    // Don't set errorState for transient empty responses during background polling
  }
  
  /// Helper method to safely set error state, filtering out cancellation and transient errors
  private func setErrorState(_ error: Error) {
    if shouldShowError(error) {
      errorState = .generalError(error)
    }
  }
}
