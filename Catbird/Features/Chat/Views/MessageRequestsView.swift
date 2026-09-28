import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

// MARK: - Presentation

/// Presents the Message Requests sheet from the Inbox entry points.
struct MessageRequestSheet<SheetContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  var onDismiss: () -> Void
  @ViewBuilder var sheetContent: () -> SheetContent

  func body(content: Content) -> some View {
    content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
      sheetContent()
        .presentationDetents([.large])
    }
  }
}

/// Live Message Requests sheet for the signed-in account: Bluesky and
/// encrypted requests in one list. Accepting routes to the new conversation
/// and closes the sheet; declining keeps the sheet open.
struct UnifiedMessageRequestsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var store: LiveMessageRequestsStore?

  var body: some View {
    Group {
      if let store, store.accountDID == appState.userDID {
        MessageRequestsScreen(
          store: store,
          onAccepted: { acceptance in routeAccepted(acceptance, accountDID: store.accountDID) },
          onClose: { dismiss() }
        )
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: appState.userDID) {
      store?.invalidate()
      let session = LiveMessageRequestsStore(appState: appState)
      store = session
      await session.refresh()
    }
    .onDisappear { store?.invalidate() }
  }

  /// F79: an accepted request opens its conversation in the Inbox and closes
  /// the sheet, but only while the accepting account is still active.
  /// F81: encrypted conversations route through the unified AppState helper,
  /// which selects the chat tab and resolves the route fail-closed.
  private func routeAccepted(_ acceptance: MessageRequestAcceptance, accountDID: String) {
    guard appState.userDID == accountDID else { return }
    switch acceptance {
    case .bluesky(let convoID):
      appState.navigationManager.targetConversationId = convoID
      selectChatTabOnMac()
    case .encrypted(let conversationID):
      appState.navigateToMLSConversation(conversationID)
      appState.stateInvalidationBus.notify(.mlsConversationListChanged)
    }
    dismiss()
  }

  private func selectChatTabOnMac() {
    #if os(macOS)
    appState.navigationManager.updateCurrentTab(AppNavigationManager.chatTabIndex)
    #endif
  }
}

// MARK: - Routes

/// In-sheet destinations besides `NavigationDestination` (profiles, posts).
enum MessageRequestRoute: Hashable {
  case detail(MessageRequestItem.ID)
}

/// What a request route shows.
enum MessageRequestDestination: Equatable {
  /// A verified encrypted request, shown through `MLSRequestConversationGate`.
  case verifiedEncrypted(conversationID: String)
  /// Any other request, shown by `MessageRequestDetailView`.
  case detail(MessageRequestItem)
  /// The request is gone (accepted, declined, or closed elsewhere).
  case handled
}

extension MessageRequestRoute {
  @MainActor
  func destination(in store: any MessageRequestsStore) -> MessageRequestDestination {
    switch self {
    case .detail(let id):
      guard let item = store.item(withID: id) else { return .handled }
      if case .encryptedDirect(let conversationID) = item.origin, store.usesVerifiedEncryptedDetail {
        return .verifiedEncrypted(conversationID: conversationID)
      }
      return .detail(item)
    }
  }
}

// MARK: - Screen

/// The Message Requests list. One inset-grouped list with a section per
/// provider; profiles and request details push inside the sheet's own stack
/// so nothing is pushed onto the tab underneath.
struct MessageRequestsScreen: View {
  @Environment(AppState.self) private var appState
  let store: any MessageRequestsStore
  let onAccepted: (MessageRequestAcceptance) -> Void
  let onClose: () -> Void

  @State private var path: NavigationPath
  /// `NavigationHandler` destinations take a tab binding for "search this
  /// user's posts"; profiles pushed in the sheet must not switch app tabs.
  @State private var sheetTab = 0
  @State private var blockCandidate: MessageRequestBlock?
  @State private var legacyBlockCandidate: MessageRequestItem?
  @State private var report: MessageRequestReport?
  @State private var noteDraft: MLSDirectComposeDraft?
  @State private var showingChatSettings = false
  @State private var showingDeclineAll = false

