import OSLog
import Petrel
import SwiftUI

/// New conversation view with a segmented picker for Bluesky DM and Bluesky group modes.
struct NewConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  // MARK: - State

  @State private var mode: ConversationMode = .bluesky
  @State private var step: Step = .selectContacts
  @State private var selectedDIDs: Set<String> = []
  @State private var selectionOrder: [String] = []
  @State private var selectedProfiles: [String: ChatParticipant] = [:]
  @State private var groupName = ""
  @State private var isCreating = false
  @State private var creationProgress = ""
  @State private var creationTask: Task<Void, Never>?
  @State private var showingError = false
  @State private var errorMessage: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "NewConversation")

  enum ConversationMode: String, CaseIterable {
    case bluesky = "Bluesky DM"
    case blueskyGroup = "Bluesky Group"
  }

  enum Step {
    case selectContacts
    case configureGroup
    case creating
  }

  private var navigationTitle: String {
    switch (mode, step) {
    case (.bluesky, _): return "New Message"
    case (.blueskyGroup, .selectContacts): return "Add Participants"
    case (.blueskyGroup, .configureGroup): return "Group Details"
    case (.blueskyGroup, .creating): return "Creating Group"
    }
  }

  private var orderedSelectedParticipants: [ChatParticipant] {
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
            Button("Cancel") {
              creationTask?.cancel()
              dismiss()
            }
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
      .onDisappear { creationTask?.cancel() }
      .onChange(of: mode) { _, _ in
        creationTask?.cancel()
        step = .selectContacts
        selectedDIDs.removeAll()
        selectionOrder.removeAll()
        selectedProfiles.removeAll()
        groupName = ""
      }
      .onChange(of: appState.userDID) { _, _ in
        dismiss()
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
        selectedDIDs: .constant([]),
        selectionOrder: .constant([]),
        selectedProfiles: .constant([:]),
        onSingleSelect: startBlueskyConversation
      )

    case (.blueskyGroup, .selectContacts):
      ContactSearchList(
        selectionMode: .multi,
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
        onEditSelection: {
          withAnimation(.spring(response: 0.25)) {
            step = .selectContacts
          }
        }
      )

    case (.blueskyGroup, .creating):
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
        withAnimation(.spring(response: 0.25)) {
          step = .configureGroup
        }
      } label: {
        Text(selectedDIDs.isEmpty ? "Continue" : "Continue (\(selectedDIDs.count))")
          .fontWeight(.semibold)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(selectedDIDs.isEmpty)
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
            .fill(Color.accentColor.opacity(0.2))
            .frame(width: 80, height: 80)
          Image(systemName: "person.3.fill")
            .font(.system(size: 36))
            .foregroundColor(.accentColor)
            .symbolEffect(.pulse)
        }

        VStack(spacing: DesignTokens.Spacing.sm) {
          Text("Creating Group Chat")
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
    guard !selectedDIDs.isEmpty else {
      errorMessage = "Select at least one person"
      showingError = true
      return
    }

    let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      errorMessage = "Enter a group name"
      showingError = true
      return
    }

    isCreating = true
    step = .creating
    creationProgress = "Creating Bluesky group chat..."

    if let convoId = await appState.chatManager.startGroupConversation(
      memberDIDs: Array(selectedDIDs),
      name: trimmedName
    ) {
      logger.info("Successfully created Bluesky group conversation")
      isCreating = false
      dismiss()
      #if os(iOS)
      appState.navigationManager.navigate(to: .conversation(convoId), in: 4)
      #else
      appState.navigationManager.targetConversationId = convoId
      #endif
    } else {
      logger.error("Failed to create Bluesky group conversation")
      errorMessage = "Failed to create group chat. Please try again."
      showingError = true
      step = .configureGroup
      isCreating = false
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
          #if os(iOS)
          appState.navigationManager.navigate(to: .conversation(convoId), in: 4)
          #else
          appState.navigationManager.targetConversationId = convoId
          #endif
        }
      } else {
        await MainActor.run {
          errorMessage = "Failed to start conversation. Please try again."
          showingError = true
        }
      }
    }
  }
}
