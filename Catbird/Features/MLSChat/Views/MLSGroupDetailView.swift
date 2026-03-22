import CatbirdMLSCore
import NukeUI
import OSLog
import PhotosUI
import SwiftUI

#if os(iOS)

// MARK: - MLSGroupDetailView

/// Dedicated info screen for an MLS conversation.
/// Shows avatar, name, members, mute toggle, and leave button.
/// For 1:1 conversations, shows a simplified view without name editing or member management.
struct MLSGroupDetailView: View {
  let conversationId: String
  let conversationModel: MLSConversationModel
  let conversationManager: MLSConversationManager
  let currentUserDID: String
  let participants: [MLSParticipantViewModel]
  let participantProfiles: [String: MLSProfileEnricher.ProfileData]

  @Environment(\.dismiss) private var dismiss

  @State private var groupName: String = ""
  @State private var members: [MLSMemberModel] = []
  @State private var isLoadingMembers = true
  @State private var isSaving = false
  @State private var isLeaving = false
  @State private var showingLeaveConfirmation = false
  @State private var showingMuteOptions = false
  @State private var mutedUntil: Date?
  @State private var errorMessage: String?
  @State private var selectedAvatarItem: PhotosPickerItem?
  @State private var localAvatarData: Data?
  @State private var isUploadingAvatar = false
  @State private var showMemberHistory = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSGroupDetailView")
  private let storage = MLSStorage.shared

  // MARK: - Computed

  private var isGroupChat: Bool {
    members.count > 2
  }

  private var isMuted: Bool {
    mutedUntil.map { $0 > Date() } ?? false
  }

  private var muteStatusText: String {
    guard let until = mutedUntil, until > Date() else {
      return "On"
    }
    if until == .distantFuture {
      return "Muted"
    }
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.timeStyle = .short
    formatter.dateStyle = .short
    return "Until \(formatter.string(from: until))"
  }

  private var otherMembers: [MLSMemberModel] {
    members.filter { $0.did.lowercased() != currentUserDID.lowercased() && $0.isActive }
  }

  private var isCurrentUserAdmin: Bool {
    members.first { $0.did.lowercased() == currentUserDID.lowercased() }?.role == .admin
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      List {
        headerSection
        if isGroupChat {
          groupNameSection
        }
        notificationsSection
        encryptionSection
        if isGroupChat {
          membersSection
        } else {
          directChatInfoSection
        }
        leaveSection
      }
      .navigationTitle(isGroupChat ? "Group Info" : "Chat Info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .sheet(isPresented: $showingMuteOptions) {
        MLSMuteOptionsView(isMuted: isMuted) { date in
          Task { await setMuted(until: date) }
        }
        .presentationDetents([.medium])
      }
      .confirmationDialog(
        "Leave Conversation",
        isPresented: $showingLeaveConfirmation,
        titleVisibility: .visible
      ) {
        Button("Leave", role: .destructive) {
          Task { await leaveConversation() }
        }
      } message: {
        Text("You will no longer receive messages from this conversation. This cannot be undone.")
      }
      .sheet(isPresented: $showMemberHistory) {
        NavigationStack {
          MLSMemberHistoryView(
            conversationID: conversationId,
            currentUserDID: currentUserDID,
            database: conversationManager.database
          )
        }
      }
      .alert("Error", isPresented: .init(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        if let msg = errorMessage {
          Text(msg)
        }
      }
      .task {
        await loadData()
      }
    }
  }

  // MARK: - Header Section