  init(
    store: any MessageRequestsStore,
    initialRoutes: [MessageRequestRoute] = [],
    onAccepted: @escaping (MessageRequestAcceptance) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.store = store
    self.onAccepted = onAccepted
    self.onClose = onClose
    _path = State(initialValue: NavigationPath(initialRoutes))
  }

  var body: some View {
    NavigationStack(path: $path) {
      content
        .navigationTitle("Message Requests")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .refreshable { await store.refresh() }
        .navigationDestination(for: MessageRequestRoute.self) { route in
          destination(for: route)
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(destination, path: $path, appState: appState, selectedTab: $sheetTab)
        }
    }
    .modifier(MessageRequestsSheetFrame())
    .alert("Message Requests", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(store.errorMessage ?? "Something went wrong. Please try again.")
    }
    .confirmationDialog(
      blockCandidate.map { "Block \($0.item.title)?" } ?? "Block",
      isPresented: blockDialogBinding,
      titleVisibility: .visible,
      presenting: blockCandidate
    ) { request in
      Button("Block and Remove Request", role: .destructive) {
        Task { await block(request) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { request in
      Text(request.item.source == .encrypted
        ? "Your Bluesky block is published first. The request closes only after the server confirms it."
        : "They won't be able to message you, and this request will be removed.")
    }
    .confirmationDialog("Decline all Bluesky requests?", isPresented: $showingDeclineAll, titleVisibility: .visible) {
      Button("Decline All", role: .destructive) {
        Task { await store.declineAllBluesky() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every pending Bluesky request will be removed. Encrypted requests are not affected.")
    }
    .sheet(item: $legacyBlockCandidate) { item in
      if let sender = item.sender {
        BlockChatSenderSheet(
          senderDid: sender.did,
          senderHandle: sender.handle,
          senderDisplayName: sender.displayName,
          requestId: item.conversationID,
          onBlocked: { Task { await store.refresh() } }
        )
      }
    }
    .sheet(item: $report) { report in
      reportSheet(report)
    }
    .sheet(item: $noteDraft, onDismiss: { Task { await store.refresh() } }) { draft in
      MLSDirectComposeView(draft: draft) { conversationID in
        onAccepted(.encrypted(conversationID: conversationID))
      }
    }
    .sheet(isPresented: $showingChatSettings) {
      ChatSettingsView()
    }
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    if !store.hasLoaded && store.isEmpty {
      ProgressView("Loading requests…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if store.isEmpty {
      MessageRequestsEmptyState(onOpenSettings: { showingChatSettings = true })
    } else {
      requestList
    }
  }

  private var requestList: some View {
    List {
      ForEach(MessageRequestPresentation.sections(bluesky: store.blueskyRequests, encrypted: store.encryptedRequests)) { section in
        Section {
          ForEach(section.items) { item in
            row(for: item)
          }
        } header: {
          MessageRequestsSectionHeader(source: section.source, count: section.items.count)
        } footer: {
          if section.source == .encrypted {
            Text("Encrypted requests are end-to-end encrypted. Only the people in the chat can read them.")
          }
        }
      }
      invitationNoteSections
    }
    .modifier(MessageRequestsListStyle())
    .animation(.default, value: store.blueskyRequests.map(\.id))
    .animation(.default, value: store.encryptedRequests.map(\.id))
    .accessibilityIdentifier("messageRequests.list")
  }

  private func row(for item: MessageRequestItem) -> some View {
    RequestRow(
      item: item,
      inFlight: store.inFlight[item.id],
      onOpenProfile: { did in path.append(NavigationDestination.profile(did)) },
      onOpenDetail: { path.append(MessageRequestRoute.detail(item.id)) },
      onAccept: { Task { await accept(item) } },
      onDecline: { Task { _ = await store.decline(item) } },
      onBlock: { requestBlock(item, fromDetail: false) },
      onReport: { Task { await requestReport(item) } }
    )
  }

  @ViewBuilder
  private var invitationNoteSections: some View {
    if !store.groupInvitationNotes.isEmpty {
      Section("Group invitation notes") {
        ForEach(store.groupInvitationNotes) { batch in
          NavigationLink {
            MLSGroupInvitationNotesView(batch: batch) { onClose() }
          } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
              Text("Review notes for \(batch.recipients.count) invitees")
                .designCallout()
              Text(verbatim: batch.text)
                .designFootnote()
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
    }
    if !store.savedInvitationNotes.isEmpty {
      Section("Saved invitation notes") {
        ForEach(store.savedInvitationNotes) { draft in
          Button { noteDraft = draft } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
              Label(draft.noteAttempted == true ? "Check note delivery" : "Unsent invitation note", systemImage: "square.and.pencil")
                .designCallout()
              Text(verbatim: draft.text.isEmpty ? "Write a separate encrypted note" : draft.text)
                .designFootnote()
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
    }
  }

  // MARK: Destinations

  @ViewBuilder
  private func destination(for route: MessageRequestRoute) -> some View {
    switch route.destination(in: store) {
    case .verifiedEncrypted(let conversationID):
      MLSRequestConversationGate(conversationID: conversationID, onAccepted: { convoID in
        onAccepted(.encrypted(conversationID: convoID))
      }) {
        MLSRequestOrdinaryConversation(conversationID: conversationID)
      }
    case .detail(let item):
      MessageRequestDetailView(
        item: item,
        inFlight: store.inFlight[item.id],
        onOpenProfile: { did in path.append(NavigationDestination.profile(did)) },
        onAccept: { Task { await accept(item) } },
        onDecline: {
          Task {
            if await store.decline(item), !path.isEmpty { path.removeLast() }
          }
        },
        onBlock: { requestBlock(item, fromDetail: true) },
        onReport: { Task { await requestReport(item) } }
      )
    case .handled:
      ContentUnavailableView(
        "Request Handled",
        systemImage: "tray",
        description: Text("This request was accepted, declined, or closed.")
      )
    }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button("Close") { onClose() }
        .keyboardShortcut(.cancelAction)
    }
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button {
          Task { await store.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoading)
        .keyboardShortcut("r", modifiers: .command)
        if !store.blueskyRequests.isEmpty {
          Button(role: .destructive) {
            showingDeclineAll = true
          } label: {
            Label("Decline All Bluesky Requests…", systemImage: "xmark.circle")
          }
        }
        Button {
          showingChatSettings = true
        } label: {
          Label("Chat Privacy Settings", systemImage: "gearshape")
        }
      } label: {
        Label("More", systemImage: "ellipsis")
      }
      .accessibilityIdentifier("messageRequests.toolbarMenu")
    }
  }

  // MARK: Actions

  private func accept(_ item: MessageRequestItem) async {
    guard let acceptance = await store.accept(item) else { return }
    onAccepted(acceptance)
  }

  private func requestBlock(_ item: MessageRequestItem, fromDetail: Bool) {
    guard item.canModerateSender else { return }
    if case .encryptedLegacy = item.origin {
      legacyBlockCandidate = item
    } else {
      blockCandidate = MessageRequestBlock(item: item, fromDetail: fromDetail)
    }
  }

  private func block(_ request: MessageRequestBlock) async {
    guard await store.blockAndClose(request.item) else { return }
    if request.fromDetail, !path.isEmpty { path.removeLast() }
  }

  private func requestReport(_ item: MessageRequestItem) async {
    guard let sender = item.sender, item.canModerateSender else { return }
    switch item.origin {
    case .bluesky:
      if let conversation = store.blueskyConversation(for: item) {
        report = .bluesky(conversation)
      }
    case .encryptedDirect(let conversationID), .encryptedLegacy(let conversationID):
      if let client = await store.mlsReportClient() {
        report = .encrypted(
          conversationID: conversationID,
          reportedDID: sender.did,
          reportedName: sender.name ?? item.title,
          client: client)
      } else {
        store.errorMessage = "Reporting is unavailable right now. Please try again."
      }
    }
  }

  @ViewBuilder
  private func reportSheet(_ report: MessageRequestReport) -> some View {
    switch report {
    case .bluesky(let conversation):
      ReportConversationView(conversation: conversation, onConversationLeft: {
        Task { await store.refresh() }
      })
    case .encrypted(let conversationID, let reportedDID, let reportedName, let client):
      MLSReportSpamSheet(
        conversationId: conversationID,
        reportedDid: reportedDID,
        reportedDisplayName: reportedName,
        apiClient: client
      )
    }
  }

  // MARK: Bindings

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.errorMessage != nil },
      set: { if !$0 { store.errorMessage = nil } }
    )
  }

  private var blockDialogBinding: Binding<Bool> {
    Binding(
      get: { blockCandidate != nil },
      set: { if !$0 { blockCandidate = nil } }
    )
  }
}

/// A pending block confirmation. A block confirmed from the detail screen
/// pops back to the list once the request is gone.
struct MessageRequestBlock {
  let item: MessageRequestItem
  let fromDetail: Bool
}

/// Which report flow a row's "Report…" opens.
enum MessageRequestReport: Identifiable {
  case bluesky(ChatBskyConvoDefs.ConvoView)
  case encrypted(conversationID: String, reportedDID: String, reportedName: String, client: MLSAPIClient)

  var id: String {
    switch self {
    case .bluesky(let conversation): "bsky:\(conversation.id)"
    case .encrypted(let conversationID, _, _, _): "mls:\(conversationID)"
    }
  }
}

extension MessageRequestItem {
  /// The conversation identifier the request's provider uses.
  var conversationID: String {
    switch origin {
    case .bluesky(let id), .encryptedDirect(let id), .encryptedLegacy(let id): id
    }
  }
}

/// The platform's ordinary encrypted conversation, shown by
/// `MLSRequestConversationGate` once a request is accepted.
struct MLSRequestOrdinaryConversation: View {
  let conversationID: String

  var body: some View {
    #if os(iOS)
    MLSOrdinaryConversationDetailView(conversationId: conversationID)
    #elseif os(macOS)
    MacOSMLSOrdinaryConversationView(conversationId: conversationID)
    #endif
  }
}

// MARK: - Section Header

struct MessageRequestsSectionHeader: View {
  let source: MessageRequestSource
  let count: Int

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      if source == .encrypted {
        Image(systemName: "lock.fill")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      Text(source.title)
      Text("\(count)")
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(count) request\(count == 1 ? "" : "s")")
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Empty State

struct MessageRequestsEmptyState: View {
  let onOpenSettings: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("No Message Requests", systemImage: "tray")
    } description: {
      Text("When someone you don't follow messages you, their request waits here until you accept or decline it.")
    } actions: {
      Button("Who Can Message You", action: onOpenSettings)
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("messageRequests.empty")
  }
}

// MARK: - Sheet Frame

/// macOS sheets size to their content and a `List` has no intrinsic height,
/// so the sheet needs an explicit size there. iOS uses the large detent.
private struct MessageRequestsSheetFrame: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
    content.frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 720)
    #else
    content
    #endif
  }
}

// MARK: - List Style

private struct MessageRequestsListStyle: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.listStyle(.insetGrouped)
    #else
    content.listStyle(.inset)
    #endif
  }
}

// MARK: - Request Detail

/// Read-only view of one request: the full message, who is in the chat (each
/// opens their profile), and a floating Decline/Accept bar.
struct MessageRequestDetailView: View {
  let item: MessageRequestItem
  let inFlight: MessageRequestDecision?
  let onOpenProfile: (String) -> Void
  let onAccept: () -> Void
  let onDecline: () -> Void
  let onBlock: () -> Void
  let onReport: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
        header
        messageCard
        if item.participants.count > 1 || item.isGroup {
          participantsSection
        }
        if item.canModerateSender {
          safetySection
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.xl)
      .padding(.vertical, DesignTokens.Spacing.xl)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) {
      RequestDecisionBar(inFlight: inFlight, onAccept: onAccept, onDecline: onDecline) {
        Text("Accepting moves this chat to your inbox so you can reply.")
          .designCaption()
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .navigationTitle(item.isGroup ? "Group Invitation" : "Message Request")
    .toolbarTitleDisplayMode(.inline)
    .accessibilityIdentifier("messageRequests.detailView")
  }

  private var header: some View {
    VStack(spacing: DesignTokens.Spacing.base) {
      RequestAvatar(item: item, size: DesignTokens.Size.avatarXL)
      VStack(spacing: DesignTokens.Spacing.xs) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text(item.title)
            .designHeadline()
            .multilineTextAlignment(.center)
          if let badge = item.sender?.badge {
            VerificationBadgeView(kind: badge)
              .font(.caption)
          }
        }
        if let handle = item.sender?.secondaryHandle {
          Text(handle)
            .designFootnote()
            .foregroundStyle(.secondary)
        }
        if let context = item.context {
          Text(context)
            .designCaption()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      if let sender = item.sender, sender.canOpenProfile {
        Button("View Profile") { onOpenProfile(sender.did) }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("messageRequests.detail.viewProfile")
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var messageCard: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      if case .message = item.preview, let groupTitle = item.groupTitle {
        Label(groupTitle, systemImage: "person.3")
          .designCallout()
          .fontWeight(.semibold)
      }
      switch item.preview {
      case .message(let text):
        Text(verbatim: text)
          .designBody()
          .textSelection(.enabled)
          .accessibilityIdentifier("messageRequests.detail.message")
      case .description(let text):
        Text(text)
          .designBody()
          .foregroundStyle(.secondary)
      }
      if let date = item.date {
        Text(date.formatted(date: .abbreviated, time: .shortened))
          .designCaption()
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(DesignTokens.Spacing.lg)
    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 18))
  }

  private var participantsSection: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text(item.memberCount.map { "In this chat · \($0)" } ?? "In this chat")
        .designFootnote()
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      VStack(spacing: 0) {
        ForEach(item.participants) { participant in
          participantRow(participant)
          if participant.id != item.participants.last?.id {
            Divider()
              .padding(.leading, DesignTokens.Size.avatarMD + DesignTokens.Spacing.base)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func participantRow(_ participant: RequestParticipant) -> some View {
    let label = HStack(spacing: DesignTokens.Spacing.base) {
      AsyncProfileImage(url: participant.avatarURL, size: DesignTokens.Size.avatarMD)
      VStack(alignment: .leading, spacing: 2) {
        Text(participant.name ?? "Encrypted chat member")
          .designCallout()
          .foregroundStyle(.primary)
          .lineLimit(1)
        if let handle = participant.secondaryHandle {
          Text(handle)
            .designFootnote()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if participant.canOpenProfile {
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
    .contentShape(Rectangle())

    if participant.canOpenProfile {
      Button { onOpenProfile(participant.did) } label: { label }
        .buttonStyle(.plain)
        .accessibilityHint("Opens profile")
    } else {
      label
    }
  }

  private var safetySection: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      Button(action: onReport) {
        Label("Report", systemImage: "exclamationmark.bubble")
      }
      Button(role: .destructive, action: onBlock) {
        Label("Block", systemImage: "hand.raised")
      }
    }
    .buttonStyle(.borderless)
    .designFootnote()
    .disabled(inFlight != nil)
    .frame(maxWidth: .infinity)
  }
}
