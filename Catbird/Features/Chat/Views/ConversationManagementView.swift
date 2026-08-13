import OSLog
import SwiftUI
import Petrel

/// Conversation settings sheet: hero header, quick glass actions, member
/// administration (rename, add/remove, join links, join requests) for owned
/// groups, and the leave/lock flows.
struct ConversationManagementView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  /// Presentation snapshot; the body reads the live copy from ChatManager so
  /// admin mutations (rename, membership) refresh in place.
  let conversation: ChatBskyConvoDefs.ConvoView

  @State private var isProcessing = false
  @State private var errorMessage: String?
  @State private var showingLeaveAlert = false
  @State private var showingOwnerLeaveAlert = false
  @State private var showingEditNameAlert = false
  @State private var showingLockConfirmation = false
  @State private var showingAddMembers = false
  @State private var editedName = ""

  private let logger = Logger(subsystem: "blue.catbird", category: "ConversationManagementView")

  // MARK: - Derived State

  /// Live conversation from the manager's cache, falling back to the snapshot.
  private var convo: ChatBskyConvoDefs.ConvoView {
    appState.chatManager.conversations.first(where: { $0.id == conversation.id }) ?? conversation
  }

  private var groupMetadata: ChatBskyConvoDefs.GroupConvo? {
    convo.groupMetadata
  }

  /// Group owners can't leave until the group is locked (`OwnerCannotLeave`),
  /// so they get the lock-then-leave confirmation instead.
  private var isOwnedGroup: Bool {
    convo.isOwnedGroupConversation(currentUserDID: appState.userDID)
  }

  private var displayTitle: String {
    convo.displayTitle(currentUserDID: appState.userDID)
  }

  private var joinLink: ChatBskyGroupDefs.JoinLinkView? {
    groupMetadata?.joinLink
  }

  private var joinLinkEnabled: Bool {
    guard let joinLink else { return false }
    return joinLink.enabledStatus.rawValue
      == ChatBskyGroupDefs.LinkEnabledStatus.enabled.rawValue
  }

  /// Same URL shape the join-link message embed uses for copying.
  private var inviteURL: URL? {
    guard let joinLink, joinLinkEnabled else { return nil }
    return URL(string: "https://bsky.app/chat/\(joinLink.code)")
  }

  private var atMemberLimit: Bool {
    guard let groupMetadata else { return false }
    return groupMetadata.memberCount >= groupMetadata.memberLimit
  }

  private var memberIDs: [String] {
    convo.members.map { $0.did.didString() }
  }

  var body: some View {
    NavigationStack {
      List {
        headerSection
        if convo.isGroupConversation {
          membersSection
        }
        if isOwnedGroup {
          groupAdministrationSection
        }
        leaveSection
      }
      .animation(.spring(response: 0.35, dampingFraction: 0.8), value: memberIDs)
      .navigationTitle("Details")
    #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }

        ToolbarItem(placement: .primaryAction) {
          if isProcessing {
            ProgressView()
              .scaleEffect(0.8)
          }
        }
      }
      .sheet(isPresented: $showingAddMembers) {
        AddGroupMembersSheet(convoId: convo.id, existingMemberDIDs: Set(memberIDs))
      }
      .alert("Leave Conversation", isPresented: $showingLeaveAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Leave", role: .destructive) {
          leaveConversation()
        }
      } message: {
        Text("Are you sure you want to leave this conversation? You will no longer receive messages from this conversation.")
      }
      .alert("Lock & Leave Group", isPresented: $showingOwnerLeaveAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Lock & Leave", role: .destructive) {
          lockAndLeaveConversation()
        }
      } message: {
        Text("As the owner, you must lock this group before leaving. Your messages will be deleted for you, but not for the other participants.")
      }
      .alert("Edit Group Name", isPresented: $showingEditNameAlert) {
        TextField("Group name", text: $editedName)
        Button("Cancel", role: .cancel) { }
        Button("Save") {
          renameGroup()
        }
      } message: {
        Text("Everyone in the group will see the new name.")
      }
      .alert("Lock Group", isPresented: $showingLockConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Lock", role: .destructive) {
          lockGroup()
        }
      } message: {
        Text("Locking stops all new messages and reactions for every member. You can unlock the group later.")
      }
      .alert("Error", isPresented: errorAlertBinding) {
        Button("OK") {
          errorMessage = nil
        }
      } message: {
        Text(errorMessage ?? "An unknown error occurred")
      }
    }
  }

  private var errorAlertBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  // MARK: - Header

  private var headerSection: some View {
    Section {
      VStack(spacing: 20) {
        ConversationHeroView(conversation: convo, currentUserDID: appState.userDID)
        quickActionsRow
      }
      .frame(maxWidth: .infinity)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }

  @ViewBuilder
  private var quickActionsRow: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      GlassEffectContainer(spacing: 20) {
        quickActionsContent
      }
    } else {
      quickActionsContent
    }
  }

  private var quickActionsContent: some View {
    HStack(alignment: .top, spacing: 20) {
      QuickActionButton(
        title: convo.muted ? "Unmute" : "Mute",
        systemImage: convo.muted ? "bell" : "bell.slash",
        isDisabled: isProcessing
      ) {
        toggleMute()
      }

      QuickActionButton(
        title: "Mark Read",
        systemImage: "envelope.open",
        isDisabled: isProcessing || convo.unreadCount == 0
      ) {
        markAsRead()
      }

      if isOwnedGroup {
        QuickActionButton(
          title: "Edit Name",
          systemImage: "pencil",
          isDisabled: isProcessing
        ) {
          editedName = groupMetadata?.name ?? displayTitle
          showingEditNameAlert = true
        }
      }
    }
  }

  // MARK: - Members

  private var membersSection: some View {
    Section {
      if isOwnedGroup {
        Button {
          showingAddMembers = true
        } label: {
          Label("Add Members", systemImage: "plus")
        }
        .disabled(isProcessing || atMemberLimit)
      }

      ForEach(convo.members, id: \.did) { member in
        GroupMemberRow(
          member: member,
          isCurrentUser: member.did.didString() == appState.userDID
        )
        .modifier(
          RemovableMemberModifier(
            canRemove: canRemove(member),
            isProcessing: isProcessing,
            memberName: member.chatDisplayName
          ) {
            removeMember(member)
          }
        )
      }
    } header: {
      HStack {
        Text("Members")
        Spacer()
        if let groupMetadata {
          Text("\(groupMetadata.memberCount) of \(groupMetadata.memberLimit)")
            .contentTransition(.numericText())
        }
      }
    } footer: {
      if isOwnedGroup && atMemberLimit {
        Text("This group is at its member limit.")
      }
    }
  }

  private func canRemove(_ member: ChatBskyActorDefs.ProfileViewBasic) -> Bool {
    guard isOwnedGroup else { return false }
    return member.did.didString() != appState.userDID
  }

  // MARK: - Group Administration

  private var groupAdministrationSection: some View {
    Section {
      NavigationLink {
        GroupJoinRequestsView(convoId: convo.id)
      } label: {
        Label("Join Requests", systemImage: "person.crop.circle.badge.questionmark")
          .badge(groupMetadata?.joinRequestCount ?? 0)
      }

      Toggle(isOn: joinLinkToggleBinding) {
        Label("Invite Link", systemImage: "link")
      }
      .disabled(isProcessing)

      if let inviteURL {
        ShareLink(item: inviteURL) {
          Label("Share Invite Link", systemImage: "square.and.arrow.up")
        }

        Button {
          PlatformApplication.copyToClipboard(inviteURL.absoluteString)
        } label: {
          Label("Copy Invite Link", systemImage: "doc.on.doc")
        }
      }

      if convo.isLockedForSending {
        Button {
          unlockGroup()
        } label: {
          Label("Unlock Group", systemImage: "lock.open")
        }
        .disabled(isProcessing || groupMetadata?.lockStatusModerationOverride == true)
      } else {
        Button {
          showingLockConfirmation = true
        } label: {
          Label("Lock Group", systemImage: "lock")
        }
        .disabled(isProcessing)
      }
    } header: {
      Text("Group Administration")
    } footer: {
      if groupMetadata?.lockStatusModerationOverride == true {
        Text("This group was locked by moderation and can't be unlocked.")
      } else if joinLinkEnabled {
        Text("Anyone with the invite link can join this group.")
      }
    }
  }

  private var joinLinkToggleBinding: Binding<Bool> {
    Binding(
      get: { joinLinkEnabled },
      set: { newValue in
        setJoinLink(enabled: newValue)
      }
    )
  }

  // MARK: - Leave

  private var leaveSection: some View {
    Section {
      Button(role: .destructive) {
        if isOwnedGroup {
          showingOwnerLeaveAlert = true
        } else {
          showingLeaveAlert = true
        }
      } label: {
        Label(
          isOwnedGroup ? "Lock & Leave Group" : "Leave Conversation",
          systemImage: "rectangle.portrait.and.arrow.right"
        )
      }
      .disabled(isProcessing)
    } footer: {
      if isOwnedGroup {
        Text("As the owner, you must lock this group before leaving. Locking stops all new messages and reactions for every member.")
      } else {
        Text("Leaving this conversation will remove it from your chat list. You won't receive new messages unless someone starts a new conversation with you.")
      }
    }
  }

  // MARK: - Actions

  /// Runs a mutation with the shared processing flag, surfacing errors inline
  /// (the global chat error alert can't present over this sheet).
  private func performAdminAction(_ operation: @escaping () async throws -> Void) {
    Task {
      isProcessing = true
      defer { isProcessing = false }
      do {
        try await operation()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func toggleMute() {
    let convoId = convo.id
    let muted = convo.muted
    performAdminAction {
      if muted {
        await appState.chatManager.unmuteConversation(convoId: convoId)
      } else {
        await appState.chatManager.muteConversation(convoId: convoId)
      }
      // Mute endpoints don't return the ConvoView; re-fetch so the live copy
      // this sheet renders picks up the new muted flag.
      await appState.chatManager.refreshConversation(convoId: convoId)
    }
  }

  private func markAsRead() {
    let convoId = convo.id
    performAdminAction {
      await appState.chatManager.markConversationAsRead(convoId: convoId)
    }
  }

  private func renameGroup() {
    let convoId = convo.id
    let newName = editedName
    performAdminAction {
      try await appState.chatManager.renameGroup(convoId: convoId, name: newName)
    }
  }

  private func removeMember(_ member: ChatBskyActorDefs.ProfileViewBasic) {
    let convoId = convo.id
    let memberDID = member.did.didString()
    performAdminAction {
      try await appState.chatManager.removeGroupMember(convoId: convoId, memberDID: memberDID)
    }
  }

  private func setJoinLink(enabled: Bool) {
    let convoId = convo.id
    performAdminAction {
      if enabled {
        _ = try await appState.chatManager.enableJoinLink(convoId: convoId)
      } else {
        try await appState.chatManager.disableJoinLink(convoId: convoId)
      }
    }
  }

  private func lockGroup() {
    let convoId = convo.id
    performAdminAction {
      if await appState.chatManager.lockConversation(convoId: convoId) == .failure {
        appState.chatManager.errorState = nil
        throw GroupAdminError.underlying(
          NSError(
            domain: "ChatManager", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't lock this group. Please try again."]))
      }
    }
  }

  private func unlockGroup() {
    let convoId = convo.id
    performAdminAction {
      try await appState.chatManager.unlockConversation(convoId: convoId)
    }
  }

  private func leaveConversation() {
    Task {
      isProcessing = true
      let result = await appState.chatManager.leaveConversation(convoId: conversation.id)
      isProcessing = false
      switch result {
      case .success:
        dismiss()
      case .ownerMustLockFirst:
        // Stale role data led us down the plain-leave path; recover by
        // offering the lock-then-leave confirmation directly. Clear the
        // global error so the in-sheet confirmation is the only prompt.
        appState.chatManager.errorState = nil
        showingOwnerLeaveAlert = true
      case .failure:
        // Show the failure in-sheet; the global alert can't present over
        // this sheet, so move the message here instead.
        errorMessage = appState.chatManager.errorState?.localizedDescription
          ?? "Couldn't leave this conversation. Please try again."
        appState.chatManager.errorState = nil
      }
    }
  }

  private func lockAndLeaveConversation() {
    Task {
      isProcessing = true
      let success = await appState.chatManager.lockAndLeaveConversation(convoId: conversation.id)
      isProcessing = false
      if success {
        dismiss()
      } else {
        // Show the failure in-sheet; the global alert can't present over
        // this sheet, so move the message here instead.
        errorMessage = appState.chatManager.errorState?.localizedDescription
          ?? "Couldn't lock and leave this group. Please try again."
        appState.chatManager.errorState = nil
      }
    }
  }
}

// MARK: - Hero Header

/// Avatar cluster (or single avatar), title, and context line for the sheet header.
private struct ConversationHeroView: View {
  let conversation: ChatBskyConvoDefs.ConvoView
  let currentUserDID: String

  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    conversation.displayMembersExcludingCurrentUser(currentUserDID: currentUserDID)
  }

  private var avatarParticipants: [MLSParticipantViewModel] {
    otherMembers.map { member in
      MLSParticipantViewModel(
        id: member.did.didString(),
        handle: member.handle.description,
        displayName: member.displayName,
        avatarURL: member.finalAvatarURL()
      )
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      avatarView

      VStack(spacing: 4) {
        HStack(spacing: 6) {
          Text(conversation.displayTitle(currentUserDID: currentUserDID))
            .appFont(AppTextRole.title2)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)

          if conversation.isLockedForSending {
            Image(systemName: "lock.fill")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Locked group")
          }
        }

        if let contextLine {
          Text(contextLine)
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.top, 8)
  }

  @ViewBuilder
  private var avatarView: some View {
    if conversation.isGroupConversation {
      MLSGroupAvatarView(participants: avatarParticipants, size: 96)
    } else {
      ChatProfileAvatarView(
        profile: conversation.directDisplayMember(currentUserDID: currentUserDID),
        size: 96
      )
    }
  }

  private var contextLine: String? {
    if let group = conversation.groupMetadata {
      let created = group.createdAt.date.formatted(date: .abbreviated, time: .omitted)
      return "Created \(created)"
    }

    if conversation.isGroupConversation {
      return conversation.displaySubtitle(currentUserDID: currentUserDID)
    }

    guard let member = conversation.directDisplayMember(currentUserDID: currentUserDID),
          !member.isDeletedBlueskyChatAccount else {
      return nil
    }
    return "@\(member.handle.description)"
  }
}

// MARK: - Quick Actions

/// Circular glass action button with a caption, iMessage-details style.
private struct QuickActionButton: View {
  let title: String
  let systemImage: String
  var tint: Color = .accentColor
  var isDisabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        glyphCircle
        Text(title)
          .appFont(AppTextRole.caption)
          .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      }
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .accessibilityLabel(title)
  }

  @ViewBuilder
  private var glyphCircle: some View {
    let glyph = Image(systemName: systemImage)
      .font(.system(size: 20, weight: .medium))
      .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
      .frame(width: 56, height: 56)
      .contentShape(Circle())

    if #available(iOS 26.0, macOS 26.0, *) {
      glyph.glassEffect(.regular.interactive(), in: Circle())
    } else {
      glyph.background(Circle().fill(tint.opacity(0.12)))
    }
  }
}

// MARK: - Member Row

private struct GroupMemberRow: View {
  let member: ChatBskyActorDefs.ProfileViewBasic
  let isCurrentUser: Bool

  private var groupMemberInfo: ChatBskyActorDefs.GroupConvoMember? {
    guard case .chatBskyActorDefsGroupConvoMember(let info) = member.kind else { return nil }
    return info
  }

  private var isOwner: Bool {
    groupMemberInfo?.role.rawValue == ChatBskyActorDefs.MemberRole.owner.rawValue
  }

  var body: some View {
    HStack(spacing: 12) {
      ChatProfileAvatarView(profile: member, size: 40)

      VStack(alignment: .leading, spacing: 2) {
        Text(isCurrentUser ? "You" : member.chatDisplayName)
          .appFont(AppTextRole.body)
          .fontWeight(.medium)
          .lineLimit(1)

        Text(subtitle)
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if isOwner {
        Text("Owner")
          .appFont(AppTextRole.caption)
          .fontWeight(.medium)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.accentColor.opacity(0.15))
          .foregroundStyle(Color.accentColor)
          .clipShape(Capsule())
      }

      if member.chatDisabled == true {
        Text("Chat Disabled")
          .appFont(AppTextRole.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.red.opacity(0.15))
          .foregroundStyle(.red)
          .clipShape(Capsule())
      }
    }
  }

  private var subtitle: String {
    var parts = ["@\(member.handle.description)"]
    if let addedBy = groupMemberInfo?.addedBy, !isOwner {
      parts.append("Added by \(addedBy.chatDisplayName)")
    }
    return parts.joined(separator: " · ")
  }
}

/// Owner-only removal affordances (swipe + context menu) with confirmation.
private struct RemovableMemberModifier: ViewModifier {
  let canRemove: Bool
  let isProcessing: Bool
  let memberName: String
  let onRemove: () -> Void

  @State private var showingRemoveConfirmation = false

  func body(content: Content) -> some View {
    if canRemove {
      content
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) {
            showingRemoveConfirmation = true
          } label: {
            Label("Remove", systemImage: "person.badge.minus")
          }
          .disabled(isProcessing)
        }
        .contextMenu {
          Button(role: .destructive) {
            showingRemoveConfirmation = true
          } label: {
            Label("Remove from Group", systemImage: "person.badge.minus")
          }
          .disabled(isProcessing)
        }
        .alert("Remove \(memberName)?", isPresented: $showingRemoveConfirmation) {
          Button("Cancel", role: .cancel) { }
          Button("Remove", role: .destructive) {
            onRemove()
          }
        } message: {
          Text("They will no longer be able to see or send messages in this group.")
        }
    } else {
      content
    }
  }
}