  @ViewBuilder
  private var headerSection: some View {
    Section {
      VStack(spacing: 12) {
        if isGroupChat {
          PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
              MLSGroupAvatarView(
                participants: participants,
                size: 80,
                groupAvatarData: localAvatarData ?? conversationModel.avatarImageData,
                currentUserDID: currentUserDID
              )

              if isUploadingAvatar {
                ProgressView()
                  .controlSize(.small)
                  .frame(width: 24, height: 24)
                  .background(Circle().fill(.ultraThinMaterial))
              } else {
                Image(systemName: "camera.fill")
                  .font(.system(size: 10))
                  .foregroundStyle(.white)
                  .frame(width: 24, height: 24)
                  .background(Circle().fill(.blue))
              }
            }
          }
          .disabled(isUploadingAvatar)
          .onChange(of: selectedAvatarItem) { _, newItem in
            guard let newItem else { return }
            Task { await processAvatarSelection(newItem) }
          }
        } else {
          MLSGroupAvatarView(
            participants: participants,
            size: 80,
            groupAvatarData: conversationModel.avatarImageData,
            currentUserDID: currentUserDID
          )
        }

        if let title = conversationModel.title, !title.isEmpty {
          Text(title)
            .font(.title2.bold())
        } else if !isGroupChat, let other = otherMembers.first {
          VStack(spacing: 4) {
            Text(displayName(for: other))
              .font(.title2.bold())
            Text("@\(handle(for: other))")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        } else {
          Text(isGroupChat ? "Group Chat" : "Chat")
            .font(.title2.bold())
            .foregroundStyle(.secondary)
        }

        Text("\(members.filter(\.isActive).count) members")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 8, trailing: 0))
    }
  }

  // MARK: - Group Name Section

  @ViewBuilder
  private var groupNameSection: some View {
    Section("Group Name") {
      TextField("Group Name", text: $groupName)
        .onSubmit {
          Task { await saveGroupName() }
        }
        .submitLabel(.done)
        .disabled(isSaving)
        .overlay(alignment: .trailing) {
          if isSaving {
            ProgressView()
              .controlSize(.small)
          }
        }
    }
  }

  // MARK: - Notifications Section

  @ViewBuilder
  private var notificationsSection: some View {
    Section("Notifications") {
      Button {
        showingMuteOptions = true
      } label: {
        HStack {
          Label {
            Text("Notifications")
          } icon: {
            Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
              .foregroundStyle(isMuted ? Color.secondary : Color.blue)
          }
          Spacer()
          Text(muteStatusText)
            .foregroundStyle(.secondary)
          Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Encryption Section

  @ViewBuilder
  private var encryptionSection: some View {
    Section("Encryption") {
      HStack(spacing: 12) {
        Image(systemName: "lock.shield.fill")
          .foregroundStyle(.green)
          .font(.title3)
        VStack(alignment: .leading, spacing: 2) {
          Text("End-to-End Encrypted")
            .font(.body)
          Text("MLS Protocol (RFC 9420) · Epoch \(conversationModel.epoch)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Members Section

  @ViewBuilder
  private var membersSection: some View {
    Section {
      if isLoadingMembers {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
      } else {
        ForEach(members.filter(\.isActive)) { member in
          memberRow(member)
        }

        NavigationLink {
          MLSAddMemberView(
            conversationId: conversationId,
            conversationManager: conversationManager,
            existingMemberDIDs: Set(members.filter(\.isActive).map(\.did))
          )
        } label: {
          Label("Add Members", systemImage: "person.badge.plus")
        }
      }
    } header: {
      HStack {
        Text("Members (\(members.filter(\.isActive).count))")
        Spacer()
        Button {
          showMemberHistory = true
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "clock")
              .font(.caption)
            Text("History")
              .font(.caption)
          }
        }
      }
    }
  }

  // MARK: - Direct Chat Info Section

  @ViewBuilder
  private var directChatInfoSection: some View {
    if let other = otherMembers.first {
      Section("Participant") {
        memberRow(other)
      }
    }
  }

  // MARK: - Leave Section

  @ViewBuilder
  private var leaveSection: some View {
    Section {
      Button(role: .destructive) {
        showingLeaveConfirmation = true
      } label: {
        HStack {
          Spacer()
          if isLeaving {
            ProgressView()
              .controlSize(.small)
              .tint(.red)
          } else {
            Text("Leave Conversation")
          }
          Spacer()
        }
      }
      .disabled(isLeaving)
    }
  }

  // MARK: - Member Row

  @ViewBuilder
  private func memberRow(_ member: MLSMemberModel) -> some View {
    HStack(spacing: 12) {
      avatarImage(for: member)
        .frame(width: 36, height: 36)
        .clipShape(Circle())

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(displayName(for: member))
            .font(.body)
          if member.role == .admin {
            Text("Admin")
              .font(.caption2)
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(.blue))
          }
        }
        Text("@\(handle(for: member))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if member.did.lowercased() == currentUserDID.lowercased() {
        Text("You")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Avatar Image

  @ViewBuilder
  private func avatarImage(for member: MLSMemberModel) -> some View {
    let profile = participantProfiles[member.did]
      ?? participantProfiles[MLSProfileEnricher.canonicalDID(member.did)]
    if let url = profile?.avatarURL {
      LazyImage(url: url) { state in
        if let image = state.image {
          image.resizable().scaledToFill()
        } else {
          placeholderAvatar(for: member)
        }
      }
    } else {
      placeholderAvatar(for: member)
    }
  }

  @ViewBuilder
  private func placeholderAvatar(for member: MLSMemberModel) -> some View {
    ZStack {
      Circle().fill(Color.gray.opacity(0.2))
      Text(initials(for: member))
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Helpers

  private func displayName(for member: MLSMemberModel) -> String {
    let canonical = MLSProfileEnricher.canonicalDID(member.did)
    if let profile = participantProfiles[member.did] ?? participantProfiles[canonical] {
      return profile.displayName ?? profile.handle
    }
    return member.displayName ?? member.handle ?? member.did
  }

  private func handle(for member: MLSMemberModel) -> String {
    let canonical = MLSProfileEnricher.canonicalDID(member.did)
    if let profile = participantProfiles[member.did] ?? participantProfiles[canonical] {
      return profile.handle
    }
    return member.handle ?? String(member.did.suffix(12))
  }

  private func initials(for member: MLSMemberModel) -> String {
    let name = displayName(for: member)
    let components = name.split(separator: " ")
    if components.count >= 2 {
      return "\(components[0].prefix(1))\(components[1].prefix(1))".uppercased()
    }
    return String(name.prefix(2)).uppercased()
  }

  // MARK: - Actions

  @MainActor
  private func loadData() async {
    groupName = conversationModel.title ?? ""
    mutedUntil = conversationModel.mutedUntil
    localAvatarData = conversationModel.avatarImageData

    do {
      members = try await conversationManager.fetchConversationMembers(convoId: conversationId)
      isLoadingMembers = false
    } catch {
      logger.error("Failed to load members: \(error.localizedDescription)")
      isLoadingMembers = false
    }
  }

  @MainActor
  private func processAvatarSelection(_ item: PhotosPickerItem) async {
    isUploadingAvatar = true
    defer {
      isUploadingAvatar = false
      selectedAvatarItem = nil
    }

    do {
      guard let imageData = try await item.loadTransferable(type: Data.self) else {
        errorMessage = "Could not load image."
        return
      }

      guard let uiImage = UIImage(data: imageData) else {
        errorMessage = "Invalid image format."
        return
      }

      guard var jpegData = uiImage.jpegData(compressionQuality: 0.8) else {
        errorMessage = "Could not compress image."
        return
      }

      let maxSize = 1024 * 1024
      if jpegData.count > maxSize {
        guard let smaller = uiImage.jpegData(compressionQuality: 0.5) else {
          errorMessage = "Image too large."
          return
        }
        jpegData = smaller
      }

      localAvatarData = jpegData

      try await conversationManager.database.write { db in
        try db.execute(
          sql: """
            UPDATE MLSConversationModel
            SET avatarImageData = ?, updatedAt = ?
            WHERE conversationID = ? AND currentUserDID = ?
            """,
          arguments: [jpegData, Date(), conversationId, currentUserDID]
        )
      }

      logger.info("Group avatar updated locally (\(jpegData.count) bytes)")
    } catch {
      logger.error("Failed to process avatar: \(error.localizedDescription)")
      errorMessage = "Failed to update group photo."
    }
  }

  @MainActor
  private func saveGroupName() async {
    let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != conversationModel.title else { return }

    isSaving = true
    defer { isSaving = false }

    do {
      try await conversationManager.updateGroupMetadata(
        conversationId: conversationId,
        name: trimmed,
        description: nil
      )
      logger.info("Group name updated to: \(trimmed)")
    } catch {
      logger.error("Failed to update group name: \(error.localizedDescription)")
      errorMessage = "Failed to update group name."
      groupName = conversationModel.title ?? ""
    }
  }

  @MainActor
  private func setMuted(until date: Date?) async {
    do {
      try await storage.setMutedUntil(
        conversationID: conversationId,
        currentUserDID: currentUserDID,
        mutedUntil: date,
        database: conversationManager.database
      )
      mutedUntil = date
      logger.info("Mute updated for conversation \(conversationId)")
    } catch {
      logger.error("Failed to update mute: \(error.localizedDescription)")
      errorMessage = "Failed to update notification settings."
    }
  }

  @MainActor
  private func leaveConversation() async {
    isLeaving = true
    do {
      try await conversationManager.leaveConversation(convoId: conversationId)
      dismiss()
    } catch {
      logger.error("Failed to leave conversation: \(error.localizedDescription)")
      errorMessage = "Failed to leave conversation."
      isLeaving = false
    }
  }
}

#endif
