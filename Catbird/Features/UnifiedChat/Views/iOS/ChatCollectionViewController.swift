#if os(iOS)
import NukeUI
import Observation
import os
import SwiftUI
import UIKit
#if DEBUG
import Petrel
#endif

@available(iOS 16.0, *)
final class ChatCollectionViewController<DataSource: UnifiedChatDataSource>: UIViewController,
  UICollectionViewDelegateFlowLayout,
  UICollectionViewDataSourcePrefetching
{
  typealias Message = DataSource.Message
  private let chatLogger = Logger(subsystem: "blue.catbird", category: "ChatCollectionVC")

  // MARK: - Types

  private enum Section: Int, CaseIterable {
    case messages
  }

  /// Wrapper for typing indicator avatar URL to avoid UIKit's NSNull crash
  /// when using Optional types with CellRegistration.
  private struct TypingAvatarItem: Hashable {
    let avatarURL: URL?
  }

  private enum Item: Hashable {
    case message(id: String)
    case dateSeparator(Date)
    case typingIndicator(TypingAvatarItem)

    func hash(into hasher: inout Hasher) {
      switch self {
      case .message(let id):
        hasher.combine(0)
        hasher.combine(id)
      case .dateSeparator(let date):
        hasher.combine(1)
        hasher.combine(date)
      case .typingIndicator:
        hasher.combine(2)
      }
    }

    static func == (lhs: Item, rhs: Item) -> Bool {
      switch (lhs, rhs) {
      case (.message(let a), .message(let b)): return a == b
      case (.dateSeparator(let a), .dateSeparator(let b)): return a == b
      case (.typingIndicator, .typingIndicator): return true
      default: return false
      }
    }
  }

  // MARK: - Properties

  private var collectionView: UICollectionView!
  private var diffableDataSource: UICollectionViewDiffableDataSource<Section, Item>!

  /// Message item IDs already shown at least once — used to detect genuinely
  /// new (appended) messages for the one-shot entrance animation.
  private var knownMessageItemIDs: Set<String> = []
  /// Message item IDs whose cells should play the entrance animation on next
  /// display. One-shot; consumed in `willDisplay`.
  private var entranceAnimationIDs: Set<String> = []

  private var navigationPath: Binding<NavigationPath>
  let dataSource: DataSource
  private weak var appState: AppState?
  private var sceneContext: SceneNavigationContext

  private var observationTask: Task<Void, Never>?
  private let embedPrefetchAdmission = ChatEmbedPrefetchAdmission()
  private var embedPrefetchTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
  private var lastMessageSignaturesByID: [String: String] = [:]
  private var lastSnapshotItems: [Item] = []
  private var lastOldestMessageID: String?
  private var lastMessageCount: Int = 0
  private var isAtBottom = true
  /// Tight threshold for treating the transcript as bottom-locked.
  private let bottomLockThreshold: CGFloat = 24
  private var isLoadingOlderMessages = false
  
  // Callbacks for message actions
  var onMessageLongPress: ((Message) -> Void)?
  var onReactionTapped: ((String, String) -> Void)? // (messageID, emoji)
  var onRequestEmojiPicker: ((String) -> Void)?
  var onRetryMessage: ((String) -> Void)? // (messageID) retry a failed send (WS-6.5)
  var onEditMessage: ((Message) -> Void)?
  var onUnsendMessage: ((Message) -> Void)?
  var onReply: ((Message) -> Void)?
  var onDeleteMessage: ((Message) -> Void)?
  var onReportMessage: ((Message) -> Void)?
  private var hasPerformedInitialScroll = false
  private var lastScrollToBottomTrigger: Int = 0

  private let newMessagesPillButton: UIButton = {
    var config = UIButton.Configuration.filled()
    config.cornerStyle = .capsule
    config.baseBackgroundColor = .secondarySystemGroupedBackground
    config.baseForegroundColor = .label
    config.image = UIImage(systemName: "chevron.down")
    config.imagePlacement = .trailing
    config.imagePadding = 6
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .small)
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)

    var titleAttr = AttributedString("New messages")
    let baseFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.subheadline)
    let descriptor = baseFont.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]])
    titleAttr.font = UIFont(descriptor: descriptor, size: 0)
    config.attributedTitle = titleAttr

    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "New messages"
    button.accessibilityHint = "Jump to latest messages"
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.12
    button.layer.shadowRadius = 8
    button.layer.shadowOffset = CGSize(width: 0, height: 2)
    button.alpha = 0
    button.isHidden = true
    return button
  }()

  private var pillBottomConstraint: NSLayoutConstraint?

  private weak var reactionDetailsController: UIViewController?
  #if DEBUG
  private let fixtureRecordStore = ChatPresentationFixtureRecordStore()
  private(set) var fixtureNativeContextMenuRequestCount = 0
  private(set) var fixtureNativeContextMenuAttemptCount = 0
  private(set) var fixtureNativeContextMenuLastStatus = "not-requested"
  #endif
  private var messageMenuAccountID: String?
  private var messageMenuGeneration = UUID()
  private var messageMenuAnchors: [String: ChatMessageContextMenuAnchorReference] = [:]
  private var activeMessageMenuIdentity: ChatMessageMenuIdentity?
  private var pendingMessageMenuAction: (action: ChatMessageMenuAction, identity: ChatMessageMenuIdentity)?
  private weak var messageActionsController: UIAlertController?

  // MARK: - Initialization

  init(
    dataSource: DataSource,
    navigationPath: Binding<NavigationPath>,
    appState: AppState,
    sceneContext: SceneNavigationContext
  ) {
    self.dataSource = dataSource
    self.navigationPath = navigationPath
    self.appState = appState
    self.messageMenuAccountID = appState.userDID
    self.sceneContext = sceneContext
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    observationTask?.cancel()
    for request in embedPrefetchTasks.values { request.task.cancel() }
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    setupCollectionView()
    setupDataSource()
    (collectionView.collectionViewLayout as? ChatAnchoredLayout)?.measuredItemKey = { [weak self] indexPath in
      self?.diffableDataSource.itemIdentifier(for: indexPath).map(AnyHashable.init)
    }
    setupObservation()
    setupNewMessagesPill()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if observationTask == nil {
      hasPerformedInitialScroll = false
      collectionView.alpha = 0
      setupObservation()
    }
    Task { await dataSource.loadMessages() }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    embedPrefetchAdmission.update(
      isVisible: true, cancel: cancelEmbedPrefetch, warm: warmNewestEmbeds
    )
  }

  override func viewWillDisappear(_ animated: Bool) {
    embedPrefetchAdmission.update(
      isVisible: false, cancel: cancelEmbedPrefetch, warm: warmNewestEmbeds
    )
    super.viewWillDisappear(animated)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Only tear down observation when truly leaving the screen (popped from nav stack),
    // not when a sheet or full-screen cover is presented over this view controller.
    // Cancelling here caused incoming websocket messages to be silently dropped from the
    // UI because the snapshot was never updated while observation was inactive.
    if isMovingFromParent || isBeingDismissed {
      dismissMessageMenus()
      observationTask?.cancel()
      observationTask = nil
    }
  }

  func dismantle() {
    dismissMessageMenus()
    observationTask?.cancel()
    observationTask = nil
  }

  // MARK: - Setup

  private func setupCollectionView() {
    collectionView = ChatTranscriptCollectionView(frame: view.bounds, collectionViewLayout: createLayout())
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.prefetchDataSource = self
    collectionView.keyboardDismissMode = .interactive
    collectionView.bounces = true
    collectionView.alwaysBounceVertical = true
    collectionView.showsVerticalScrollIndicator = true
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      collectionView.topEdgeEffect.style = .soft
      collectionView.bottomEdgeEffect.style = .soft
    }
    #endif

    // Keep the collection view in a normal (unflipped) coordinate space.
    // We preserve scroll position when prepending older messages by adjusting contentOffset.
    collectionView.scrollsToTop = true

    // Hide until initial snapshot is applied and scrolled to bottom to prevent
    // the user seeing messages appear from the top and then jump down.
    collectionView.alpha = 0

    view.addSubview(collectionView)
  }
  private func setupNewMessagesPill() {
    view.addSubview(newMessagesPillButton)
    newMessagesPillButton.addTarget(self, action: #selector(didTapNewMessagesPill), for: .touchUpInside)

    let bottomAnchor = view.bottomAnchor
    let constraint = newMessagesPillButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
    pillBottomConstraint = constraint

    NSLayoutConstraint.activate([
      newMessagesPillButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      constraint
    ])
  }
  private func createLayout() -> UICollectionViewLayout {
    ChatAnchoredLayout()
  }

  private func setupDataSource() {
    let messageRegistration = UICollectionView.CellRegistration<ChatTranscriptCell, String> {
      [weak self] cell, _, messageID in
      guard
        let self,
        let message = self.dataSource.message(for: messageID),
        let appState = self.appState
      else {
        cell.contentConfiguration = nil
        return
      }

      cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
      cell.selectedBackgroundView = nil
      cell.clipsToBounds = false
      cell.contentView.clipsToBounds = false
      // Reused cells must never inherit a half-finished entrance animation.
      cell.contentView.layer.removeAllAnimations()
      cell.contentView.alpha = 1
      cell.contentView.transform = .identity

      cell.contentConfiguration = UIHostingConfiguration {
        ChatTranscriptContent(cell: cell) {
          self.fixtureRecordsContent {
            UnifiedMessageBubble(
              message: message,
              navigationPath: self.navigationPath,
              onReactionTapped: { emoji in
                Task { @MainActor in
                  self.dataSource.toggleReaction(messageID: messageID, emoji: emoji)
                  self.onReactionTapped?(messageID, emoji)
                }
              },
              onAddReaction: { emoji in
                Task { @MainActor in
                  self.dataSource.addReaction(messageID: messageID, emoji: emoji)
                  self.onReactionTapped?(messageID, emoji)
                }
              },
              onRequestEmojiPicker: { requestedMessageID in
                self.onRequestEmojiPicker?(requestedMessageID)
              },
              onLongPress: nil,
              onMoreActions: { [weak self] in
                self?.presentAccessibleMessageActions(messageID: messageID)
              },
              onContextMenuAnchor: { [weak self, weak cell] anchor in
                // Hosting can finish layout in a reused or measurement cell.
                // Only the currently displayed message may replace its anchor.
                guard let self, let cell,
                      anchor.window != nil,
                      anchor.isDescendant(of: cell.contentView),
                      let indexPath = self.collectionView.indexPath(for: cell),
                      self.diffableDataSource.itemIdentifier(for: indexPath) == .message(id: messageID),
                      self.collectionView.cellForItem(at: indexPath) === cell else { return }
                self.messageMenuAnchors[messageID] = ChatMessageContextMenuAnchorReference(view: anchor, cell: cell)
              },
              onReactionLongPress: {
                Task { @MainActor [weak self] in
                  await self?.presentReactionDetailsSheet(messageID: messageID)
                }
              },
              onReply: { [weak self] in
                guard let self, let msg = self.dataSource.message(for: messageID) else { return }
                self.onReply?(msg)
              },
              onReplyTapped: { [weak self] referencedID in
                self?.scrollToMessage(id: referencedID, highlight: true)
              },
              onToggleGroup: { [weak self] in
                (self?.dataSource as? BlueskyConversationDataSource)?.toggleSystemGroup(groupID: messageID)
              },
              onRetry: { [weak self] in
                self?.onRetryMessage?(messageID)
              },
              showSenderName: (self.dataSource as? BlueskyConversationDataSource)?.isGroupConversation ?? true,
              groupPosition: UnifiedMessageGrouping.groupPosition(for: messageID, in: self.dataSource.messages)
            )
            // Quoted posts and avatars in a bubble read the moderation policy from
            // the environment; without it they would use the fail-closed policy.
            .trackingModerationPolicy(of: appState)
            .applyAppStateEnvironment(appState)
            .environment(self.sceneContext)
          }
        }
      }
      .margins(.all, 0)
    }

    let dateSeparatorRegistration = UICollectionView.CellRegistration<ChatTranscriptCell, Date> {
      cell, _, date in
      cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
      cell.selectedBackgroundView = nil

      cell.contentConfiguration = UIHostingConfiguration {
        ChatTranscriptContent(cell: cell) {
          Text(date, format: .dateTime.month().day().year())
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
      }
      .margins(.all, 0)
    }

    let typingIndicatorRegistration = UICollectionView.CellRegistration<ChatTranscriptCell, TypingAvatarItem> {
      cell, _, item in
      cell.backgroundConfiguration = UIBackgroundConfiguration.clear()

      cell.contentConfiguration = UIHostingConfiguration {
        ChatTranscriptContent(cell: cell) {
          TypingIndicatorView(avatarURL: item.avatarURL)
            .padding(.vertical, 4)
        }
      }
      .margins(.all, 0)
    }

    diffableDataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
      collectionView, indexPath, item in
      switch item {
      case .message(let id):
        return collectionView.dequeueConfiguredReusableCell(
          using: messageRegistration,
          for: indexPath,
          item: id
        )
      case .dateSeparator(let date):
        return collectionView.dequeueConfiguredReusableCell(
          using: dateSeparatorRegistration,
          for: indexPath,
          item: date
        )
      case .typingIndicator(let avatarItem):
        return collectionView.dequeueConfiguredReusableCell(
          using: typingIndicatorRegistration,
          for: indexPath,
          item: avatarItem
        )
      }
    }
  }

  @ViewBuilder
  private func fixtureRecordsContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    #if DEBUG
    content().modifier(ChatPresentationFixtureRecordsModifier(store: fixtureRecordStore))
    #else
    content()
    #endif
  }

  #if DEBUG
  func updateFixtureRecords(_ records: [String: AppBskyEmbedRecord.ViewRecordUnion]) {
    guard fixtureRecordStore.records != records else { return }
    fixtureRecordStore.records = records
  }
  #endif

  private func setupObservation() {
    observationTask?.cancel()
    observationTask = Task { @MainActor [weak self] in
      guard let initialSelf = self else { return }

      // Perform an initial snapshot so the UI is populated immediately.
      await initialSelf.processObservationCycle()

      // Re-arm observation each time a tracked property changes.
      while !Task.isCancelled {
        var didResume = false
        await withCheckedContinuation { continuation in
          withObservationTracking { [weak self] in
            // Touch the observable properties we care about so the
            // tracking system knows to wake us when they change.
            guard let self else { return }
            _ = self.dataSource.messages
            _ = self.dataSource.showsTypingIndicator
            _ = self.dataSource.typingParticipantAvatarURL
            _ = self.dataSource.scrollToBottomTrigger
          } onChange: {
            guard !didResume else { return }
            didResume = true
            continuation.resume()
          }
        }

        guard !Task.isCancelled, let self else { break }
        await self.processObservationCycle()
      }
    }
  }

  @MainActor
  private func processObservationCycle() async {
    let newItems = currentSnapshotItems()
    warmNewestEmbeds()
    let itemsChanged = newItems != lastSnapshotItems
    let newSignaturesByID = currentMessageSignaturesByID()
    let stableIDs = Set(lastMessageSignaturesByID.keys).intersection(newSignaturesByID.keys)
    let changedMessageIDs = Set(stableIDs.filter {
      lastMessageSignaturesByID[$0] != newSignaturesByID[$0]
    })

    // Detect if the data source requested a scroll-to-bottom (e.g. after sending)
    let currentTrigger = dataSource.scrollToBottomTrigger
    let shouldForceScrollToBottom = currentTrigger != lastScrollToBottomTrigger
    lastScrollToBottomTrigger = currentTrigger

    if itemsChanged || !changedMessageIDs.isEmpty {
      lastSnapshotItems = newItems
      lastMessageSignaturesByID = newSignaturesByID
      await updateSnapshot(
        items: newItems,
        itemsChanged: itemsChanged,
        forceScrollToBottom: shouldForceScrollToBottom,
        reconfiguringMessageIDs: changedMessageIDs
      )
    } else if shouldForceScrollToBottom {
      scrollToBottom(animated: true)
    }
  }

  // MARK: - Snapshot Updates

  @MainActor
  private func updateSnapshot(
    items: [Item],
    itemsChanged: Bool,
    forceScrollToBottom: Bool,
    reconfiguringMessageIDs: Set<String>
  ) async {
    guard diffableDataSource != nil else { return }
    let messageIDs = Set(items.compactMap { item -> String? in
      if case .message(let id) = item { return id }
      return nil
    })
    messageMenuAnchors = messageMenuAnchors.filter { messageIDs.contains($0.key) && $0.value.view != nil }
    if let identity = activeMessageMenuIdentity, message(for: identity) == nil {
      dismissMessageMenus()
    }

    // Capture current state before update for scroll position maintenance
    let previousItemCount = diffableDataSource.snapshot().numberOfItems
    let previousContentHeight = collectionView.contentSize.height
    let visibleAnchor = captureVisibleMessageAnchor()
    let previousContentOffsetY = collectionView.contentOffset.y
    let previousVisibleBottom =
      previousContentOffsetY +
      collectionView.bounds.height -
      collectionView.adjustedContentInset.bottom
    let wasLockedToBottom = previousVisibleBottom >= previousContentHeight - bottomLockThreshold
    let userIsInteracting =
      collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    let shouldAutoScrollForNewItems =
      itemsChanged &&
      ((previousItemCount == 0) || wasLockedToBottom)
    let shouldPinBottomAfterUpdate =
      !userIsInteracting &&
      (forceScrollToBottom || (!UIAccessibility.isVoiceOverRunning && (wasLockedToBottom || shouldAutoScrollForNewItems)))
    let currentOldestMessageID = dataSource.messages.first?.id
    let currentMessageCount = dataSource.messages.count
    let didPrependOlderMessages =
      previousItemCount > 0 &&
      currentMessageCount > lastMessageCount &&
      currentOldestMessageID != nil &&
      lastOldestMessageID != nil &&
      currentOldestMessageID != lastOldestMessageID

    // Entrance animation bookkeeping: animate only genuinely-new messages on
    // live appends — never on the initial population or history prepends, and
    // never for identity-stable reconfigures (pending→confirmed handover).
    let messageItemIDs = Set(items.compactMap { item -> String? in
      if case .message(let id) = item { return id }
      return nil
    })
    if previousItemCount == 0 || didPrependOlderMessages {
      knownMessageItemIDs = messageItemIDs
    } else {
      let appended = messageItemIDs.subtracting(knownMessageItemIDs)
      if !appended.isEmpty {
        entranceAnimationIDs.formUnion(appended)
      }
      knownMessageItemIDs = messageItemIDs
    }

    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections([.messages])
    snapshot.appendItems(items, toSection: .messages)
    
    if !reconfiguringMessageIDs.isEmpty {
      let itemsToReconfigure = items.filter { item in
        switch item {
        case .message(let id):
          return reconfiguringMessageIDs.contains(id)
        case .dateSeparator, .typingIndicator:
          return false
        }
      }
      if !itemsToReconfigure.isEmpty {
        snapshot.reconfigureItems(itemsToReconfigure)
      }
    }
    
    // When prepending older messages or performing initial load, disable animation.
    let isInitialPopulate = !hasPerformedInitialScroll && previousItemCount == 0 && items.count > 0

    if isInitialPopulate {
      let layout = collectionView.collectionViewLayout as? ChatAnchoredLayout
      layout?.preservesSelfSizingAnchor = false
      defer { layout?.preservesSelfSizingAnchor = true }

      UIView.performWithoutAnimation {
        diffableDataSource.applySnapshotUsingReloadData(snapshot)
        if snapshot.numberOfItems > 0 {
          collectionView.scrollToItem(
            at: IndexPath(item: snapshot.numberOfItems - 1, section: 0),
            at: .bottom,
            animated: false
          )
        }
        scrollToBottom(animated: false)
        collectionView.alpha = 1
      }
      hasPerformedInitialScroll = true
      hideNewMessagesPill(animated: false)
      lastOldestMessageID = currentOldestMessageID
      lastMessageCount = currentMessageCount
    } else if didPrependOlderMessages {
      // Apply without animation, then restore scroll position so viewport stays stable.
      UIView.performWithoutAnimation {
        diffableDataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()
        restoreVisibleMessageAnchor(visibleAnchor)
      }
      lastOldestMessageID = currentOldestMessageID
      lastMessageCount = currentMessageCount
    } else {
      // Apply without animating differences — diffable animation fights estimated
      // self-sizing heights. The bottom pin happens after the layout pass as a
      // retargetable glide, so new messages push the transcript up smoothly instead
      // of teleporting it; reconfigure-only churn resolves to the same target and
      // leaves an in-flight glide untouched (see scrollToBottom).
      UIView.performWithoutAnimation {
        diffableDataSource.apply(snapshot, animatingDifferences: false)
      }
      if shouldPinBottomAfterUpdate {
        scrollToBottom(animated: true)
        hideNewMessagesPill(animated: true)
      } else {
        collectionView.layoutIfNeeded()
        restoreVisibleMessageAnchor(visibleAnchor)
        let newlyAppendedCount = currentMessageCount - lastMessageCount
        if itemsChanged && newlyAppendedCount > 0 && !forceScrollToBottom {
          let latestMessageIsFromSelf = dataSource.messages.last?.isFromCurrentUser ?? false
          if !latestMessageIsFromSelf {
            showNewMessagesPill(animated: true)
          }
        }
      }
      lastOldestMessageID = currentOldestMessageID
      lastMessageCount = currentMessageCount
    }
  }
  private func captureVisibleMessageAnchor() -> ChatVisibleItemAnchor<Item>? {
    ChatVisibleItemAnchor.capture(
      in: collectionView,
      itemAt: { self.diffableDataSource.itemIdentifier(for: $0) },
      include: { if case .message = $0 { return true }; return false }
    )
  }

  private func restoreVisibleMessageAnchor(_ anchor: ChatVisibleItemAnchor<Item>?) {
    anchor?.restore(in: collectionView, indexPathFor: { self.diffableDataSource.indexPath(for: $0) })
  }

  func updateTranscriptBottomInset(_ height: CGFloat) {
    loadViewIfNeeded()
    guard height.isFinite, abs(collectionView.contentInset.bottom - height) > 0.5 else { return }
    collectionView.contentInset.bottom = max(0, height)
    collectionView.verticalScrollIndicatorInsets.bottom = max(0, height)
    pillBottomConstraint?.constant = -12 - max(0, height)
  }

  func updateNavigationBinding(_ binding: Binding<NavigationPath>) {
    navigationPath = binding
  }

  func updateSceneContext(_ context: SceneNavigationContext) {
    guard sceneContext !== context else { return }
    reactionDetailsController?.dismiss(animated: false)
    dismissMessageMenus()
    sceneContext = context
    collectionView?.reloadData()
  }

  func updateAppState(_ newAppState: AppState) {
    if appState !== newAppState { cancelEmbedPrefetch() }
    if appState !== newAppState || messageMenuAccountID != newAppState.userDID {
      reactionDetailsController?.dismiss(animated: false)
      dismissMessageMenus()
    }
    appState = newAppState
    messageMenuAccountID = newAppState.userDID
  }

  // MARK: - Actions

  private func signature(for message: Message) -> String {
    UnifiedChatRenderSignature.messageSignature(for: message)
  }
  
  private func currentMessageSignaturesByID() -> [String: String] {
    var signatures: [String: String] = [:]
    let messages = dataSource.messages
    signatures.reserveCapacity(messages.count)
    for (index, message) in messages.enumerated() {
      // Group position decides the time-underneath row and avatar visibility,
      // and it changes for NEIGHBORS when a message is appended (the previous
      // last-in-group loses its timestamp row). Bake it into the signature so
      // those cells reconfigure the moment their grouping changes, not at some
      // later unrelated update.
      let position = UnifiedMessageGrouping.groupPosition(for: index, in: messages)
      signatures[message.diffableID] = signature(for: message) + "|\(position)"
    }
    return signatures
  }
  
  private func messageMenuIdentity(messageID: String) -> ChatMessageMenuIdentity {
    ChatMessageMenuIdentity(
      messageID: messageID,
      accountID: appState?.userDID,
      sceneID: ObjectIdentifier(sceneContext),
      generation: messageMenuGeneration
    )
  }

  private func message(for identity: ChatMessageMenuIdentity) -> Message? {
    guard appState != nil,
          identity == messageMenuIdentity(messageID: identity.messageID),
          let message = dataSource.message(for: identity.messageID),
          message.diffableID == identity.messageID,
          !message.isSystemMessage, !message.isTombstone else { return nil }
    return message
  }

  private func menuActions(for message: Message) -> [ChatMessageMenuAction] {
    ChatMessageMenuActions.available(
      for: message,
      callbacks: ChatMessageMenuCallbacks(
        canReply: onReply != nil, canDelete: onDeleteMessage != nil, canReport: onReportMessage != nil
      ),
      quickReactions: UnifiedQuickReactionBar.defaultQuickReactions
    )
  }

  private func dismissMessageMenus() {
    messageMenuGeneration = UUID()
    pendingMessageMenuAction = nil
    activeMessageMenuIdentity = nil
    collectionView?.contextMenuInteraction?.dismissMenu()
    messageActionsController?.dismiss(animated: false)
    messageActionsController = nil
  }

  private func menuAnchor(messageID: String) -> (view: ChatMessageContextMenuAnchorView, cell: UICollectionViewCell, rect: CGRect)? {
    guard let reference = messageMenuAnchors[messageID],
          let anchor = reference.view,
          let indexPath = diffableDataSource.indexPath(for: .message(id: messageID)),
          let cell = collectionView.cellForItem(at: indexPath),
          reference.cell === cell,
          anchor.window != nil,
          anchor.isDescendant(of: cell.contentView) else { return nil }
    let rect = anchor.convert(anchor.bounds, to: cell.contentView)
    guard !rect.isEmpty, !rect.isInfinite, !rect.isNull,
          rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
    return (anchor, cell, rect)
  }

  #if DEBUG
  /// A read-only witness for the local fixture; no message content is recorded.
  func fixtureMessageMenuAnchorStatus(messageID: String) -> String {
    let reference = messageMenuAnchors[messageID]
    let anchor = reference?.view
    let storedCell = reference?.cell
    let indexPath = diffableDataSource.indexPath(for: .message(id: messageID))
    let currentCell = indexPath.flatMap { collectionView.cellForItem(at: $0) }
    let sameCell = storedCell != nil && storedCell === currentCell
    let hasWindow = anchor?.window != nil
    let isDescendant: Bool
    let rect: CGRect?
    if let anchor, let currentCell {
      isDescendant = anchor.isDescendant(of: currentCell.contentView)
      rect = anchor.convert(anchor.bounds, to: currentCell.contentView)
    } else {
      isDescendant = false
      rect = nil
    }
    let validRect = rect.map {
      !$0.isEmpty && !$0.isInfinite && !$0.isNull && $0.origin.x.isFinite && $0.origin.y.isFinite
    } ?? false
    let reason: String
    if reference == nil { reason = "missing-reference" }
    else if anchor == nil { reason = "released-anchor" }
    else if indexPath == nil { reason = "missing-index-path" }
    else if currentCell == nil { reason = "no-visible-cell" }
    else if !sameCell { reason = "cell-mismatch" }
    else if !hasWindow { reason = "no-window" }
    else if !isDescendant { reason = "not-current-content-descendant" }
    else if !validRect { reason = "invalid-rect" }
    else { reason = "valid" }
    let storedCellID = storedCell.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    let currentCellID = currentCell.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    let location = indexPath.map { "\($0.section):\($0.item)" } ?? "nil"
    let bounds = anchor.map { String(describing: $0.bounds) } ?? "nil"
    let convertedRect = rect.map { String(describing: $0) } ?? "nil"
    return "\(reason) references=\(messageMenuAnchors.count) indexPath=\(location) storedCell=\(storedCellID) currentCell=\(currentCellID) sameCell=\(sameCell) window=\(hasWindow) descendant=\(isDescendant) bounds=\(bounds) rect=\(convertedRect)"
  }

  private func fixtureMessageMenuConfigurationFailure(indexPaths: [IndexPath], point: CGPoint) -> String {
    let geometry = "point=\(point) indexPathCount=\(indexPaths.count)"
    guard indexPaths.count == 1, let indexPath = indexPaths.first else {
      return "invalid-index-path-count \(geometry)"
    }
    guard let item = diffableDataSource.itemIdentifier(for: indexPath) else {
      return "missing-item indexPath=\(indexPath.section):\(indexPath.item) \(geometry)"
    }
    guard case .message(let messageID) = item else {
      return "non-message-item indexPath=\(indexPath.section):\(indexPath.item) \(geometry)"
    }
    return "invalid-anchor \(fixtureMessageMenuAnchorStatus(messageID: messageID)) \(geometry)"
  }
  #endif

  func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    #if DEBUG
    fixtureNativeContextMenuAttemptCount += 1
    fixtureNativeContextMenuLastStatus = "entered point=\(point)"
    #endif
    guard indexPaths.count == 1,
          let indexPath = indexPaths.first,
          let item = diffableDataSource.itemIdentifier(for: indexPath),
          case .message(let messageID) = item,
          let anchor = menuAnchor(messageID: messageID) else {
      #if DEBUG
      fixtureNativeContextMenuLastStatus = fixtureMessageMenuConfigurationFailure(indexPaths: indexPaths, point: point)
      #endif
      return nil
    }
    let localPoint = collectionView.convert(point, to: anchor.cell.contentView)
    #if DEBUG
    let fixtureMenuGeometry = "point=\(point) localPoint=\(localPoint) anchorRect=\(anchor.rect)"
    #endif
    guard anchor.rect.contains(localPoint) else {
      #if DEBUG
      fixtureNativeContextMenuLastStatus = "outside-anchor \(fixtureMenuGeometry)"
      #endif
      return nil
    }

    // Preserve an embedded control's own hold menu. Ordinary card buttons
    // still allow a message hold menu; their normal tap is unchanged. The
    // native anchor never participates in hit testing.
    var hitView = anchor.cell.contentView.hitTest(localPoint, with: nil)
    while let candidate = hitView, candidate !== anchor.cell.contentView {
      if candidate.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
        #if DEBUG
        fixtureNativeContextMenuLastStatus = "nested-interaction class=\(String(describing: type(of: candidate))) \(fixtureMenuGeometry)"
        #endif
        return nil
      }
      hitView = candidate.superview
    }

    messageMenuGeneration = UUID()
    let identity = messageMenuIdentity(messageID: messageID)
    guard message(for: identity) != nil else {
      #if DEBUG
      fixtureNativeContextMenuLastStatus = "invalid-message \(fixtureMenuGeometry)"
      #endif
      return nil
    }
    #if DEBUG
    fixtureNativeContextMenuRequestCount += 1
    fixtureNativeContextMenuLastStatus = "accepted \(fixtureMenuGeometry)"
    #endif
    return UIContextMenuConfiguration(identifier: ChatMessageMenuConfigurationIdentifier(identity: identity), previewProvider: nil) { [weak self] _ in
      self?.nativeMessageMenu(for: identity)
    }
  }

  private func nativeMessageMenu(for identity: ChatMessageMenuIdentity) -> UIMenu? {
    guard let message = message(for: identity) else { return nil }
    let actions = menuActions(for: message)
    func nativeAction(_ action: ChatMessageMenuAction) -> UIAction {
      let image: UIImage?
      if case .reaction(let emoji) = action {
        let size = CGSize(width: 30, height: 30)
        image = UIGraphicsImageRenderer(size: size).image { _ in
          (emoji as NSString).draw(at: CGPoint(x: 1, y: 0), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }.withRenderingMode(.alwaysOriginal)
      } else {
        image = action.symbolName.flatMap { UIImage(systemName: $0) }
      }
      return UIAction(
        title: action.title,
        image: image,
        identifier: UIAction.Identifier(action.identifier),
        attributes: action.isDestructive ? [.destructive] : []
      ) { [weak self] _ in
        self?.selectMessageMenuAction(action, identity: identity)
      }
    }
    let reactions = actions.filter { if case .reaction = $0 { return true }; return false }
    // Keep each native compact group within one row. A six-item group can
    // overflow into full-size image-and-title rows for its remaining actions.
    let reactionMenus: [UIMenuElement] = stride(from: 0, to: reactions.count, by: 3).map { startIndex in
      let groupIdentifier = startIndex == 0
        ? "chat.message.reactions"
        : "chat.message.reactions.\(startIndex / 3 + 1)"
      let menu = UIMenu(
        title: "", identifier: UIMenu.Identifier(groupIdentifier), options: .displayInline,
        children: reactions[startIndex..<min(startIndex + 3, reactions.count)].map(nativeAction)
      )
      menu.preferredElementSize = .small
      return menu
    }
    let otherActions = actions.filter { if case .reaction = $0 { return false }; return true }
    return UIMenu(
      title: "", identifier: UIMenu.Identifier("chat.message.actions"),
      children: reactionMenus + otherActions.map(nativeAction)
    )
  }

  func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfiguration configuration: UIContextMenuConfiguration,
    highlightPreviewForItemAt indexPath: IndexPath
  ) -> UITargetedPreview? {
    messageMenuPreview(configuration: configuration, indexPath: indexPath)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfiguration configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemAt indexPath: IndexPath
  ) -> UITargetedPreview? {
    messageMenuPreview(configuration: configuration, indexPath: indexPath)
  }

  private func messageMenuPreview(configuration: UIContextMenuConfiguration, indexPath: IndexPath) -> UITargetedPreview? {
    guard let identifier = configuration.identifier as? ChatMessageMenuConfigurationIdentifier,
          message(for: identifier.identity) != nil,
          case .message(let messageID)? = diffableDataSource.itemIdentifier(for: indexPath),
          messageID == identifier.identity.messageID,
          let anchor = menuAnchor(messageID: messageID),
          let snapshot = anchor.cell.contentView.resizableSnapshotView(
            from: anchor.rect, afterScreenUpdates: false, withCapInsets: .zero
          ) else { return nil }
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    parameters.visiblePath = UIBezierPath(
      roundedRect: CGRect(origin: .zero, size: anchor.rect.size), cornerRadius: anchor.view.cornerRadius
    )
    let target = UIPreviewTarget(
      container: anchor.cell.contentView,
      center: CGPoint(x: anchor.rect.midX, y: anchor.rect.midY)
    )
    // A crop of the rendered cell preserves loaded media without a second
    // SwiftUI tree, record request, or change to transcript sizing.
    return UITargetedPreview(view: snapshot, parameters: parameters, target: target)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    willDisplayContextMenu configuration: UIContextMenuConfiguration,
    animator: (any UIContextMenuInteractionAnimating)?
  ) {
    guard let identifier = configuration.identifier as? ChatMessageMenuConfigurationIdentifier else { return }
    let identity = identifier.identity
    guard let message = message(for: identity) else { return }
    activeMessageMenuIdentity = identity
    onMessageLongPress?(message)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
    animator: (any UIContextMenuInteractionAnimating)?
  ) {
    guard let identifier = configuration.identifier as? ChatMessageMenuConfigurationIdentifier else { return }
    let identity = identifier.identity
    let complete = { [weak self] in
      guard let self, self.activeMessageMenuIdentity == identity else { return }
      self.activeMessageMenuIdentity = nil
      let pending = self.pendingMessageMenuAction
      self.pendingMessageMenuAction = nil
      if let pending { self.performMessageMenuAction(pending.action, identity: pending.identity) }
    }
    if let animator { animator.addCompletion(complete) } else { complete() }
  }

  private func selectMessageMenuAction(_ action: ChatMessageMenuAction, identity: ChatMessageMenuIdentity) {
    guard message(for: identity) != nil else { return }
    if activeMessageMenuIdentity == identity {
      pendingMessageMenuAction = (action, identity)
      collectionView.contextMenuInteraction?.dismissMenu()
    } else {
      performMessageMenuAction(action, identity: identity)
    }
  }

  #if DEBUG
  func fixturePresentAccessibleMessageActions(messageID: String) {
    presentAccessibleMessageActions(messageID: messageID)
  }
  #endif

  /// VoiceOver's named action uses the same descriptors without attempting to
  /// programmatically present UIContextMenuInteraction through private API.
  private func presentAccessibleMessageActions(messageID: String) {
    dismissMessageMenus()
    let identity = messageMenuIdentity(messageID: messageID)
    guard let message = message(for: identity), let anchor = menuAnchor(messageID: messageID) else { return }
    let alert = UIAlertController(title: "Message Actions", message: nil, preferredStyle: .actionSheet)
    for action in menuActions(for: message) {
      alert.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) { [weak self, weak alert] _ in
        guard let self else { return }
        let perform: () -> Void = { [weak self] in self?.performMessageMenuAction(action, identity: identity) }
        if let alert { alert.dismiss(animated: true, completion: perform) } else { perform() }
      })
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.popoverPresentationController?.sourceView = anchor.cell.contentView
    alert.popoverPresentationController?.sourceRect = anchor.rect
    messageActionsController = alert
    onMessageLongPress?(message)
    present(alert, animated: true)
  }

  private func performMessageMenuAction(_ action: ChatMessageMenuAction, identity: ChatMessageMenuIdentity) {
    guard viewIfLoaded?.window != nil,
          let message = message(for: identity), menuActions(for: message).contains(action) else { return }
    switch action {
    case .reaction(let emoji):
      dataSource.addReaction(messageID: identity.messageID, emoji: emoji)
      onReactionTapped?(identity.messageID, emoji)
    case .moreReactions:
      onRequestEmojiPicker?(identity.messageID)
    case .reply:
      onReply?(message)
    case .copy:
      UIPasteboard.general.string = message.text
      PlatformHaptics.light()
    case .deleteForMe:
      onDeleteMessage?(message)
    case .report:
      onReportMessage?(message)
    case .edit:
      onEditMessage?(message)
    case .unsend:
      let alert = UIAlertController(
        title: "Unsend Message", message: "This removes the message for everyone in the conversation.", preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      alert.addAction(UIAlertAction(title: "Unsend", style: .destructive) { [weak self] _ in
        guard let self, let current = self.message(for: identity), current.canUnsend else { return }
        self.onUnsendMessage?(current)
      })
      messageActionsController = alert
      present(alert, animated: true)
    }
  }

  @MainActor
  private func presentReactionDetailsSheet(messageID: String) {
    dismissMessageMenus()
    guard let message = dataSource.message(for: messageID),
          !message.isSystemMessage, !message.reactions.isEmpty, let appState else { return }
    let host = UIHostingController(rootView: UnifiedReactionDetailsSheet(
      dataSource: dataSource, messageID: messageID, appState: appState, accountDID: appState.userDID
    ))
    host.modalPresentationStyle = .pageSheet
    reactionDetailsController = host
    present(host, animated: true)
  }

  private func currentSnapshotItems() -> [Item] {
    var items: [Item] = []
    var seenDays = Set<Date>()
    let calendar = Calendar.current

    // Messages in chronological order (oldest first, newest last)
    var seenMessageIDs = Set<String>()
    for message in dataSource.messages {
      guard seenMessageIDs.insert(message.diffableID).inserted else {
        chatLogger.warning("Duplicate message ID skipped in snapshot: \(message.diffableID)")
        continue
      }
      let messageDay = calendar.startOfDay(for: message.sentAt)
      if seenDays.insert(messageDay).inserted {
        items.append(.dateSeparator(messageDay))
      }
      items.append(.message(id: message.diffableID))
    }

    if dataSource.showsTypingIndicator {
      items.append(.typingIndicator(TypingAvatarItem(avatarURL: dataSource.typingParticipantAvatarURL)))
    }

    return items
  }

  /// Offset that pins the transcript to its bottom edge, clamped for content
  /// shorter than the viewport.
  private func bottomContentOffsetY() -> CGFloat {
    max(
      collectionView.contentSize.height
        - collectionView.bounds.height
        + collectionView.adjustedContentInset.bottom,
      -collectionView.adjustedContentInset.top
    )
  }

  func scrollToBottom(animated: Bool = true) {
    hideNewMessagesPill(animated: animated)

    guard
      diffableDataSource != nil,
      diffableDataSource.snapshot().numberOfItems > 0,
      collectionView.bounds.height > 0
    else { return }

    // Never fight an active touch — bottom pins during interaction are already
    // excluded in updateSnapshot; this covers the keyboard/composer paths.
    if animated,
       collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating {
      return
    }

    // Settle the layout at the bottom first so self-sizing cells there are
    // measured and the target offset is exact — with estimated heights,
    // contentSize is approximate until the bottom cells have been created.
    // Nothing renders mid-transaction, so the temporary offset is invisible.
    let layout = collectionView.collectionViewLayout as? ChatAnchoredLayout
    layout?.preservesSelfSizingAnchor = false
    defer { layout?.preservesSelfSizingAnchor = true }
    let startOffsetY = collectionView.contentOffset.y
    var targetY = startOffsetY
    UIView.performWithoutAnimation {
      collectionView.layoutIfNeeded()
      collectionView.contentOffset.y = bottomContentOffsetY()
      collectionView.layoutIfNeeded()
      targetY = bottomContentOffsetY()
      collectionView.contentOffset.y = targetY
    }

    if !animated || UIAccessibility.isReduceMotionEnabled {
      return
    }

    // Already pinned (or an in-flight glide is heading here): leave the model
    // offset where it is so we don't disturb the running animation.
    guard abs(targetY - startOffsetY) > 0.5 else { return }

    // Rewind to where the transcript was and glide to the bottom. The spring
    // matches the cell entrance animation so both read as one motion, and the
    // additive .beginFromCurrentState animation retargets smoothly when a new
    // update lands mid-flight instead of snapping.
    UIView.performWithoutAnimation {
      collectionView.contentOffset.y = startOffsetY
    }
    UIView.animate(
      withDuration: 0.38,
      delay: 0,
      usingSpringWithDamping: 0.84,
      initialSpringVelocity: 0.4,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.collectionView.contentOffset.y = targetY
    }
  }

  func scrollToMessage(id: String, highlight: Bool = true) {
    guard let diffableDataSource else { return }
    let snapshot = diffableDataSource.snapshot()
    guard let item = snapshot.itemIdentifiers.first(where: {
      if case .message(let itemID) = $0 {
        return itemID == id
      }
      return false
    }), let indexPath = diffableDataSource.indexPath(for: item) else { return }

    collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)

    if highlight {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let cell = self?.collectionView.cellForItem(at: indexPath) else { return }
        UIView.animate(withDuration: 0.2, animations: {
          cell.contentView.backgroundColor = UIColor.systemFill.withAlphaComponent(0.3)
        }) { _ in
          UIView.animate(withDuration: 0.5, delay: 0.5, options: .curveEaseOut) {
            cell.contentView.backgroundColor = .clear
          }
        }
      }
    }
  }

  // MARK: - UICollectionViewDelegate

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    let visibleBottom =
      scrollView.contentOffset.y +
      scrollView.bounds.height -
      scrollView.adjustedContentInset.bottom

    isAtBottom = visibleBottom >= scrollView.contentSize.height - bottomLockThreshold
    if isAtBottom {
      hideNewMessagesPill(animated: true)
    }


    // Trigger pagination when approaching the top (older messages)
    let threshold: CGFloat = 200
    if
      visibleTop < threshold &&
      dataSource.hasMoreMessages &&
      !dataSource.isLoading &&
      !isLoadingOlderMessages
    {
      isLoadingOlderMessages = true
      Task {
        await dataSource.loadMoreMessages()
        await MainActor.run { isLoadingOlderMessages = false }
      }
    }
  }

  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    guard
      let item = diffableDataSource.itemIdentifier(for: indexPath),
      case .message(let id) = item,
      entranceAnimationIDs.remove(id) != nil
    else { return }

    let content = cell.contentView
    if UIAccessibility.isReduceMotionEnabled {
      content.alpha = 0
      UIView.animate(withDuration: 0.22, delay: 0, options: [.allowUserInteraction]) {
        content.alpha = 1
      }
      return
    }
    content.alpha = 0
    content.transform = CGAffineTransform(translationX: 0, y: 14)
    UIView.animate(
      withDuration: 0.38,
      delay: 0,
      usingSpringWithDamping: 0.84,
      initialSpringVelocity: 0.4,
      options: [.allowUserInteraction]
    ) {
      content.alpha = 1
      content.transform = .identity
    }
  }

  /// With self-sizing enabled this is each item's starting estimate: the last
  /// fitted height for the same message, so off-screen rows keep their measured
  /// size across snapshot applies instead of collapsing to the default.
  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    guard let layout = collectionViewLayout as? ChatAnchoredLayout else {
      return CGSize(width: collectionView.bounds.width, height: ChatAnchoredLayout.defaultEstimatedHeight)
    }
    return layout.estimatedSize(at: indexPath)
  }

  // MARK: - UICollectionViewDataSourcePrefetching

  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    for index in indexPaths {
      guard case .message(let id) = diffableDataSource.itemIdentifier(for: index),
        let uri = dataSource.message(for: id)?.embed?.recordURI else { continue }
      prefetchEmbed(uri: uri)
    }
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cancelPrefetchingForItemsAt indexPaths: [IndexPath]
  ) {
    for index in indexPaths {
      guard case .message(let id) = diffableDataSource.itemIdentifier(for: index),
        let uri = dataSource.message(for: id)?.embed?.recordURI else { continue }
      embedPrefetchTasks.removeValue(forKey: uri)?.task.cancel()
    }
  }

  func updatePrefetchSceneActivity(isActive: Bool) {
    embedPrefetchAdmission.update(
      isSceneActive: isActive, cancel: cancelEmbedPrefetch, warm: warmNewestEmbeds
    )
  }

  private func warmNewestEmbeds() {
    // Observation remains live when covered; only optional metadata work stops.
    embedPrefetchAdmission.performIfAllowed {
      for message in dataSource.messages.suffix(8).reversed() {
        if let uri = message.embed?.recordURI { prefetchEmbed(uri: uri) }
      }
    }
  }

  private func prefetchEmbed(uri: String) {
    #if DEBUG
    guard fixtureRecordStore.records[uri] == nil else { return }
    #endif
    guard embedPrefetchAdmission.isAllowed,
      embedPrefetchTasks.count < 4, embedPrefetchTasks[uri] == nil,
      let appState, ChatRecordEmbedStore.shared.cachedRecord(uri: uri, appState: appState) == nil else { return }
    let requestID = UUID()
    let task = Task { @MainActor [weak self] in
      guard !Task.isCancelled, self?.embedPrefetchAdmission.isAllowed == true else { return }
      _ = try? await ChatRecordEmbedStore.shared.load(uri: uri, appState: appState)
      if self?.embedPrefetchTasks[uri]?.id == requestID {
        self?.embedPrefetchTasks.removeValue(forKey: uri)
      }
    }
    embedPrefetchTasks[uri] = (requestID, task)
  }

  private func cancelEmbedPrefetch() {
    for request in embedPrefetchTasks.values { request.task.cancel() }
    embedPrefetchTasks.removeAll()
  }

  // MARK: - New Messages Pill Actions

  @objc private func didTapNewMessagesPill() {
    PlatformHaptics.light()
    scrollToBottom(animated: true)
    hideNewMessagesPill(animated: true)
  }

  @MainActor
  private func showNewMessagesPill(animated: Bool = true) {
    guard newMessagesPillButton.isHidden || newMessagesPillButton.alpha < 1 else { return }
    newMessagesPillButton.isHidden = false
    view.bringSubviewToFront(newMessagesPillButton)
    if animated {
      UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
        self.newMessagesPillButton.alpha = 1
        self.newMessagesPillButton.transform = .identity
      }
    } else {
      newMessagesPillButton.alpha = 1
      newMessagesPillButton.transform = .identity
    }
  }

  @MainActor
  private func hideNewMessagesPill(animated: Bool = true) {
    guard !newMessagesPillButton.isHidden else { return }
    if animated {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
        self.newMessagesPillButton.alpha = 0
        self.newMessagesPillButton.transform = CGAffineTransform(translationX: 0, y: 10)
      } completion: { finished in
        if finished {
          self.newMessagesPillButton.isHidden = true
        }
      }
    } else {
      newMessagesPillButton.alpha = 0
      newMessagesPillButton.isHidden = true
      newMessagesPillButton.transform = CGAffineTransform(translationX: 0, y: 10)
    }
  }
}

