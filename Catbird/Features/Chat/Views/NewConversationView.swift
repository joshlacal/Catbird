import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

/// New conversation screen. "Message" picks a person, then the user picks the kind of
/// conversation: an encrypted chat (when the person can use it) or a Bluesky DM. The two kinds
/// are separate conversations; nothing is chosen or converted automatically.
struct NewConversationView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  /// A person picked before the screen opened, for example from a profile.
  let preselectedRecipient: NewConversationRecipient?

  init(preselectedRecipient: NewConversationRecipient? = nil) {
    self.preselectedRecipient = preselectedRecipient
  }

  // MARK: - State

  @State private var kindModel: NewConversationKindModel?
  @State private var didApplyPreselection = false
  @State private var showingIntroduction = false
  @State private var showingChatSettingsPointer = false
  @State private var showingChatSettings = false
  @State private var groupCapabilities: [String: MLSChatCapabilityStatus] = [:]

  @State private var introductionText = ""
  @State private var invitationNotes: MLSGroupInvitationNotes?
  @State private var directDraft: MLSDirectComposeDraft?
  @State private var mode: ConversationMode = .bluesky
  @State private var step: Step = .selectContacts
  @State private var selectedDIDs: Set<String> = []
  @State private var selectionOrder: [String] = []
  @State private var selectedProfiles: [String: MLSParticipantViewModel] = [:]
  @State private var groupName = ""
  @State private var isCreating = false
  @State private var creationProgress = ""
  @State private var creationTask: Task<Void, Never>?
  @State private var showingError = false
  @State private var errorTitle = String(
    localized: "Couldn’t Start Conversation",
    comment: "Default alert title when starting a conversation fails"
  )
  @State private var errorMessage: String?
  @State private var isCheckingExisting = false
  @State private var pendingGroupCreation: PendingGroupCreationStatus?
  @State private var isMutatingPendingGroup = false

  private let logger = Logger(subsystem: "blue.catbird", category: "NewConversation")

  enum ConversationMode: String, CaseIterable {
    case bluesky = "Message"
    case blueskyGroup = "Bluesky Group"
    case catbirdGroup = "Encrypted Group"

    var title: LocalizedStringKey {
      switch self {
      case .bluesky:
        return "Message"
      case .blueskyGroup:
        return "Bluesky Group"
      case .catbirdGroup:
        return "Encrypted Group"
      }
    }
  }

  enum Step {
    case selectContacts
    case configureGroup
    case creating
  }

  private var availableModes: [ConversationMode] {
    ConversationMode.allCases
  }

  private var mlsEnabled: Bool {
    appState.isMLSRuntimeAllowed
  }

  private var navigationTitle: String {
    switch (mode, step) {
    case (.bluesky, _):
      return kindModel == nil
        ? String(localized: "New Message", comment: "Navigation title when picking a contact for a new message")
        : String(localized: "Start a Conversation", comment: "Navigation title when choosing conversation type")
    case (.blueskyGroup, .selectContacts):
      return String(localized: "Add Participants", comment: "Navigation title when selecting group chat participants")
    case (.blueskyGroup, .configureGroup):
      return String(localized: "Group Details", comment: "Navigation title when naming and configuring a group chat")
    case (.blueskyGroup, .creating):
      return String(localized: "Creating Group", comment: "Navigation title while group creation is in progress")
    case (.catbirdGroup, .selectContacts):
      return mlsEnabled
        ? String(localized: "Add Participants", comment: "Navigation title when selecting group chat participants")
        : String(localized: "Encrypted Groups", comment: "Navigation title when encrypted chat opt-in gate is shown")
    case (.catbirdGroup, .configureGroup):
      return String(localized: "Group Details", comment: "Navigation title when naming and configuring a group chat")
    case (.catbirdGroup, .creating):
      return String(localized: "Creating Group", comment: "Navigation title while group creation is in progress")
    }
  }

  private var orderedSelectedParticipants: [MLSParticipantViewModel] {
    selectionOrder.compactMap { selectedProfiles[$0] }
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      ZStack {
        if let invitationNotes {
          MLSGroupInvitationNotesView(batch: invitationNotes) {
            openEncryptedConversation(invitationNotes.conversationID)
          }
        } else {
          VStack(spacing: 0) {
            segmentedPicker
            if let pendingGroupCreation, mode == .catbirdGroup {
              MLSPendingGroupCreationBanner(
                status: pendingGroupCreation,
                isBusy: isMutatingPendingGroup || isCreating,
                onRetry: { Task { await retryPendingMLSGroup(pendingGroupCreation) } },
                onCancel: { Task { await cancelPendingMLSGroup(pendingGroupCreation) } }
              )
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
            }
            mainContent
          }
        }

        if isCreating {
          creationOverlay
        }
      }
      .sheet(isPresented: $showingIntroduction) {
        MLSIntroSheet(
          onContinue: { respondToIntroduction(accept: true) },
          onNotNow: { respondToIntroduction(accept: false) }
        )
        .presentationDetents([.large])
      }
      .sheet(isPresented: $showingChatSettings) {
        ChatSettingsView()
          .applyAppStateEnvironment(appState)
      }
      .alert("Encrypted Chat Is Off", isPresented: $showingChatSettingsPointer) {
        Button("Open Chat Settings") { showingChatSettings = true }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Turn on encrypted chat in Settings > Chat to start an encrypted chat.")
      }
      .task {
        guard !didApplyPreselection else { return }
        didApplyPreselection = true
        if let preselectedRecipient { await pick(preselectedRecipient) }
      }
      .sheet(item: $directDraft) { draft in
        MLSDirectComposeView(draft: draft) { conversationID in
          openEncryptedConversation(conversationID)
        }
      }
      .navigationTitle(
        invitationNotes == nil
          ? navigationTitle
          : String(localized: "Invitation Notes", comment: "Navigation title when sending individual encrypted group invitation notes")
      )
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if invitationNotes != nil {
            EmptyView()
          } else if step == .configureGroup {
            Button("Back") {
              withAnimation(.spring(response: 0.25)) {
                step = .selectContacts
              }
            }
          } else {
            Button("Cancel") {
              creationTask?.cancel()
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if invitationNotes == nil { confirmationButton }
        }
      }
      .alert(errorTitle, isPresented: $showingError) {
        Button("OK", role: .cancel) {}
      } message: {
        if let errorMessage {
          Text(errorMessage)
        }
      }
      .onDisappear { creationTask?.cancel() }
      .onChange(of: mode) { _, _ in
        creationTask?.cancel()
        kindModel = nil
        groupCapabilities = [:]
        step = .selectContacts
        selectedDIDs.removeAll()
        selectionOrder.removeAll()
        selectedProfiles.removeAll()
        groupName = ""
      }
      .onChange(of: appState.userDID) { _, _ in
        dismiss()
        invitationNotes = nil
        introductionText = ""
        directDraft = nil
        kindModel = nil
        groupCapabilities = [:]
        creationTask?.cancel()
        step = .selectContacts
        selectedDIDs.removeAll()
        selectionOrder.removeAll()
        selectedProfiles.removeAll()
        groupName = ""
      }
    }
  }

  // MARK: - Segmented Picker

  @ViewBuilder
  private var segmentedPicker: some View {
    Picker("Type", selection: $mode) {
      ForEach(availableModes, id: \.self) { m in
        Text(m.title).tag(m)
      }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  // MARK: - Main Content

  @ViewBuilder
  private var mainContent: some View {
    switch (mode, step) {
    case (.bluesky, _):
      if let kindModel {
        ConversationKindChooserView(
          model: kindModel,
          onChoose: { kind in
            creationTask = Task { await kindModel.choose(kind, handlers: kindHandlers) }
          },
          onChangePerson: { self.kindModel = nil }
        )
      } else {
        ContactSearchList(
          selectionMode: .single,
          showMLSStatus: false,
          requiresBlueskyMessageability: false,
          selectedDIDs: .constant([]),
          selectionOrder: .constant([]),
          selectedProfiles: .constant([:]),
          onSingleSelect: { profile in await pick(NewConversationRecipient(profile: profile)) }
        )
      }

    case (.blueskyGroup, .selectContacts):
      ContactSearchList(
        selectionMode: .multi,
        showMLSStatus: false,
        selectedDIDs: $selectedDIDs,
        selectionOrder: $selectionOrder,
        selectedProfiles: $selectedProfiles
      )
      .safeAreaInset(edge: .bottom) {
        selectionActionBar
      }

    case (.blueskyGroup, .configureGroup):
      GroupConfigView(
        groupName: $groupName,
        participants: orderedSelectedParticipants,
        kind: .bluesky,
        onEditSelection: {
          withAnimation(.spring(response: 0.25)) {
            step = .selectContacts
          }
        }
      )

    case (.blueskyGroup, .creating):
      Color.clear

    case (.catbirdGroup, .selectContacts) where mlsEnabled:
      if let eligibility = appState.spacesEligibility, !eligibility.eligible {
        MLSSpacesRequiredGateView(
          eligibility: eligibility,
          onReauthorizeScopes: { present in
            await appState.reauthorizeSpacesForMLS(present: present)
          },
          onRefreshCheck: {
            try? await appState.initializeMLS()
          }
        )
      } else {
        ContactSearchList(
          selectionMode: .multi,
          showMLSStatus: true,
          selectedDIDs: $selectedDIDs,
          selectionOrder: $selectionOrder,
          selectedProfiles: $selectedProfiles,
          onMLSCapabilityChange: { did, status in groupCapabilities[did] = status }
        )
        .safeAreaInset(edge: .bottom) {
          selectionActionBar
        }
      }

    case (.catbirdGroup, .selectContacts):
      MLSOptInGateView()

    case (.catbirdGroup, .configureGroup):
      GroupConfigView(
        groupName: $groupName,
        participants: orderedSelectedParticipants,
        kind: .mls,
        introduction: $introductionText,
        onEditSelection: {
          withAnimation(.spring(response: 0.25)) {
            step = .selectContacts
          }
        }
      )

    case (.catbirdGroup, .creating):
      Color.clear
    }
  }

  // MARK: - Selection Action Bar

  /// Every picked member of an encrypted group must be able to use encrypted chat.
  private var encryptedGroupEvaluation: EncryptedGroupMembership.Evaluation {
    EncryptedGroupMembership.evaluate(selected: selectionOrder, capabilities: groupCapabilities)
  }

  private var canContinueSelection: Bool {
    !selectedDIDs.isEmpty && (mode != .catbirdGroup || encryptedGroupEvaluation.canContinue)
  }

  private func memberNames(_ dids: [String]) -> String {
    dids.map { did in selectedProfiles[did].map { "@\($0.handle)" } ?? did }.joined(separator: ", ")
  }

  @ViewBuilder
  private var encryptedGroupMembershipNotice: some View {
    let evaluation = encryptedGroupEvaluation
    if mode == .catbirdGroup, !evaluation.notCapable.isEmpty {
      Label {
        Text(
          "Encrypted chat isn’t available yet for \(memberNames(evaluation.notCapable)).",
          comment: "Notice listing selected contacts who cannot join an encrypted group yet (%@ = formatted list of handles)"
        )
      } icon: {
        Image(systemName: "lock.slash")
      }
      .designCaption()
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("newConversation.groupNotCapable")
    } else if mode == .catbirdGroup, !evaluation.unchecked.isEmpty {
      Label {
        Text(
          "Checking encrypted chat for \(memberNames(evaluation.unchecked))…",
          comment: "Progress notice while checking encrypted chat support for selected contacts (%@ = formatted list of handles)"
        )
      } icon: {
        Image(systemName: "clock")
      }
      .designCaption()
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var selectionActionBar: some View {
    let isBlueskyGroup = mode == .blueskyGroup

    VStack(spacing: DesignTokens.Spacing.sm) {
      encryptedGroupMembershipNotice
      HStack {
        if !selectedDIDs.isEmpty {
          Label {
            Text(
              "\(selectedDIDs.count) selected",
              comment: "Count of selected contacts in new group bar (%lld = selected count)"
            )
          } icon: {
            Image(systemName: "person.3")
          }
          .designCaption()
          .foregroundColor(.secondary)
        } else {
          Label("Select at least one person", systemImage: "person.badge.plus")
            .designCaption()
            .foregroundColor(.secondary)
        }
        Spacer()
      }

      Button {
        if !isBlueskyGroup && selectedDIDs.count == 1, let did = selectedDIDs.first {
          creationTask = Task { await handleDirectMLSMessage(participantDid: did) }
        } else {
          withAnimation(.spring(response: 0.25)) {
            step = .configureGroup
          }
        }
      } label: {
        if isCheckingExisting {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Group {
            if selectedDIDs.isEmpty {
              Text("Continue")
            } else {
              Text(
                "Continue (\(selectedDIDs.count))",
                comment: "Continue button showing selected contact count (%lld = selected count)"
              )
            }
          }
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canContinueSelection || isCheckingExisting)
    }
    .padding(.horizontal)
    .padding(.vertical, DesignTokens.Spacing.base)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) { Divider() }
  }

  // MARK: - Confirmation Button

  @ViewBuilder
  private var confirmationButton: some View {
    switch (mode, step) {
    case (.blueskyGroup, .selectContacts):
      Button("Next") {
        withAnimation(.spring(response: 0.25)) {
          step = .configureGroup
        }
      }
      .disabled(selectedDIDs.isEmpty)
      .fontWeight(.semibold)
    case (.blueskyGroup, .configureGroup):
      Button("Create") {
        Task { await createBlueskyGroup() }
      }
      .disabled(isCreating || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .fontWeight(.semibold)
    case (.catbirdGroup, .selectContacts) where mlsEnabled:
      Button("Next") {
        if selectedDIDs.count == 1, let did = selectedDIDs.first {
          creationTask = Task { await handleDirectMLSMessage(participantDid: did) }
        } else {
          withAnimation(.spring(response: 0.25)) {
            step = .configureGroup
          }
        }
      }
      .disabled(!canContinueSelection || isCheckingExisting)
      .fontWeight(.semibold)
    case (.catbirdGroup, .configureGroup):
      Button("Create") {
        creationTask = Task { await createMLSGroup() }
      }
      .disabled(isCreating)
      .fontWeight(.semibold)
    default:
      EmptyView()
    }
  }

  // MARK: - Creation Overlay

  @ViewBuilder
  private var creationOverlay: some View {
    let isBlueskyGroup = mode == .blueskyGroup

    ZStack {
      Color.black.opacity(0.4)
        .ignoresSafeArea()

      VStack(spacing: DesignTokens.Spacing.lg) {
        ZStack {
          Circle()
            .fill((isBlueskyGroup ? Color.accentColor : Color.green).opacity(0.2))
            .frame(width: 80, height: 80)
          Image(systemName: isBlueskyGroup ? "person.3.fill" : "lock.shield.fill")
            .font(.system(size: 36))
            .foregroundColor(isBlueskyGroup ? .accentColor : .green)
            .symbolEffect(.pulse)
        }

        VStack(spacing: DesignTokens.Spacing.sm) {
          Group {
            if isBlueskyGroup {
              Text("Creating Group Chat")
            } else {
              Text("Creating Secure Group")
            }
          }
          .font(.title3)
          .fontWeight(.semibold)
          .foregroundColor(.white)
          Text(creationProgress)
            .designCallout()
            .foregroundColor(.white.opacity(0.8))
            .multilineTextAlignment(.center)
        }

        ProgressView()
          .tint(.white)
          .scaleEffect(1.2)
      }
      .padding(32)
      .background(.ultraThinMaterial)
      .cornerRadius(DesignTokens.Size.radiusLG)
      .shadow(radius: 20)
    }
  }

  // MARK: - Bluesky Group Creation

  @MainActor
  private func createBlueskyGroup() async {
    errorTitle = String(localized: "Couldn’t Create Group", comment: "Alert title when creating a group chat fails")
    guard !selectedDIDs.isEmpty else {
      errorMessage = String(localized: "Select at least one person.", comment: "Validation error when no group members are selected")
      showingError = true
      return
    }

    let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      errorMessage = String(localized: "Enter a name for the group.", comment: "Validation error when group name is blank")
      showingError = true
      return
    }

    isCreating = true
    step = .creating
    creationProgress = String(localized: "Creating group chat…", comment: "Progress message while creating a Bluesky group chat")

    if let convoId = await appState.chatManager.startGroupConversation(
      memberDIDs: Array(selectedDIDs),
      name: trimmedName
    ) {
      logger.info("Successfully created Bluesky group conversation")
      isCreating = false
      openBlueskyConversation(convoId)
    } else {
      logger.error("Failed to create Bluesky group conversation")
      // Show the specific reason here; the sheet hides the Messages tab's alert
      errorMessage = appState.chatManager.errorState?.localizedDescription
        ?? String(
          localized: "Couldn’t create the group chat. Please try again.",
          comment: "Fallback error when creating a Bluesky group chat fails"
        )
      appState.chatManager.errorState = nil
      showingError = true
      step = .configureGroup
      isCreating = false
    }
  }

  // MARK: - Bluesky DM Creation

  // MARK: - Conversation Kind

  @MainActor
  private func selectChatTab() {
    #if os(iOS)
    let navigation = sceneContext.navigationManager
    navigation.updateCurrentTab(AppNavigationManager.chatTabIndex)
    navigation.tabSelection?(AppNavigationManager.chatTabIndex)
    #endif
  }

  @MainActor
  private func openBlueskyConversation(_ conversationID: String) {
    dismiss()
    selectChatTab()
    #if os(iOS)
    sceneContext.navigationManager.navigate(
      to: .conversation(conversationID), in: AppNavigationManager.chatTabIndex)
    #else
    sceneContext.navigationManager.targetConversationId = conversationID
    #endif
  }

  @MainActor
  private func openEncryptedConversation(_ conversationID: String) {
    dismiss()
    selectChatTab()
    sceneContext.navigationManager.targetMLSConversationId = conversationID
  }

  @MainActor
  private func pick(_ recipient: NewConversationRecipient) async {
    let model = NewConversationKindModel(
      recipient: recipient,
      checkCapability: { did, force in
        await MLSChatCapabilityResolver.shared.capability(for: did, forceRefresh: force)
      },
      selfReadiness: { [appState] in
        EncryptedChatSelfReadiness.evaluate(
          runtimeAllowed: appState.isMLSRuntimeAllowed,
          userTurnedOff: ExperimentalSettings.shared.isMLSUserDisabled(for: appState.userDID),
          eligibilityProblem: appState.spacesEligibility.flatMap { $0.eligible ? nil : $0.userMessage }
        )
      }
    )
    kindModel = model
    await model.load()
  }

  private var kindHandlers: NewConversationKindHandlers {
    NewConversationKindHandlers(
      startEncrypted: { recipient in
        selectedProfiles[recipient.did] = recipient.participant
        await handleDirectMLSMessage(participantDid: recipient.did)
      },
      startBluesky: { recipient in await startBlueskyConversation(did: recipient.did) },
      presentIntroduction: { showingIntroduction = true },
      presentChatSettingsPointer: { showingChatSettingsPointer = true },
      presentAccountNotEligible: { message in
        errorTitle = String(localized: "Encrypted Chat Unavailable", comment: "Alert title when account is not eligible for encrypted chat")
        errorMessage = message
        showingError = true
      }
    )
  }

  /// The introduction from the encrypted chat option. Continue turns encrypted chat on; the
  /// user then picks the kind again. Not now records the opt-out. Neither starts a chat.
  private func respondToIntroduction(accept: Bool) {
    showingIntroduction = false
    let accountDID = appState.userDID
    Task { @MainActor in
      guard appState.userDID == accountDID else { return }
      if accept {
        do {
          try await appState.optInToMLSChat()
        } catch {
          logger.error("Encrypted chat setup from the new conversation screen failed")
        }
      } else {
        do {
          try await appState.optOutOfMLSChat()
        } catch {
          logger.error("Encrypted chat opt-out from the new conversation screen failed")
          errorTitle = String(localized: "Couldn’t Disable Encrypted Chat", comment: "Alert title when opting out of encrypted chat fails")
          errorMessage = error.localizedDescription
          showingError = true
        }
      }
    }
  }

  @MainActor
  private func startBlueskyConversation(did: String) async {
    logger.debug("Starting Bluesky conversation")
    let accountDID = appState.userDID
    if let existing = await appState.chatManager.existingProfileConversation(
      with: did, expectedViewerDID: accountDID) {
      guard !Task.isCancelled, appState.userDID == accountDID else { return }
      openBlueskyConversation(existing.id)
      return
    }
    let canMessage = await appState.chatManager.canMessage(members: [accountDID, did])
    guard !Task.isCancelled, appState.userDID == accountDID else { return }
    guard canMessage == true else {
      errorTitle = String(localized: "Bluesky DM Unavailable", comment: "Alert title when recipient cannot receive Bluesky DMs")
      errorMessage = canMessage == false
        ? String(
            localized: "This person isn’t accepting new Bluesky DMs.",
            comment: "Error message when recipient's privacy settings disallow Bluesky DMs"
          )
        : String(
            localized: "Couldn’t check whether this person accepts Bluesky DMs. Try again.",
            comment: "Error message when checking Bluesky DM availability fails"
          )
      showingError = true
      return
    }
    if let convoId = await appState.chatManager.startConversationWith(
      userDID: did
    ) {
      guard !Task.isCancelled, appState.userDID == accountDID else { return }
      openBlueskyConversation(convoId)
    } else {
      // Show the specific reason here; the sheet hides the Messages tab's alert
      errorTitle = String(localized: "Couldn’t Start Conversation", comment: "Alert title when starting a conversation fails")
      errorMessage = appState.chatManager.errorState?.localizedDescription
        ?? String(
          localized: "Couldn’t start this conversation. Please try again.",
          comment: "Fallback error when starting a Bluesky conversation fails"
        )
      appState.chatManager.errorState = nil
      showingError = true
    }
  }

  // MARK: - MLS Direct Message (1:1)

  @MainActor
  private func handleDirectMLSMessage(participantDid: String) async {
    let accountDID = appState.userDID
    errorTitle = String(localized: "Couldn’t Start Conversation", comment: "Alert title when starting a conversation fails")

    isCheckingExisting = true
    defer { isCheckingExisting = false }

    guard await appState.getOrOpenMLSCoordinator() != nil else {
      guard !Task.isCancelled else { return }
      errorMessage = appState.spacesEligibility.flatMap { $0.eligible ? nil : $0.userMessage }
        ?? String(
          localized: "Encrypted chat isn’t ready on this device yet. Try again in a moment.",
          comment: "Error when encrypted chat engine is not initialized yet"
        )
      showingError = true
      return
    }

    if let existing = await ExistingConversationFinder.encryptedDirect(with: participantDid, appState: appState) {
      guard !Task.isCancelled, AppStateManager.shared.lifecycle.userDID == accountDID else { return }
      ExistingConversationFinder.revealIfHidden(existing.id, accountDID: accountDID)
      openEncryptedConversation(existing.id)
      return
    }

    guard !Task.isCancelled, appState.userDID == accountDID else { return }
    directDraft = MLSDirectComposeDraftStore.open(
      accountDID: accountDID,
      recipientDID: participantDid
    )
  }

  // MARK: - MLS Group Creation

  @MainActor
  private func createMLSGroup() async {
    let accountDID = appState.userDID
    let membersSnapshot = Array(selectedDIDs)
    let nameSnapshot = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    let noteSnapshot = introductionText
    errorTitle = String(localized: "Couldn’t Create Group", comment: "Alert title when creating a group chat fails")
    guard !membersSnapshot.isEmpty,
          let mlsCoordinator = await appState.getOrOpenMLSCoordinator() else {
      guard !Task.isCancelled else { return }
      errorMessage = appState.spacesEligibility.flatMap { $0.eligible ? nil : $0.userMessage }
        ?? String(
          localized: "Encrypted chat isn’t ready on this device yet. Try again in a moment.",
          comment: "Error when encrypted chat engine is not initialized yet"
        )
      showingError = true
      return
    }
    guard EncryptedGroupMembership.evaluate(selected: membersSnapshot, capabilities: groupCapabilities).canContinue
    else {
      errorMessage = String(
        localized: "Everyone in an encrypted group must be able to use encrypted chat.",
        comment: "Validation error when one or more selected members cannot join an encrypted group"
      )
      showingError = true
      return
    }

    guard !Task.isCancelled, AppStateManager.shared.lifecycle.userDID == accountDID else { return }
    isCreating = true
    defer { isCreating = false }
    step = .creating

    let conversationID = UUID().uuidString.lowercased()
    do {
      creationProgress = String(localized: "Setting up secure group…", comment: "Progress message while creating an encrypted group")
      let created = try await mlsCoordinator.createGroup(
        conversationId: conversationID,
        sequencerDid: appState.defaultMLSSequencerDID,
        memberDids: membersSnapshot,
        title: nameSnapshot.isEmpty ? nil : nameSnapshot,
        description: nil
      )
      guard !Task.isCancelled, AppStateManager.shared.lifecycle.userDID == accountDID else { return }
      pendingGroupCreation = nil

      if !noteSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let notes = MLSGroupInvitationNotes(
          accountDID: accountDID,
          conversationID: created.conversationId,
          recipients: membersSnapshot.sorted(),
          text: noteSnapshot
        )
        invitationNotes = notes
        MLSGroupInvitationNotesStore.save(notes)
        return
      }

      creationProgress = String(localized: "Finalizing…", comment: "Progress message while finalizing encrypted group creation")
      await appState.reloadMLSConversations()

      guard !Task.isCancelled, AppStateManager.shared.lifecycle.userDID == accountDID else { return }
      logger.info("Successfully created MLS conversation \(created.conversationId)")
      openEncryptedConversation(created.conversationId)
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), AppStateManager.shared.lifecycle.userDID == accountDID else { return }
      logger.error("Failed to create MLS conversation")
      if let pending = try? await mlsCoordinator.pendingGroupCreationStatus(conversationId: conversationID) {
        pendingGroupCreation = pending
      }
      errorMessage = ChatFailureMessage.text(for: error, context: .createEncryptedGroup)
      showingError = true
      step = selectedDIDs.count == 1 ? .selectContacts : .configureGroup
    }

    isCreating = false
  }

  @MainActor
  private func retryPendingMLSGroup(_ pending: PendingGroupCreationStatus) async {
    guard let mlsCoordinator = await appState.getOrOpenMLSCoordinator() else { return }
    isMutatingPendingGroup = true
    defer { isMutatingPendingGroup = false }
    do {
      if let created = try await mlsCoordinator.retryPendingGroupCreation(conversationId: pending.conversationId) {
        pendingGroupCreation = nil
        await appState.reloadMLSConversations()
        logger.info("Recovered pending MLS group creation \(created.conversationId)")
        dismiss()
      } else {
        pendingGroupCreation = try? await mlsCoordinator.pendingGroupCreationStatus(conversationId: pending.conversationId)
      }
    } catch {
      pendingGroupCreation = try? await mlsCoordinator.pendingGroupCreationStatus(conversationId: pending.conversationId)
      errorMessage = ChatFailureMessage.text(for: error, context: .retryEncryptedGroup)
      showingError = true
    }
  }

  @MainActor
  private func cancelPendingMLSGroup(_ pending: PendingGroupCreationStatus) async {
    guard let mlsCoordinator = await appState.getOrOpenMLSCoordinator() else { return }
    isMutatingPendingGroup = true
    defer { isMutatingPendingGroup = false }
    do {
      _ = try await mlsCoordinator.cancelPendingGroupCreation(conversationId: pending.conversationId)
      pendingGroupCreation = nil
    } catch {
      errorMessage = ChatFailureMessage.text(for: error, context: .cancelEncryptedGroup)
      showingError = true
    }
  }
}
