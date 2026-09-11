import OSLog
import SwiftUI
import Petrel
import CatbirdMLSCore

/// View for managing message requests (conversations with status "request")
struct MessageRequestsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var selectedFilter: RequestFilter = .all
  @State private var path = NavigationPath()
  /// `UnifiedProfileView` writes to this when the user taps "search this user's
  /// posts" from inside the sheet. The sheet pushes profiles onto its own stack,
  /// so the write is inert — a local binding (same approach as `AddFeedSheet`)
  /// keeps the app's tab selection untouched.
  @State private var profileTab = 0

  private let logger = Logger(subsystem: "blue.catbird", category: "MessageRequestsView")

  enum RequestFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"

    var systemImage: String {
      switch self {
      case .all: return "tray"
      case .unread: return "tray.fill"
      }
    }
  }

  private var filteredRequests: [ChatBskyConvoDefs.ConvoView] {
    let requests = appState.chatManager.messageRequests
    switch selectedFilter {
    case .all:
      return requests
    case .unread:
      return requests.filter { $0.unreadCount > 0 }
    }
  }

  var body: some View {
    NavigationStack(path: $path) {
      VStack(spacing: 0) {
        MessageRequestsExplainerHeader()

        Divider()

        if !appState.chatManager.messageRequests.isEmpty {
          FilterPickerView(selectedFilter: $selectedFilter)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }

        if filteredRequests.isEmpty {
          EmptyRequestsView(
            filter: selectedFilter,
            hasAnyRequests: !appState.chatManager.messageRequests.isEmpty
          )
        } else {
          RequestsListView(
            requests: filteredRequests,
            onAccept: { request in
              await acceptRequest(request)
            },
            onDecline: { request in
              await declineRequest(request)
            },
            onOpenProfile: { did in
              path.append(NavigationDestination.profile(did))
            }
          )
        }
      }
      .navigationTitle("Message Requests")
#if os(iOS)
      .toolbarTitleDisplayMode(.inline)
#endif
      .navigationDestination(for: NavigationDestination.self) { destination in
        NavigationHandler.viewForDestination(
          destination,
          path: $path,
          appState: appState,
          selectedTab: $profileTab
        )
      }
      .toolbar {
        // Provide an explicit close affordance for Mac (and also handy on iOS)
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
            .keyboardShortcut(.escape, modifiers: [])
        }
        ToolbarItem(placement: .primaryAction) {
          RequestsToolbarMenu(
            hasRequests: !appState.chatManager.messageRequests.isEmpty,
            onAcceptAll: acceptAllRequests,
            onDeclineAll: declineAllRequests
          )
        }
      }
      .refreshable {
        await loadRequests()
      }
      .onAppear {
        Task {
          await loadRequests()
        }
      }
    }
  }

  private func loadRequests() async {
    await appState.chatManager.loadMessageRequests(refresh: true)
  }

  private func acceptRequest(_ request: ChatBskyConvoDefs.ConvoView) async {
    let success = await appState.chatManager.acceptMessageRequest(convoId: request.id)
    if success {
      logger.debug("Successfully accepted message request: \(request.id)")
    } else {
      logger.error("Failed to accept message request: \(request.id)")
    }
  }

  private func declineRequest(_ request: ChatBskyConvoDefs.ConvoView) async {
    let success = await appState.chatManager.declineMessageRequest(convoId: request.id)
    if success {
      logger.debug("Successfully declined message request: \(request.id)")
    } else {
      logger.error("Failed to decline message request: \(request.id)")
    }
  }

  private func acceptAllRequests() {
    Task {
      for request in filteredRequests {
        await appState.chatManager.acceptMessageRequest(convoId: request.id)
      }
    }
  }

  private func declineAllRequests() {
    Task {
      for request in filteredRequests {
        await appState.chatManager.declineMessageRequest(convoId: request.id)
      }
    }
  }
}

/// Explains who ends up here and what accepting a request does.
struct MessageRequestsExplainerHeader: View {
  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.base) {
      Image(systemName: "hand.raised.fill")
        .font(.system(size: 22))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text("People you don't follow can still message you — those conversations wait here instead of your inbox.")
          .appFont(AppTextRole.footnote)
          .fixedSize(horizontal: false, vertical: true)

        Text("Accepting moves the conversation to your inbox so you can reply. Declining removes it.")
          .appFont(AppTextRole.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, DesignTokens.Spacing.base)
    .padding(.vertical, DesignTokens.Spacing.md)
  }
}

