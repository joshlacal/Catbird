import CatbirdMLSCore
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
    case historyBoundary(id: String, text: String)

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
      case .historyBoundary(let id, _):
        hasher.combine(3)
        hasher.combine(id)
      }
    }

    static func == (lhs: Item, rhs: Item) -> Bool {
      switch (lhs, rhs) {
      case (.message(let a), .message(let b)): return a == b
      case (.dateSeparator(let a), .dateSeparator(let b)): return a == b
      case (.typingIndicator, .typingIndicator): return true
      case (.historyBoundary(let a, _), .historyBoundary(let b, _)): return a == b
      default: return false
      }
    }
  }

  // MARK: - Properties

  private var collectionView: UICollectionView!
  private var diffableDataSource: UICollectionViewDiffableDataSource<Section, Item>!

  private var navigationPath: Binding<NavigationPath>
  let dataSource: DataSource
  private weak var appState: AppState?

  private var observationTask: Task<Void, Never>?
  private var lastMessageSignaturesByID: [String: String] = [:]
  private var lastSnapshotItems: [Item] = []
  private var lastOldestMessageID: String?
  private var lastMessageCount: Int = 0
  private var isAtBottom = true
  private let bottomProximityThreshold: CGFloat = 120
  private var isLoadingOlderMessages = false
  
  // Callbacks for message actions
  var onMessageLongPress: ((Message) -> Void)?
  var onReactionTapped: ((String, String) -> Void)? // (messageID, emoji)
  var onRequestEmojiPicker: ((String) -> Void)?

  private var hasPerformedInitialScroll = false
  private var lastScrollToBottomTrigger: Int = 0

  private var reactionOverlayControl: UIControl?
  private var reactionOverlayHost: UIHostingController<UnifiedQuickReactionBar>?

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
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    setupCollectionView()
    setupDataSource()
    setupObservation()
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
    collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: createLayout())
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.prefetchDataSource = self
    collectionView.keyboardDismissMode = .interactive
    collectionView.alwaysBounceVertical = true
    collectionView.showsVerticalScrollIndicator = true
    collectionView.contentInsetAdjustmentBehavior = .automatic

    // Extra bottom inset so the last message clears the floating composer
    collectionView.contentInset.bottom = 100

    // Keep the collection view in a normal (unflipped) coordinate space.
    // We preserve scroll position when prepending older messages by adjusting contentOffset.
    collectionView.scrollsToTop = true

    // Hide until initial snapshot is applied and scrolled to bottom to prevent
    // the user seeing messages appear from the top and then jump down.
    collectionView.alpha = 0

    view.addSubview(collectionView)
  }

  private func createLayout() -> UICollectionViewLayout {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(80)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(80)
    )
    let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])

    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 4
    section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

    return UICollectionViewCompositionalLayout(section: section)
  }

  private func setupDataSource() {
    let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
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

      cell.contentConfiguration = UIHostingConfiguration {
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
          groupPosition: UnifiedMessageGrouping.groupPosition(for: messageID, in: self.dataSource.messages)
        )
        .environment(appState)
      }
      .margins(.all, 0)
    }

    let dateSeparatorRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Date> {
      cell, _, date in
      cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
      cell.selectedBackgroundView = nil

      cell.contentConfiguration = UIHostingConfiguration {
        Text(date, format: .dateTime.month().day().year())
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
      .margins(.all, 0)
    }

    let typingIndicatorRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, TypingAvatarItem> {
      cell, _, item in
      cell.backgroundConfiguration = UIBackgroundConfiguration.clear()

      cell.contentConfiguration = UIHostingConfiguration {
        TypingIndicatorView(avatarURL: item.avatarURL)
          .padding(.vertical, 4)
      }
      .margins(.all, 0)
    }

    let historyBoundaryRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
      cell, _, text in
      cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
      cell.selectedBackgroundView = nil

      cell.contentConfiguration = UIHostingConfiguration {
        HistoryBoundaryView(text: text)
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
      case .historyBoundary(_, let text):
        return collectionView.dequeueConfiguredReusableCell(
          using: historyBoundaryRegistration,
          for: indexPath,
          item: text
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
    let newSignaturesByID = currentMessageSignaturesByID()
    let stableIDs = Set(lastMessageSignaturesByID.keys).intersection(newSignaturesByID.keys)
    let changedMessageIDs = Set(stableIDs.filter {
      lastMessageSignaturesByID[$0] != newSignaturesByID[$0]
    })

    // Detect if the data source requested a scroll-to-bottom (e.g. after sending)
    let currentTrigger = dataSource.scrollToBottomTrigger
    let shouldForceScrollToBottom = currentTrigger != lastScrollToBottomTrigger
    lastScrollToBottomTrigger = currentTrigger

    if newItems != lastSnapshotItems || !changedMessageIDs.isEmpty {
      lastSnapshotItems = newItems
      lastMessageSignaturesByID = newSignaturesByID
      if shouldForceScrollToBottom {
        isAtBottom = true
      }
      await updateSnapshot(reconfiguringMessageIDs: changedMessageIDs)
    } else if shouldForceScrollToBottom {
      scrollToBottom(animated: true)
    }
  }

  // MARK: - Snapshot Updates

  @MainActor
  private func updateSnapshot(reconfiguringMessageIDs: Set<String>) async {
    guard diffableDataSource != nil else { return }
    
    // Capture current state before update for scroll position maintenance
    let previousItemCount = diffableDataSource.snapshot().numberOfItems
    let previousContentHeight = collectionView.contentSize.height
    let previousContentOffsetY = collectionView.contentOffset.y
    let previousVisibleBottom =
      previousContentOffsetY +
      collectionView.bounds.height -
      collectionView.adjustedContentInset.bottom
    let wasNearBottom = previousVisibleBottom >= previousContentHeight - bottomProximityThreshold
    let shouldScrollToBottomAfterUpdate = (previousItemCount == 0) || isAtBottom || wasNearBottom
    let currentOldestMessageID = dataSource.messages.first?.id
    let currentMessageCount = dataSource.messages.count
    let didPrependOlderMessages =
      previousItemCount > 0 &&
      currentMessageCount > lastMessageCount &&
      currentOldestMessageID != nil &&
      lastOldestMessageID != nil &&
      currentOldestMessageID != lastOldestMessageID

    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    snapshot.appendSections([.messages])

    let items = currentSnapshotItems()
    snapshot.appendItems(items, toSection: .messages)
    
    if !reconfiguringMessageIDs.isEmpty {
      snapshot.reconfigureItems(reconfiguringMessageIDs.map { .message(id: $0) })
    }
    
    // When prepending older messages or performing initial load, disable animation.
    let isInitialPopulate = !hasPerformedInitialScroll && previousItemCount == 0 && items.count > 0
    let shouldAnimate = !isInitialPopulate && !didPrependOlderMessages && previousItemCount > 0

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
      lastOldestMessageID = currentOldestMessageID
      lastMessageCount = currentMessageCount
    } else {
      diffableDataSource.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
        guard let self else { return }

        // Keep the user's viewport stable when older messages are inserted at the top.
        if didPrependOlderMessages {
          self.collectionView.layoutIfNeeded()
          let newContentHeight = self.collectionView.contentSize.height
          let deltaHeight = newContentHeight - previousContentHeight
          self.collectionView.contentOffset.y = previousContentOffsetY + deltaHeight
        } else if shouldScrollToBottomAfterUpdate {
          self.scrollToBottom(animated: shouldAnimate)
        }

        self.lastOldestMessageID = currentOldestMessageID
        self.lastMessageCount = currentMessageCount
      }
    }
  }

  func refreshIfNeeded() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.updateSnapshot(reconfiguringMessageIDs: [])
    }
  }

  func updateNavigationBinding(_ binding: Binding<NavigationPath>) {
    navigationPath = binding
  }

  func updateAppState(_ newAppState: AppState) {
    appState = newAppState
  }

  // MARK: - Actions

  private func signature(for message: Message) -> String {
    UnifiedChatRenderSignature.messageSignature(for: message)
  }
  
  private func currentMessageSignaturesByID() -> [String: String] {
    var signatures: [String: String] = [:]
    signatures.reserveCapacity(dataSource.messages.count)
    for message in dataSource.messages {
      signatures[message.id] = signature(for: message)
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
    guard let mlsMessage = message as? MLSMessageAdapter else { return }

    let mlsReactions = message.reactions.map { reaction in
      MLSMessageReaction(
        messageId: reaction.messageID,
        reaction: reaction.emoji,
        senderDID: reaction.senderDID,
        reactedAt: reaction.reactedAt
      )
    }

    let senderDIDs = Array(Set(mlsReactions.map(\.senderDID)))

    let makeSheet: ([String: MLSProfileEnricher.ProfileData]) -> MLSReactionDetailsSheet = { profiles in
      MLSReactionDetailsSheet(
        reactions: mlsReactions,
        participantProfiles: profiles,
        currentUserDID: mlsMessage.currentUserDID,
        onAddReaction: { [weak self] emoji in
          guard let self else { return }
          self.dataSource.addReaction(messageID: messageID, emoji: emoji)
        },
        onRemoveReaction: { [weak self] emoji in
          guard let self else { return }
          self.dataSource.toggleReaction(messageID: messageID, emoji: emoji)
        }
      )
    }

    let host = UIHostingController(rootView: makeSheet([:]))
    host.modalPresentationStyle = .pageSheet
    present(host, animated: true)

    Task { @MainActor [weak self, weak host] in
      guard let self, let host else { return }
      guard let appState = self.appState, let client = appState.atProtoClient else { return }

      let requestedProfiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: senderDIDs,
        using: client,
        currentUserDID: appState.userDID
      )

      var canonicalProfiles: [String: MLSProfileEnricher.ProfileData] = [:]
      canonicalProfiles.reserveCapacity(requestedProfiles.count)
      for (requestedDID, profile) in requestedProfiles {
        canonicalProfiles[MLSProfileEnricher.canonicalDID(requestedDID)] = profile
      }

      host.rootView = makeSheet(canonicalProfiles)
    }
  }

  @MainActor
  private func presentReactionOverlay(messageID: String, bubbleGlobalFrame: CGRect) {
    dismissReactionOverlay()

    guard let message = dataSource.message(for: messageID) else { return }

    let bar = UnifiedQuickReactionBar(
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
      }
    )

    let host = UIHostingController(rootView: bar)
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
      guard seenMessageIDs.insert(message.id).inserted else {
        chatLogger.warning("Duplicate message ID skipped in snapshot: \(message.id)")
        continue
      }
      let messageDay = calendar.startOfDay(for: message.sentAt)
      if seenDays.insert(messageDay).inserted {
        items.append(.dateSeparator(messageDay))
      }
      // Render history boundary markers as inline system pills
      if message.id.hasPrefix("hb-") {
        items.append(.historyBoundary(id: message.id, text: message.text))
      } else {
        items.append(.message(id: message.id))
      }
    }

    if dataSource.showsTypingIndicator {
      items.append(.typingIndicator(TypingAvatarItem(avatarURL: dataSource.typingParticipantAvatarURL)))
    }

    return items
  }

  func scrollToBottom(animated: Bool = true) {
    guard collectionView.numberOfItems(inSection: 0) > 0 else { return }
    let lastItemIndex = collectionView.numberOfItems(inSection: 0) - 1
    collectionView.scrollToItem(
      at: IndexPath(item: lastItemIndex, section: 0),
      at: .bottom,
      animated: animated
    )
  }

  // MARK: - UICollectionViewDelegate

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    let visibleBottom =
      scrollView.contentOffset.y +
      scrollView.bounds.height -
      scrollView.adjustedContentInset.bottom

    isAtBottom = visibleBottom >= scrollView.contentSize.height - bottomProximityThreshold

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
#endif
