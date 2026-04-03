import CatbirdMLSCore
import GRDB
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

/// Unified new conversation view with segmented picker for Bluesky DM and Catbird Group modes.
struct NewConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // MARK: - State

  @State private var mode: ConversationMode = .bluesky
  @State private var step: Step = .selectContacts
  @State private var selectedDIDs: Set<String> = []
  @State private var selectionOrder: [String] = []
  @State private var selectedProfiles: [String: MLSParticipantViewModel] = [:]
  @State private var groupName = ""
  @State private var isCreating = false
  @State private var creationProgress = ""
  @State private var showingError = false
  @State private var errorMessage: String?
  @State private var isCheckingExisting = false

  private let logger = Logger(subsystem: "blue.catbird", category: "NewConversation")

  enum ConversationMode: String, CaseIterable {
    case bluesky = "Bluesky DM"
    case catbirdGroup = "Catbird Group"
  }

  enum Step {
    case selectContacts
    case configureGroup
    case creating
  }

  private var mlsEnabled: Bool {
    ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
  }

  private var navigationTitle: String {
    switch (mode, step) {
    case (.bluesky, _): return "New Message"
    case (.catbirdGroup, .selectContacts): return mlsEnabled ? "Add Participants" : "Catbird Groups"
    case (.catbirdGroup, .configureGroup): return "Group Details"
    case (.catbirdGroup, .creating): return "Creating Group"
    }
  }

  private var orderedSelectedParticipants: [MLSParticipantViewModel] {
    selectionOrder.compactMap { selectedProfiles[$0] }
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      ZStack {
        VStack(spacing: 0) {
          segmentedPicker
          mainContent
        }

        if isCreating {
          creationOverlay
        }
      }
      .navigationTitle(navigationTitle)
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if step == .configureGroup {
            Button("Back") {
              withAnimation(.spring(response: 0.25)) {
                step = .selectContacts
              }
            }
          } else {
            Button("Cancel") { dismiss() }
              .disabled(isCreating)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          confirmationButton
        }
      }
      .alert("Error", isPresented: $showingError) {
        Button("OK", role: .cancel) {}
      } message: {
        if let errorMessage {
          Text(errorMessage)
        }
      }
      .onChange(of: mode) { _, _ in
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
      ForEach(ConversationMode.allCases, id: \.self) { m in
        Text(m.rawValue).tag(m)
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
      ContactSearchList(
        selectionMode: .single,
        showMLSStatus: false,
        selectedDIDs: .constant([]),
        selectionOrder: .constant([]),
        selectedProfiles: .constant([:]),
        onSingleSelect: startBlueskyConversation
      )

    case (.catbirdGroup, .selectContacts) where mlsEnabled:
      ContactSearchList(
        selectionMode: .multi,
        showMLSStatus: true,
        selectedDIDs: $selectedDIDs,
        selectionOrder: $selectionOrder,
        selectedProfiles: $selectedProfiles
      )
      .safeAreaInset(edge: .bottom) {
        selectionActionBar
      }

    case (.catbirdGroup, .selectContacts):
      MLSOptInGateView()

    case (.catbirdGroup, .configureGroup):
      GroupConfigView(
        groupName: $groupName,
        participants: orderedSelectedParticipants,
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

  @ViewBuilder
  private var selectionActionBar: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      HStack {
        if !selectedDIDs.isEmpty {
          Label("\(selectedDIDs.count) selected", systemImage: "person.3")
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
        if selectedDIDs.count == 1 {
          Task { await handleDirectMLSMessage() }
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
          Text(selectedDIDs.isEmpty ? "Continue" : "Continue (\(selectedDIDs.count))")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(selectedDIDs.isEmpty || isCheckingExisting)
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
    case (.catbirdGroup, .selectContacts) where mlsEnabled:
      Button("Next") {
        if selectedDIDs.count == 1 {
          Task { await handleDirectMLSMessage() }
        } else {
          withAnimation(.spring(response: 0.25)) {
            step = .configureGroup
          }
        }
      }
      .disabled(selectedDIDs.isEmpty || isCheckingExisting)
      .fontWeight(.semibold)
    case (.catbirdGroup, .configureGroup):
      Button("Create") {
        Task { await createMLSGroup() }
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
    ZStack {
      Color.black.opacity(0.4)
        .ignoresSafeArea()

      VStack(spacing: DesignTokens.Spacing.lg) {
        ZStack {
          Circle()
            .fill(Color.green.opacity(0.2))
            .frame(width: 80, height: 80)
          Image(systemName: "lock.shield.fill")
            .font(.system(size: 36))
            .foregroundColor(.green)
            .symbolEffect(.pulse)
        }

        VStack(spacing: DesignTokens.Spacing.sm) {
          Text("Creating Secure Group")
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

  // MARK: - Bluesky DM Creation

  private func startBlueskyConversation(_ profile: any ProfileDisplayable) {
    Task {
      logger.debug("Starting Bluesky conversation with: \(profile.handle.description)")
      if let convoId = await appState.chatManager.startConversationWith(
        userDID: profile.did.didString()
      ) {
        await MainActor.run {
          dismiss()
          appState.navigationManager.navigate(to: .conversation(convoId), in: 4)
        }
      } else {
        await MainActor.run {
          errorMessage = "Failed to start conversation. Please try again."
          showingError = true
        }
      }
    }
  }

  // MARK: - MLS Direct Message (1:1)

  @MainActor
  private func handleDirectMLSMessage() async {
    guard selectedDIDs.count == 1,
          let participantDid = selectedDIDs.first else { return }

    isCheckingExisting = true
    defer { isCheckingExisting = false }

    if let conversationManager = await appState.getMLSConversationManager() {
      do {
        let did = try DID(didString: participantDid)
        if let existingConvoId = try await conversationManager.findDirectConversation(with: did) {
          dismiss()
          appState.navigationManager.targetMLSConversationId = existingConvoId
          return
        }
      } catch {
        logger.warning("Failed to check existing 1:1: \(error.localizedDescription)")
      }
    }

    withAnimation(.spring(response: 0.25)) {
      step = .creating
    }
    await createMLSGroup()
  }

  // MARK: - MLS Group Creation

  @MainActor
  private func createMLSGroup() async {
    guard !selectedDIDs.isEmpty,
          let database = appState.mlsDatabase,
          let conversationManager = await appState.getMLSConversationManager() else {
      errorMessage = "MLS service not available"
      showingError = true
      return
    }

    isCreating = true
    step = .creating

    do {
      creationProgress = "Fetching encryption keys..."

      let viewModel = MLSNewConversationViewModel(
        database: database,
        conversationManager: conversationManager
      )

      if !groupName.isEmpty {
        viewModel.conversationName = groupName
      }

      viewModel.selectedMembers = Array(selectedDIDs)

      creationProgress = "Setting up secure group..."
      await viewModel.createConversation()

      if let error = viewModel.error {
        throw error
      }

      creationProgress = "Finalizing..."
      await appState.reloadMLSConversations()

      logger.info("Successfully created MLS conversation")
      dismiss()
    } catch {
      logger.error("Failed to create MLS conversation: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
      step = selectedDIDs.count == 1 ? .selectContacts : .configureGroup
    }

    isCreating = false
  }
}

// MARK: - macOS Stub

#else

struct NewConversationView: View {
  var body: some View {
    VStack {
      Text("New Message")
        .font(.title2)
        .fontWeight(.semibold)
      Text("Chat features require iOS")
        .foregroundColor(.secondary)
    }
    .padding()
  }
}

#endif
