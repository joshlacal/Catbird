//
//  MLSConversationDetailView.swift
//  Catbird
//
//  Spaces-only clean-slate iOS MLS conversation detail view backed by
//  MLSClientCoordinator and UnifiedChatView.
//

import CatbirdMLSCore
import OSLog
import Petrel
import PhotosUI
import SwiftUI

#if os(iOS)

private struct MLSModerationTarget: Identifiable {
  let id = UUID()
  let did: String
  let handle: String?
  let displayName: String?
}

private struct MLSReactionInspectionTarget: Identifiable {
  let id: String
}

struct MLSConversationDetailView: View {
  let conversationId: String

  var body: some View {
    MLSRequestConversationGate(conversationID: conversationId) {
      MLSOrdinaryConversationDetailView(conversationId: conversationId)
    }
  }
}

struct MLSOrdinaryConversationDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  let conversationId: String

  @State private var dataSource: MLSConversationDataSource?
  @State private var groupTitle: String?
  @State private var groupDescription: String = ""
  @State private var spaceURI: String?
  @State private var memberDIDs: [String] = []
  @State private var showingGroupInfo = false
  @State private var showingLabyrinthSettings = false
  @State private var removeMemberDIDInput = ""
  @State private var moderationDIDInput = ""
  @State private var groupInfoError: String?

  // Resurrected inline composer, attachment pickers, edit session, & draft handoff
  @State private var editSession = MLSMessageEditSession()
  @State private var imageSender: MLSImageSender?
  @State private var showingPhotoPicker = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var embedPreviewUIImage: PlatformImage?
  @State private var showingGifPicker = false
  @State private var showingPostPicker = false
  @State private var pendingDraftText: String?

  // In-conversation moderation & reaction details sheets
  @State private var reportTarget: MLSModerationTarget?
  @State private var blockTarget: MLSModerationTarget?
  @State private var reactionDetailsTarget: MLSReactionInspectionTarget?
  @State private var showingLeaveConfirmation = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDetail")

  /// Shared Chat tab navigation path so tapping a profile or post inside UnifiedChatView
  /// pushes onto the Chat tab stack and fires onDisappear (clearing active-convo state per PR #54).
  private var chatNavigationPath: Binding<NavigationPath> {
    sceneContext.navigationManager.pathBinding(for: AppNavigationManager.chatTabIndex)
  }

  private var isChatTabActive: Bool {
    sceneContext.navigationManager.currentTabIndex == AppNavigationManager.chatTabIndex
  }

  private var showsComposer: Bool {
    guard let dataSource,
          dataSource.hasResolvedConsent,
          !dataSource.isPendingRequest else {
      return false
    }
    return !SendBlockedNotice.hidesComposer(
      for: dataSource.conversationRecoveryState,
      leave: dataSource.leavePresentation
    )
  }

  private var latestReactedMessage: MLSMessageAdapter? {
    dataSource?.messages.last { !$0.mlsReactions.isEmpty }
  }

  var body: some View {
    Group {
      if let eligibility = appState.spacesEligibility, !eligibility.eligible {
        MLSSpacesRequiredGateView(
          eligibility: eligibility,
          onReauthorizeScopes: {
            Task { await appState.reauthorizeSpacesForMLS() }
          },
          onRefreshCheck: {
            try? await appState.initializeMLS()
          }
        )
      } else if !MLSConversationIdentityBoundary.isCanonicalStableID(conversationId) {
        ContentUnavailableView(
          "Conversation Unavailable",
          systemImage: "lock.slash",
          description: Text("This conversation identifier is not a valid canonical MLS chat ID.")
        )
      } else if let dataSource {
        UnifiedChatView(
          dataSource: dataSource,
          navigationPath: chatNavigationPath,
          title: groupTitle ?? "Encrypted Chat",
          composerConfig: makeComposerConfig(for: dataSource),
          onEditMessage: { message in
            guard message.canEdit else { return }
            editSession.begin(message)
          },
          onReportMessage: { message in
            let rootDID = MLSCredentialBinding.credentialRootDID(message.senderID)
            let resolvedDID = rootDID.isEmpty ? message.senderID : rootDID
            guard !MLSCredentialBinding.isSameAccount(resolvedDID, as: appState.userDID) else { return }
            let profile = dataSource.enrichedProfilesSnapshot[MLSProfileEnricher.canonicalDID(resolvedDID)]
            reportTarget = MLSModerationTarget(
              did: resolvedDID,
              handle: profile?.handle,
              displayName: message.senderDisplayName ?? profile?.displayName ?? resolvedDID
            )
          }
        )
        .overlay(alignment: .top) {
          if appState.mlsSyncIncompleteConversationIDs.contains(conversationId) {
            Label(
              "Couldn't update this conversation. Catbird will try again.",
              systemImage: "exclamationmark.arrow.triangle.2.circlepath"
            )
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityIdentifier("mls-sync-incomplete-status")
          }
        }
      } else {
        ProgressView("Opening encrypted chat…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            showingGroupInfo = true
          } label: {
            Label("Chat Info & Metadata", systemImage: "info.circle")
          }
          Button {
            showingLabyrinthSettings = true
          } label: {
            Label("Encrypted History & Recovery", systemImage: "key.shield")
          }
          if let reactedMessage = latestReactedMessage {
            Button {
              reactionDetailsTarget = MLSReactionInspectionTarget(id: reactedMessage.id)
            } label: {
              Label("Message Reactions", systemImage: "face.smiling")
            }
          }
          Divider()
          moderationMenuItems
          Divider()
          Button(role: .destructive) {
            showingLeaveConfirmation = true
          } label: {
            Label("Leave Conversation", systemImage: "rectangle.portrait.and.arrow.right")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("mlsConversation.menu")
      }
    }
    .sheet(isPresented: $showingGroupInfo) {
      groupInfoSheet
    }
    .sheet(isPresented: $showingLabyrinthSettings) {
      NavigationStack {
        LabyrinthSettingsAndRestoreView(
          coordinator: appState.mlsCoordinator,
          currentDeviceId: appState.resolvedMLSDeviceID()
        )
      }
      .environment(appState)
    }
    .sheet(isPresented: $showingGifPicker) {
      GifPickerView { gif in
        let mp4URL = gif.media_formats.mp4?.url
          ?? gif.media_formats.loopedmp4?.url
          ?? gif.media_formats.tinymp4?.url
          ?? gif.media_formats.nanomp4?.url
        guard let mp4URL else { return }
        let thumbnailURL = gif.media_formats.tinygif?.url ?? gif.media_formats.gif?.url
        let dims = gif.media_formats.mp4?.dims
        let width = dims?.first
        let height = (dims?.count ?? 0) > 1 ? dims?[1] : nil
        dataSource?.attachedEmbed = .gif(
          MLSGIFEmbed(
            tenorURL: "https://tenor.com/view/\(gif.id)",
            mp4URL: mp4URL,
            title: gif.content_description,
            thumbnailURL: thumbnailURL,
            width: width,
            height: height
          )
        )
        embedPreviewUIImage = nil
      }
    }
    .sheet(isPresented: $showingPostPicker) {
      MLSPostPickerView { post in
        let postText: String
        if case let .knownType(record) = post.record,
           let feedPost = record as? AppBskyFeedPost
        {
          postText = feedPost.text
        } else {
          postText = ""
        }
        var images: [MLSPostImage]?
        if case let .appBskyEmbedImagesView(imagesView) = post.embed {
          let mapped = imagesView.images.compactMap { img -> MLSPostImage? in
            guard let fullsize = img.fullsize.url, let thumb = img.thumb.url else { return nil }
            return MLSPostImage(thumb: thumb, fullsize: fullsize, alt: img.alt)
          }
          images = mapped.isEmpty ? nil : mapped
        } else if case let .appBskyEmbedGalleryView(galleryView) = post.embed {
          let mapped = galleryView.items.compactMap { item -> MLSPostImage? in
            guard case let .appBskyEmbedGalleryViewImage(image) = item,
                  let fullsize = image.fullsize.url,
                  let thumb = image.thumbnail.url
            else {
              return nil
            }
            return MLSPostImage(thumb: thumb, fullsize: fullsize, alt: image.alt)
          }
          images = mapped.isEmpty ? nil : mapped
        }
        dataSource?.attachedEmbed = .post(
          MLSPostEmbed(
            uri: post.uri.uriString(),
            cid: post.cid.string,
            authorDid: post.author.did.description,
            authorHandle: post.author.handle.description,
            authorDisplayName: post.author.displayName,
            authorAvatar: post.author.finalAvatarURL(),
            text: postText,
            createdAt: post.indexedAt.date,
            likeCount: post.likeCount,
            replyCount: post.replyCount,
            repostCount: post.repostCount,
            images: images
          )
        )
        embedPreviewUIImage = nil
      }
    }
    .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
    .onChange(of: selectedPhotoItem) { _, newItem in
      guard let newItem else { return }
      selectedPhotoItem = nil
      Task { @MainActor in
        if imageSender == nil {
          imageSender = MLSImageSender(client: appState.client)
        }
        guard let sender = imageSender else { return }
        if let embed = await sender.processImage(from: newItem, convoId: conversationId) {
          dataSource?.attachedEmbed = .image(embed)
          if let data = try? await newItem.loadTransferable(type: Data.self),
             let image = PlatformImage(data: data)
          {
            let size = CGSize(width: 64, height: 64)
            let renderer = CrossPlatformImageRenderer(size: size)
            embedPreviewUIImage = renderer.image { context in
              context.interpolationQuality = .high
              image.draw(in: CGRect(origin: .zero, size: size))
            }
          }
        }
      }
    }
    .sheet(item: $reportTarget) { target in
      MLSReportSpamSheet(
        conversationId: conversationId,
        reportedDid: target.did,
        reportedDisplayName: target.displayName ?? target.handle.map { "@\($0)" } ?? target.did
      )
      .environment(appState)
    }
    .sheet(item: $blockTarget) { target in
      BlockChatSenderSheet(
        senderDid: target.did,
        senderHandle: target.handle,
        senderDisplayName: target.displayName,
        conversationId: conversationId,
        onBlocked: {
          dismiss()
        }
      )
      .environment(appState)
    }
    .sheet(item: $reactionDetailsTarget) { target in
      if let dataSource, let message = dataSource.message(for: target.id) {
        MLSReactionDetailsSheet(
          reactions: message.mlsReactions,
          participantProfiles: dataSource.enrichedProfilesSnapshot,
          currentUserDID: appState.userDID,
          onAddReaction: { emoji in
            dataSource.addReaction(messageID: message.id, emoji: emoji)
          },
          onRemoveReaction: { emoji in
            dataSource.toggleReaction(messageID: message.id, emoji: emoji)
          }
        )
      }
    }
    .alert("Leave Encrypted Conversation?", isPresented: $showingLeaveConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Leave", role: .destructive) {
        Task { await leaveCurrentConversation() }
      }
    } message: {
      Text("You will stop receiving new encrypted messages in this conversation on this account.")
    }
    .task(id: "\(appState.userDID):\(conversationId)") {
      await initializeConversation()
    }
    .onChange(of: showsComposer) { _, isShown in
      guard !isShown else { return }
      showingPhotoPicker = false
      showingGifPicker = false
      showingPostPicker = false
      editSession.cancel()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        if isChatTabActive {
          MLSActiveConversationTracker.shared.setActive(conversationId)
        }
        Task { await dataSource?.loadMessages() }
        consumePendingChatDraft()
      } else {
        MLSActiveConversationTracker.shared.setInactive(conversationId)
      }
    }
    .onChange(of: isChatTabActive) { _, active in
      if active {
        MLSActiveConversationTracker.shared.setActive(conversationId)
      } else {
        MLSActiveConversationTracker.shared.setInactive(conversationId)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: ChatDraftHandoff.didStoreDraft)) { _ in
      consumePendingChatDraft()
    }
    .onAppear {
      if isChatTabActive {
        MLSActiveConversationTracker.shared.setActive(conversationId)
      }
      consumePendingChatDraft()
    }
    .onDisappear {
      MLSActiveConversationTracker.shared.setInactive(conversationId)
      dataSource?.stopObserving()
    }
  }

  private func makeComposerConfig(for dataSource: MLSConversationDataSource) -> InlineComposerConfig? {
    guard showsComposer else { return nil }
    return InlineComposerConfig(
      placeholderText: dataSource.composerPlaceholder,
      isSendBlocked: dataSource.isSendBlockedByRecovery,
      onSend: { text in
        if let messageToEdit = editSession.prepareSubmission(draftText: text) {
          Task { @MainActor in
            let succeeded = await dataSource.editMessage(
              messageID: messageToEdit.id,
              newText: text
            )
            editSession.finish(succeeded: succeeded)
          }
        } else {
          embedPreviewUIImage = nil
          Task { @MainActor in
            await dataSource.sendMessage(text: text)
          }
        }
      },
      onAttachTapped: {},
      onPhotoPicker: {
        guard showsComposer else { return }
        showingPhotoPicker = true
      },
      onGifPicker: {
        guard showsComposer else { return }
        showingGifPicker = true
      },
      onPostPicker: {
        guard showsComposer else { return }
        showingPostPicker = true
      },
      embedPreviewImage: embedPreviewUIImage,
      hasEmbed: dataSource.attachedEmbed != nil,
      onEmbedRemoved: {
        dataSource.attachedEmbed = nil
        embedPreviewUIImage = nil
      },
      isEditMode: editSession.message != nil,
      editMessageText: editSession.draftText,
      onCancelEdit: {
        editSession.cancel()
      },
      prefillText: pendingDraftText,
      onPrefillApplied: {
        pendingDraftText = nil
      }
    )
  }

  private var nonSelfParticipantDIDs: [String] {
    var seen = Set<String>()
    var combined: [String] = []
    for raw in memberDIDs + (dataSource?.participantDIDs ?? []) {
      let root = MLSCredentialBinding.credentialRootDID(raw)
      let candidate = root.isEmpty ? raw : root
      guard !candidate.isEmpty,
            !MLSCredentialBinding.isSameAccount(candidate, as: appState.userDID),
            seen.insert(candidate).inserted else {
        continue
      }
      combined.append(candidate)
    }
    return combined
  }

  @ViewBuilder
  private var moderationMenuItems: some View {
    let participants = nonSelfParticipantDIDs
    if participants.count == 1, let peerDID = participants.first {
      let profile = dataSource?.enrichedProfilesSnapshot[MLSProfileEnricher.canonicalDID(peerDID)]
      let handleLabel = profile.map { "@\($0.handle)" }
      Button {
        reportTarget = MLSModerationTarget(
          did: peerDID,
          handle: profile?.handle,
          displayName: profile?.displayName ?? handleLabel ?? peerDID
        )
      } label: {
        Label("Report Account…", systemImage: "exclamationmark.bubble")
      }
      Button(role: .destructive) {
        blockTarget = MLSModerationTarget(
          did: peerDID,
          handle: profile?.handle,
          displayName: profile?.displayName
        )
      } label: {
        Label("Block Account…", systemImage: "hand.raised")
      }
    } else if participants.count > 1 {
      Menu {
        ForEach(participants, id: \.self) { peerDID in
          let profile = dataSource?.enrichedProfilesSnapshot[MLSProfileEnricher.canonicalDID(peerDID)]
          let handleLabel = profile.map { "@\($0.handle)" }
          let label = profile?.displayName ?? handleLabel ?? peerDID
          Button(label) {
            reportTarget = MLSModerationTarget(
              did: peerDID,
              handle: profile?.handle,
              displayName: label
            )
          }
        }
      } label: {
        Label("Report Participant…", systemImage: "exclamationmark.bubble")
      }
      Menu {
        ForEach(participants, id: \.self) { peerDID in
          let profile = dataSource?.enrichedProfilesSnapshot[MLSProfileEnricher.canonicalDID(peerDID)]
          let handleLabel = profile.map { "@\($0.handle)" }
          let label = profile?.displayName ?? handleLabel ?? peerDID
          Button(label, role: .destructive) {
            blockTarget = MLSModerationTarget(
              did: peerDID,
              handle: profile?.handle,
              displayName: profile?.displayName
            )
          }
        }
      } label: {
        Label("Block Participant…", systemImage: "hand.raised")
      }
    } else {
      Button {
        showingGroupInfo = true
      } label: {
        Label("Report or Block Participant…", systemImage: "hand.raised")
      }
    }
  }

  private var groupInfoSheet: some View {
    NavigationStack {
      Form {
        Section("Encrypted Group Metadata") {
          TextField("Title", text: Binding(
            get: { groupTitle ?? "" },
            set: { groupTitle = $0.isEmpty ? nil : $0 }
          ))
          TextField("Description", text: $groupDescription, axis: .vertical)
            .lineLimit(2...5)
          Button("Save Metadata") {
            Task { await saveGroupMetadata() }
          }
        }

        if let spaceURI {
          Section("ATProto Space") {
            Text(verbatim: spaceURI)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }

        Section("Safety & Moderation") {
          TextField("Participant DID (did:plc:… or did:web:…)", text: $moderationDIDInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          let trimmedDID = moderationDIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
          Button("Report Account…") {
            showingGroupInfo = false
            reportTarget = MLSModerationTarget(did: trimmedDID, handle: nil, displayName: trimmedDID)
          }
          .disabled(trimmedDID.isEmpty)
          Button("Block Account…", role: .destructive) {
            showingGroupInfo = false
            blockTarget = MLSModerationTarget(did: trimmedDID, handle: nil, displayName: trimmedDID)
          }
          .disabled(trimmedDID.isEmpty)
        }

        Section("Admin Member Removal") {
          TextField("Member DID (did:plc:… or did:web:…)", text: $removeMemberDIDInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("Remove Member (Admin Only)", role: .destructive) {
            Task { await removeMemberAsAdmin() }
          }
          .disabled(removeMemberDIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if let groupInfoError {
          Section {
            Text(groupInfoError)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Chat Info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { showingGroupInfo = false }
        }
      }
    }
  }

  @MainActor
  private func consumePendingChatDraft() {
    let account = appState.userDID
    guard !account.isEmpty else { return }
    guard let draft = try? ChatDraftHandoff.shared.consumeDurably(
      for: conversationId,
      accountDID: account
    ),
    !draft.isEmpty else {
      return
    }
    pendingDraftText = draft
  }

  @MainActor
  private func leaveCurrentConversation() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    do {
      do {
        try await coordinator.removeGroupMember(
          actorRole: .member,
          conversationId: conversationId,
          targetDid: coordinator.accountDid
        )
      } catch {
        try await coordinator.removeGroupMember(
          actorRole: .admin,
          conversationId: conversationId,
          targetDid: coordinator.accountDid
        )
      }
      await appState.loadMLSConversations()
      dismiss()
    } catch {
      groupInfoError = error.localizedDescription
      showingGroupInfo = true
    }
  }

  @MainActor
  private func initializeConversation() async {
    dataSource?.stopObserving()
    let source = MLSConversationDataSource(
      conversationId: conversationId,
      currentUserDID: appState.userDID,
      appState: appState
    )
    dataSource = source
    consumePendingChatDraft()
    await source.loadMessages()
    await refreshMetadata()
  }

  @MainActor
  private func refreshMetadata() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    if let metadata = try? await coordinator.getGroupMetadata(conversationId: conversationId) {
      groupTitle = metadata.title
      groupDescription = metadata.description ?? ""
    }
    if let convo = (try? await coordinator.listConversations(limit: 200))?.first(where: { $0.conversationId == conversationId }) {
      if groupTitle == nil {
        groupTitle = convo.title
      }
      spaceURI = convo.spaceUri
    }
    if let members = try? await coordinator.listMembers(conversationId: conversationId) {
      memberDIDs = members
    }
  }

  @MainActor
  private func saveGroupMetadata() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    do {
      let updated = try await coordinator.updateGroupMetadata(
        conversationId: conversationId,
        title: groupTitle ?? "",
        description: groupDescription
      )
      let updatedTitle = updated.title ?? ""
      groupTitle = updatedTitle.isEmpty ? nil : updatedTitle
      groupDescription = updated.description ?? ""
      groupInfoError = nil
    } catch {
      groupInfoError = error.localizedDescription
      logger.error("Failed to save group metadata: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func removeMemberAsAdmin() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    let targetDID = removeMemberDIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetDID.isEmpty else { return }
    do {
      try await coordinator.removeGroupMember(
        actorRole: .admin,
        conversationId: conversationId,
        targetDid: targetDID
      )
      removeMemberDIDInput = ""
      groupInfoError = nil
    } catch {
      groupInfoError = error.localizedDescription
    }
  }
}

#endif
