#if os(iOS)
import NukeUI
import Observation
import os
import SwiftUI
import UIKit

@available(iOS 16.0, *)
final class ChatCollectionViewController<DataSource: UnifiedChatDataSource>: UIViewController,
  UICollectionViewDelegate,
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

  private var observationTask: Task<Void, Never>?
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
  private var reactionOverlayControl: UIControl?
  private var reactionOverlayHost: UIViewController?

  // MARK: - Initialization

  init(
    dataSource: DataSource,
    navigationPath: Binding<NavigationPath>,
    appState: AppState
  ) {
    self.dataSource = dataSource
    self.navigationPath = navigationPath
    self.appState = appState
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    observationTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupCollectionView()
    setupDataSource()
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

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Only tear down observation when truly leaving the screen (popped from nav stack),
    // not when a sheet or full-screen cover is presented over this view controller.
    // Cancelling here caused incoming websocket messages to be silently dropped from the
    // UI because the snapshot was never updated while observation was inactive.
    if isMovingFromParent || isBeingDismissed {
      observationTask?.cancel()
      observationTask = nil
    }
  }

  // MARK: - Setup

  private func setupCollectionView() {
    collectionView = ChatTranscriptCollectionView(frame: view.bounds, collectionViewLayout: createLayout())
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.prefetchDataSource = self
    collectionView.keyboardDismissMode = .interactive
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
            onLongPress: { bubbleGlobalFrame in
              self.onMessageLongPress?(message)
              self.presentReactionOverlay(messageID: messageID, bubbleGlobalFrame: bubbleGlobalFrame)
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
            groupPosition: UnifiedMessageGrouping.groupPosition(for: messageID, in: self.dataSource.messages)
          )
          .environment(appState)
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

  private func setupObservation() {
    observationTask?.cancel()
    observationTask = Task { @MainActor [weak self] in
      guard let self else { return }

      // Perform an initial snapshot so the UI is populated immediately.
      await self.processObservationCycle()

      // Re-arm observation each time a tracked property changes.
      while !Task.isCancelled {
        // withObservationTracking calls `apply` synchronously to register
        // which @Observable properties are read, then invokes `onChange`
        // asynchronously the NEXT time any of them mutates.
        await withCheckedContinuation { continuation in
          withObservationTracking {
            // Touch the observable properties we care about so the
            // tracking system knows to wake us when they change.
            _ = self.dataSource.messages
            _ = self.dataSource.showsTypingIndicator
            _ = self.dataSource.typingParticipantAvatarURL
            _ = self.dataSource.scrollToBottomTrigger
          } onChange: {
            continuation.resume()
          }
        }

        guard !Task.isCancelled else { break }
        await self.processObservationCycle()
      }
    }
  }

  @MainActor
  private func processObservationCycle() async {
    let newItems = currentSnapshotItems()
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
      (forceScrollToBottom || wasLockedToBottom || shouldAutoScrollForNewItems)
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
      // Apply without any animation for the initial load, then scroll to bottom
      // and reveal the collection view in one frame.
      UIView.performWithoutAnimation {
        diffableDataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()
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

  func updateNavigationBinding(_ binding: Binding<NavigationPath>) {
    navigationPath = binding
  }

  func updateAppState(_ newAppState: AppState) {
    if appState?.userDID != newAppState.userDID {
      reactionDetailsController?.dismiss(animated: false)
      dismissReactionOverlay()
    }
    appState = newAppState
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
  
  @objc private func reactionOverlayTappedOutside() {
    dismissReactionOverlay()
  }

  @MainActor
  private func dismissReactionOverlay() {
    reactionOverlayHost?.willMove(toParent: nil)
    reactionOverlayHost?.view.removeFromSuperview()
    reactionOverlayHost?.removeFromParent()
    reactionOverlayHost = nil

    reactionOverlayControl?.removeFromSuperview()
    reactionOverlayControl = nil
  }

  @MainActor
  private func presentReactionDetailsSheet(messageID: String) {
    dismissReactionOverlay()

    guard let message = dataSource.message(for: messageID) else { return }
    guard !message.isSystemMessage, !message.reactions.isEmpty else { return }

    guard let appState else { return }
    let accountDID = appState.userDID
    let host = UIHostingController(rootView: UnifiedReactionDetailsSheet(
      dataSource: dataSource,
      messageID: messageID,
      appState: appState,
      accountDID: accountDID
    ))
    host.modalPresentationStyle = .pageSheet
    reactionDetailsController = host
    present(host, animated: true)
  }

  @MainActor
  private func presentReactionOverlay(messageID: String, bubbleGlobalFrame: CGRect) {
    dismissReactionOverlay()

    guard let message = dataSource.message(for: messageID) else { return }

    let overlay = MessageLongPressOverlay(
      quickReactions: UnifiedQuickReactionBar.defaultQuickReactions,
      onReactionSelected: { [weak self] emoji in
        guard let self else { return }
        Task { @MainActor in
          self.dataSource.addReaction(messageID: messageID, emoji: emoji)
          self.onReactionTapped?(messageID, emoji)
          self.dismissReactionOverlay()
        }
      },
      onMoreTapped: { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          self.dismissReactionOverlay()
          self.onRequestEmojiPicker?(messageID)
        }
      },
      canEdit: message.canEdit,
      canUnsend: message.canUnsend,
      onEditTapped: { [weak self] in
        guard let self else { return }
        self.dismissReactionOverlay()
        self.onEditMessage?(message)
      },
      onUnsendTapped: { [weak self] in
        guard let self else { return }
        self.dismissReactionOverlay()
        let alert = UIAlertController(
          title: "Unsend Message",
          message: "This removes the message for everyone in the conversation.",
          preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unsend", style: .destructive) { [weak self] _ in
          self?.onUnsendMessage?(message)
        })
        self.present(alert, animated: true)
      }
    )

    let host = UIHostingController(rootView: overlay)
    host.view.backgroundColor = .clear

    let control = UIControl(frame: view.bounds)
    control.backgroundColor = .clear
    control.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    control.addTarget(self, action: #selector(reactionOverlayTappedOutside), for: .touchUpInside)

    addChild(host)
    control.addSubview(host.view)
    host.didMove(toParent: self)

    let bubbleFrame: CGRect
    let cellFrame: CGRect?
    if
      let indexPath = diffableDataSource.indexPath(for: .message(id: messageID)),
      let cell = collectionView.cellForItem(at: indexPath)
    {
      // SwiftUI's `.global` inside a UIHostingConfiguration is effectively global *to the hosting view*.
      // Convert from the cell's hosting view into our view so the overlay positions correctly.
      let referenceView = cell.contentView.subviews.first ?? cell.contentView
      bubbleFrame = referenceView.convert(bubbleGlobalFrame, to: view)
      cellFrame = cell.convert(cell.bounds, to: view)
    } else {
      bubbleFrame = bubbleGlobalFrame
      cellFrame = nil
    }

    let fittingSize = CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height)
    let barSize = host.sizeThatFits(in: fittingSize)

    // Match the bubble's horizontal alignment: incoming messages sit after the avatar column,
    // outgoing messages align to the trailing edge.
    let horizontalPadding: CGFloat = 12
    let avatarColumnWidth: CGFloat = 32
    let avatarSpacing: CGFloat = 8

    var x: CGFloat
    if message.isFromCurrentUser {
      x = (cellFrame?.maxX ?? bubbleFrame.maxX) - horizontalPadding - barSize.width
    } else {
      x = (cellFrame?.minX ?? bubbleFrame.minX) + horizontalPadding + avatarColumnWidth + avatarSpacing
    }
    x = min(max(x, 8), view.bounds.width - barSize.width - 8)

    var y = bubbleFrame.minY - barSize.height - 8
    y = max(y, view.safeAreaInsets.top + 8)

    host.view.frame = CGRect(origin: CGPoint(x: x, y: y), size: barSize)

    view.addSubview(control)

    reactionOverlayControl = control
    reactionOverlayHost = host
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

  // MARK: - UICollectionViewDataSourcePrefetching

  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    // Hook for future media prefetching
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cancelPrefetchingForItemsAt indexPaths: [IndexPath]
  ) {
    // Hook for cancelling prefetch work when cells leave the screen
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

// MARK: - Typing Indicator View

@available(iOS 16.0, *)
private struct TypingIndicatorView: View {
  let avatarURL: URL?
  @State private var animate = false

  var body: some View {
    HStack(spacing: 8) {
      if let avatarURL {
        LazyImage(url: avatarURL) { state in
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

@available(iOS 16.0, *)
struct MessageLongPressOverlay: View {
  let quickReactions: [String]
  let onReactionSelected: (String) -> Void
  let onMoreTapped: () -> Void
  let canEdit: Bool
  let canUnsend: Bool
  let onEditTapped: () -> Void
  let onUnsendTapped: () -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      UnifiedQuickReactionBar(
        quickReactions: quickReactions,
        onReactionSelected: onReactionSelected,
        onMoreTapped: onMoreTapped
      )

      if canEdit || canUnsend {
        HStack(spacing: 16) {
          if canEdit {
            Button(action: onEditTapped) {
              Label("Edit", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.medium))
            }
            .tint(.primary)
          }

          if canUnsend {
            Button(role: .destructive, action: onUnsendTapped) {
              Label("Unsend", systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
      }
    }
  }
}
#endif