/// View for accepting conversation invitations
struct ConversationInvitationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let conversation: ChatBskyConvoDefs.ConvoView
  
  @State private var isAccepting = false
  @State private var isDeclining = false
  @State private var errorMessage: String?
  
  private var otherMembers: [ChatBskyActorDefs.ProfileViewBasic] {
    conversation.members.filter { $0.did.didString() != appState.userDID }
  }
  
  var body: some View {
    VStack(spacing: 24) {
      // Header
      VStack(spacing: 12) {
        Image(systemName: "message.circle")
          .appFont(size: 64)
          .foregroundColor(.blue)
        
        Text("New Conversation")
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
        
        if otherMembers.count == 1 {
          Text("@\(otherMembers.first?.handle.description ?? "unknown") wants to start a conversation with you")
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
        } else {
          Text("\(otherMembers.count) people want to start a group conversation with you")
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
        }
      }
      
      // Members preview
      VStack(alignment: .leading, spacing: 12) {
        Text("Participants")
          .appFont(AppTextRole.headline)
        
        ForEach(otherMembers.prefix(3), id: \.did) { member in
          HStack {
            ChatProfileAvatarView(profile: member, size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
              Text(member.displayName ?? "Unknown")
                                .appFont(AppTextRole.body)
                .fontWeight(.medium)
              Text("@\(member.handle.description)")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
          }
        }
        
        if otherMembers.count > 3 {
          Text("and \(otherMembers.count - 3) more...")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
      }
      .padding()
      .background(Color.gray.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      
      Spacer()
      
      // Action buttons
      VStack(spacing: 12) {
        Button {
          acceptInvitation()
        } label: {
          HStack {
            if isAccepting {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Accept")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isAccepting || isDeclining)
        
        Button {
          declineInvitation()
        } label: {
          HStack {
            if isDeclining {
              ProgressView()
                .scaleEffect(0.8)
            }
            Text("Decline")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isAccepting || isDeclining)
      }
    }
    .padding()
    .alert("Error", isPresented: .constant(errorMessage != nil)) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }
  
  private func acceptInvitation() {
    Task {
      isAccepting = true
      let success = await appState.chatManager.acceptConversation(convoId: conversation.id)
      await MainActor.run {
        isAccepting = false
        if success {
          dismiss()
        } else {
          errorMessage = "Failed to accept conversation invitation"
        }
      }
    }
  }
  
  private func declineInvitation() {
    Task {
      isDeclining = true
      await appState.chatManager.leaveConversation(convoId: conversation.id)
      await MainActor.run {
        isDeclining = false
        dismiss()
      }
    }
  }
}

#Preview {
  AsyncPreviewContent { appState in
    // Mock conversation for preview
      let mockConversation = ChatBskyConvoDefs.ConvoView(
        id: "mock-convo-id",
        rev: "1",
        members: [],
        lastMessage: nil,
        lastReaction: nil,
        muted: false,
        status: .accepted,
        unreadCount: 5,
        kind: nil
      )
  
      ConversationManagementView(conversation: mockConversation)
        .environment(AppStateManager.shared)
  }
}