/// Filter picker for requests
struct FilterPickerView: View {
  @Binding var selectedFilter: MessageRequestsView.RequestFilter

  var body: some View {
    Picker("Filter", selection: $selectedFilter) {
      ForEach(MessageRequestsView.RequestFilter.allCases, id: \.self) { filter in
        Text(filter.rawValue)
          .tag(filter)
      }
    }
    .pickerStyle(.segmented)
  }
}

/// Main list of message requests
struct RequestsListView: View {
  let requests: [ChatBskyConvoDefs.ConvoView]
  let onAccept: (ChatBskyConvoDefs.ConvoView) async -> Void
  let onDecline: (ChatBskyConvoDefs.ConvoView) async -> Void
  let onOpenProfile: (String) -> Void

  var body: some View {
    List {
      ForEach(requests) { request in
        MessageRequestRow(
          request: request,
          onAccept: { await onAccept(request) },
          onDecline: { await onDecline(request) },
          onOpenProfile: { did in onOpenProfile(did) }
        )
        .listRowSeparator(.visible)
      }
    }
    .listStyle(.plain)
  }
}

/// Individual message request row
struct MessageRequestRow: View {
  @Environment(AppState.self) private var appState
  let request: ChatBskyConvoDefs.ConvoView
  let onAccept: () async -> Void
  let onDecline: () async -> Void
  let onOpenProfile: (String) -> Void

  @State private var isProcessing = false
  @State private var activeSheet: RequestRowSheet?
  @State private var showingBlockConfirmation = false