#if DEBUG
@available(iOS 16.0, *)
extension ChatCollectionViewController: ChatMessageContextMenuFixtureReporting {}
#endif

// MARK: - Typing Indicator View

@available(iOS 16.0, *)
private struct TypingIndicatorView: View {
  let avatarURL: URL?
  @Environment(\.displayScale) private var displayScale
  @State private var animate = false

  var body: some View {
    HStack(spacing: 8) {
      if let avatarURL {
        let request = ImageRequestFactory.avatar(avatarURL, pointSize: 28, scale: displayScale)
        LazyImage(request: request) { state in
          if let image = state.image {
            image
              .resizable()
              .scaledToFill()
          } else {
            Circle()
              .fill(Color.gray.opacity(0.3))
          }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
      } else {
        Circle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 28, height: 28)
      }

      HStack(spacing: 6) {
        ForEach(0..<3, id: \.self) { index in
          Circle()
            .fill(Color.secondary)
            .frame(width: 8, height: 8)
            .scaleEffect(animate ? 1.0 : 0.6)
            .opacity(animate ? 1 : 0.4)
            .animation(
              .easeInOut(duration: 0.6)
                .repeatForever()
                .delay(Double(index) * 0.15),
              value: animate
            )
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 12)
    .onAppear { animate = true }
  }
}

#endif