  /// The row's secondary presentations. A single `sheet(item:)` layer instead of
  /// two stacked `.sheet` modifiers keeps the row cheap to compose.
  enum RequestRowSheet: String, Identifiable {
    case preview
    case report
    var id: Self { self }
  }

  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    request.members.filter { $0.did.didString() != appState.userDID }
  }

  private var primaryMember: ChatBskyActorDefs.ProfileViewBasic? {
    otherMembers.first
  }

  /// Only real, non-deleted accounts get a tappable profile.
  private var profileDID: String? {
    guard let member = primaryMember, !member.isDeletedBlueskyChatAccount else { return nil }
    return member.did.didString()
  }

  private var displayName: String {
    primaryMember?.chatDisplayName ?? request.displayTitle(currentUserDID: appState.userDID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.base) {
        avatarButton

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          HStack(spacing: DesignTokens.Spacing.xs) {
            nameLabel

            if request.unreadCount > 0 {
              Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            if let date = lastMessageDate {
              Text(formatDate(date))
                .appFont(AppTextRole.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Last activity \(formatDate(date))")
            }
          }

          if let handle = primaryMember?.handle.description, !handle.isEmpty {
            Text("@\(handle)")
              .appFont(AppTextRole.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          if otherMembers.count > 1 {
            Text("and \(otherMembers.count - 1) other\(otherMembers.count > 2 ? "s" : "")")
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      RequestMessagePreview(lastMessage: request.lastMessage)
        .padding(.leading, DesignTokens.Size.avatarLG + DesignTokens.Spacing.base)

      actionButtons
        .padding(.leading, DesignTokens.Size.avatarLG + DesignTokens.Spacing.base)
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
    .accessibilityElement(children: .contain)
    .alert("Block \(displayName)?", isPresented: $showingBlockConfirmation) {
      Button("Cancel", role: .cancel) { }
      Button("Block", role: .destructive) { blockAndDecline() }
    } message: {
      Text("They won't be able to message you, and this request will be removed.")
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .preview:
        MessageRequestPreviewView(request: request)
      case .report:
        ReportConversationView(conversation: request, onConversationLeft: {
          Task { await onDecline() }
        })
      }
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var avatarButton: some View {
    if let did = profileDID {
      Button {
        onOpenProfile(did)
      } label: {
        avatar
      }
      .buttonStyle(.plain)
      .accessibilityLabel("View \(displayName)'s profile")
      .accessibilityHint("Opens profile")
    } else {
      avatar
    }
  }

  @ViewBuilder
  private var avatar: some View {
    if request.isGroupConversation {
      MLSGroupAvatarView(
        participants: otherMembers.map { member in
          MLSParticipantViewModel(
            id: member.did.didString(),
            handle: member.handle.description,
            displayName: member.displayName,
            avatarURL: member.finalAvatarURL()
          )
        },
        size: DesignTokens.Size.avatarLG
      )
    } else {
      ChatProfileAvatarView(profile: primaryMember, size: DesignTokens.Size.avatarLG)
    }
  }

  @ViewBuilder
  private var nameLabel: some View {
    if let did = profileDID {
      Button {
        onOpenProfile(did)
      } label: {
        HStack(spacing: DesignTokens.Spacing.xs) {
          nameText
          if let member = primaryMember,
             let badgeKind = VerificationBadge.kind(for: member.verification, did: member.did) {
            VerificationBadgeView(kind: badgeKind)
              .font(.caption)
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("View \(displayName)'s profile")
    } else {
      nameText
    }
  }

  private var nameText: some View {
    Text(displayName)
      .appFont(AppTextRole.headline)
      .fontWeight(request.unreadCount > 0 ? .semibold : .regular)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .accessibilityAddTraits(.isHeader)
  }

  private var actionButtons: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button(role: .destructive) {
        run { await onDecline() }
      } label: {
        Text("Decline")
          .frame(minHeight: DesignTokens.Size.buttonSM)
      }
      .buttonStyle(.bordered)
      .disabled(isProcessing)

      Button {
        run { await onAccept() }
      } label: {
        HStack(spacing: DesignTokens.Spacing.xs) {
          if isProcessing {
            ProgressView()
              .scaleEffect(0.8)
          }
          Text("Accept")
        }
        .frame(minHeight: DesignTokens.Size.buttonSM)
      }
      .buttonStyle(.borderedProminent)
      .disabled(isProcessing)

      Spacer(minLength: 0)

      Menu {
        if request.lastMessage != nil {
          Button {
            activeSheet = .preview
          } label: {
            Label("Preview Message", systemImage: "text.bubble")
          }
        }

        if profileDID != nil {
          Button {
            activeSheet = .report
          } label: {
            Label("Report Conversation", systemImage: "exclamationmark.bubble")
          }

          Button(role: .destructive) {
            showingBlockConfirmation = true
          } label: {
            Label("Block \(displayName)", systemImage: "person.crop.circle.badge.xmark")
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .imageScale(.large)
      }
      .disabled(isProcessing)
      .accessibilityLabel("More actions for this request")
    }
  }

  // MARK: - Actions

  private func run(_ operation: @escaping () async -> Void) {
    guard !isProcessing else { return }
    isProcessing = true
    Task { @MainActor in
      await operation()
      isProcessing = false
    }
  }

  private func blockAndDecline() {
    guard let did = profileDID else { return }
    run {
      do {
        try await appState.block(did: did)
      } catch {
        // Blocking is best-effort here: the request is still removable on its own.
      }
      await onDecline()
    }
  }

  // MARK: - Date helpers

  private var lastMessageDate: Date? {
    guard let message = request.lastMessage else { return nil }
    switch message {
    case .chatBskyConvoDefsMessageView(let messageView):
      return messageView.sentAt.date
    case .chatBskyConvoDefsSystemMessageView(let systemMessage):
      return systemMessage.sentAt.date
    case .chatBskyConvoDefsDeletedMessageView, .unexpected:
      return nil
    }
  }

  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else {
      return date.formatted(date: .numeric, time: .omitted)
    }
  }
}

/// One-line preview of a request's message, used inside the row.
struct RequestMessagePreview: View {
  let lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion?

  var body: some View {
    Group {
      switch lastMessage {
      case .chatBskyConvoDefsMessageView(let messageView):
        Text(messageView.text)
          .appFont(AppTextRole.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)

      case .chatBskyConvoDefsDeletedMessageView:
        Text("Message was deleted")
          .appFont(AppTextRole.callout)
          .foregroundStyle(.secondary)
          .italic()

      case .chatBskyConvoDefsSystemMessageView:
        Text("System message")
          .appFont(AppTextRole.callout)
          .foregroundStyle(.secondary)
          .italic()

      case .unexpected:
        Text("Unsupported message type")
          .appFont(AppTextRole.callout)
          .foregroundStyle(.secondary)
          .italic()

      case nil:
        Text("No messages yet")
          .appFont(AppTextRole.callout)
          .foregroundStyle(.secondary)
          .italic()
      }
    }
  }
}

/// Preview of the last message in a request
struct MessagePreviewView: View {
  let lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion

  var body: some View {
    Group {
      switch lastMessage {
      case .chatBskyConvoDefsMessageView(let messageView):
        VStack(alignment: .leading, spacing: 4) {
          Text("Message:")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)

          Text(messageView.text)
                            .appFont(AppTextRole.body)
            .lineLimit(nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

      case .chatBskyConvoDefsDeletedMessageView:
        HStack {
          Image(systemName: "trash")
            .foregroundColor(.secondary)
          Text("Message was deleted")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
            .italic()
        }

      case .chatBskyConvoDefsSystemMessageView:
        HStack {
          Image(systemName: "info.circle")
            .foregroundColor(.secondary)
          Text("System message")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
            .italic()
        }

      case .unexpected:
        Text("Unsupported message type")
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .italic()
      }
    }
  }
}

/// Empty state for when there are no requests
struct EmptyRequestsView: View {
  let filter: MessageRequestsView.RequestFilter
  var hasAnyRequests: Bool = false

  var body: some View {
    ContentUnavailableView {
      Label(hasAnyRequests ? "No \(filter.rawValue) Requests" : "No Message Requests", systemImage: "tray")
    } description: {
      if !hasAnyRequests {
        Text("When someone you don't follow messages you, their request will show up here. Nothing to review for now.")
      } else {
        switch filter {
        case .all:
          Text("You don't have any pending message requests.")
        case .unread:
          Text("You're all caught up — no unread requests.")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Toolbar menu for bulk actions
struct RequestsToolbarMenu: View {
  let hasRequests: Bool
  let onAcceptAll: () -> Void
  let onDeclineAll: () -> Void
  
  @State private var showingAcceptAllAlert = false
  @State private var showingDeclineAllAlert = false
  
  var body: some View {
    Menu {
      Button {
        showingAcceptAllAlert = true
      } label: {
        Label("Accept All", systemImage: "checkmark.circle")
      }
      .disabled(!hasRequests)
      
      Button {
        showingDeclineAllAlert = true
      } label: {
        Label("Decline All", systemImage: "xmark.circle")
      }
      .disabled(!hasRequests)
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .alert("Accept All Requests", isPresented: $showingAcceptAllAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Accept All") {
        onAcceptAll()
      }
    } message: {
      Text("Are you sure you want to accept all message requests?")
    }
    .alert("Decline All Requests", isPresented: $showingDeclineAllAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Decline All", role: .destructive) {
        onDeclineAll()
      }
    } message: {
      Text("Are you sure you want to decline all message requests? This action cannot be undone.")
    }
  }
}

/// Full preview of a message request
struct MessageRequestPreviewView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let request: ChatBskyConvoDefs.ConvoView
  
  @State private var isProcessing = false
  
  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    request.members.filter { $0.did.didString() != appState.userDID }
  }
  
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Header
          VStack(spacing: 16) {
            // Profile pictures
            HStack(spacing: -8) {
              ForEach(otherMembers.prefix(3), id: \.did) { member in
                ChatProfileAvatarView(profile: member, size: 60)
                  .overlay(
                    Circle()
                      .stroke(Color.systemBackground, lineWidth: 2)
                  )
              }
              
              if otherMembers.count > 3 {
                ZStack {
                  Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                  
                  Text("+\(otherMembers.count - 3)")
                    .appFont(AppTextRole.headline)
                    .fontWeight(.medium)
                }
                .overlay(
                  Circle()
                    .stroke(Color.systemBackground, lineWidth: 2)
                )
              }
            }
            
            Text("Message Request")
              .appFont(AppTextRole.title2)
              .fontWeight(.semibold)
            
            if otherMembers.count == 1 {
              Text("@\(otherMembers.first?.handle.description ?? "unknown") wants to send you a message")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            } else {
              Text("\(otherMembers.count) people want to start a group conversation with you")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            }
          }
          
          // Members list
          VStack(alignment: .leading, spacing: 12) {
            Text("Participants")
              .appFont(AppTextRole.headline)
            
            ForEach(otherMembers, id: \.did) { member in
              HStack {
                ChatProfileAvatarView(profile: member, size: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                  Text(member.displayName ?? "Unknown")
                                    .appFont(AppTextRole.body)
                    .fontWeight(.medium)
                  Text("@\(member.handle.description)")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if member.chatDisabled == true {
                  Text("Chat Disabled")
                    .appFont(AppTextRole.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.2))
                    .foregroundColor(.red)
                    .clipShape(Capsule())
                }
              }
            }
          }
          .padding()
          .background(Color.gray.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          
          // Message preview if available
          if let lastMessage = request.lastMessage {
            VStack(alignment: .leading, spacing: 12) {
              Text("Last Message")
                .appFont(AppTextRole.headline)
              
              MessagePreviewView(lastMessage: lastMessage)
            }
          }
          
          Spacer(minLength: 20)
          
          // Action buttons
          VStack(spacing: 12) {
            Button {
              acceptRequest()
            } label: {
              HStack {
                if isProcessing {
                  ProgressView()
                    .scaleEffect(0.8)
                } else {
                  Image(systemName: "checkmark")
                }
                Text("Accept Request")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
            
            Button {
              declineRequest()
            } label: {
              HStack {
                Image(systemName: "xmark")
                Text("Decline Request")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
          }
        }
        .padding()
      }
      .navigationTitle("Request Preview")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
  
  private func acceptRequest() {
    Task {
      isProcessing = true
      let success = await appState.chatManager.acceptMessageRequest(convoId: request.id)
      await MainActor.run {
        isProcessing = false
        if success {
          dismiss()
        }
      }
    }
  }
  
  private func declineRequest() {
    Task {
      isProcessing = true
      await appState.chatManager.declineMessageRequest(convoId: request.id)
      await MainActor.run {
        isProcessing = false
        dismiss()
      }
    }
  }
}

#Preview {
  AsyncPreviewContent { appState in
    MessageRequestsView()
        .environment(AppStateManager.shared)
  }
}


/// Both providers share one Inbox entry point while retaining their own request flows.
enum MessageRequestProvider: String, CaseIterable, Identifiable {
  case bluesky = "Bluesky"
  case catbird = "Catbird"
  var id: Self { self }

  static func initial(pendingCatbirdCount: Int) -> Self {
    pendingCatbirdCount > 0 ? .catbird : .bluesky
  }
}

/// The presentation item carries the initial provider into the first sheet render.
struct MessageRequestSheet<SheetContent: View>: ViewModifier {
  @Binding var provider: MessageRequestProvider?
  var onDismiss: () -> Void
  @ViewBuilder var sheetContent: (MessageRequestProvider) -> SheetContent

  func body(content: Content) -> some View {
    content.sheet(item: $provider, onDismiss: onDismiss, content: sheetContent)
  }
}

struct MessageRequestProviderContainer<Bluesky: View, Catbird: View>: View {
  @State private var provider: MessageRequestProvider
  let bluesky: Bluesky
  let catbird: Catbird

  init(initialProvider: MessageRequestProvider,
       @ViewBuilder bluesky: () -> Bluesky, @ViewBuilder catbird: () -> Catbird) {
    self.bluesky = bluesky()
    self.catbird = catbird()
    _provider = State(initialValue: initialProvider)
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Request type", selection: $provider) {
        ForEach(MessageRequestProvider.allCases) { provider in
          Text(provider.rawValue).tag(provider)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("messageRequests.provider")
      .padding()
      switch provider {
      case .bluesky: bluesky
      case .catbird: catbird
      }
    }
  }
}

struct UnifiedMessageRequestsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  let initialProvider: MessageRequestProvider

  var body: some View {
    let userDID = appState.userDID
    let manager = appState.mlsConversationManager
    return MessageRequestProviderContainer(initialProvider: initialProvider) {
      MessageRequestsView()
    } catbird: {
      MLSChatRequestsView(onAcceptedConversation: { conversationID in
        await MainActor.run {
          guard appState.userDID == userDID, let manager,
                appState.mlsConversationManager === manager,
                manager.currentUserDID == userDID, !manager.isShuttingDown else { return }
          appState.navigationManager.targetMLSConversationId = conversationID
          dismiss()
        }
      })
    }
    .id(appState.userDID)
  }
}
