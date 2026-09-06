import OSLog
import Petrel
import SwiftUI
import CatbirdMLSCore

struct MLSChatRequestsButton: View {
  let pendingCount: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Image(systemName: "tray")
          .appBody()

        if pendingCount > 0 {
          Text("\(pendingCount)")
            .appCaption()
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red)
            .clipShape(Capsule())
            .offset(x: 12, y: -8)
        }
      }
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    if pendingCount == 0 {
      return "Chat requests"
    }
    return "Chat requests, \(pendingCount) pending"
  }
}

struct MLSChatRequestsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let onAcceptedConversation: (@Sendable (String) async -> Void)?

  @State private var requests: [MLSConversationModel] = []
  @State private var senderProfiles: [String: MLSProfileEnricher.ProfileData] = [:]
  @State private var groupConversationIDs: Set<String> = []
  @State private var membersByConvo: [String: [String]] = [:]  // convoId -> member DIDs
  @State private var isLoading = false
  @State private var processingConvoIDs: Set<String> = []
  @State private var errorMessage: String?
  @State private var showingErrorAlert = false
  @State private var loadGeneration = UUID()

  // Block sheet state
  @State private var requestToBlock: MLSConversationModel?
  @State private var showingBlockSheet = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSChatRequests")

  var body: some View {
    NavigationStack {
      Group {
        if isLoading && requests.isEmpty {
          ProgressView("Loading requests…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if requests.isEmpty {
          ContentUnavailableView {
            Label("No Chat Requests", systemImage: "tray")
          } description: {
            Text("You're all caught up.")
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List {
            ForEach(requests, id: \.conversationID) { request in
              let members = membersByConvo[request.conversationID] ?? []
              let senderDID = members.first(where: { $0 != appState.userDID }) ?? ""
              
              MLSChatRequestRow(
                request: request,
                senderDID: senderDID,
                senderProfile: senderProfiles[senderDID],
                isGroup: groupConversationIDs.contains(request.conversationID),
                memberPreview: members.filter { $0 != appState.userDID }.map { did in
                  senderProfiles[did].map { $0.displayName ?? "@\($0.handle)" } ?? String(did.prefix(20))
                }.joined(separator: ", "),
                isProcessing: processingConvoIDs.contains(request.conversationID),
                onAccept: {
                  Task { await accept(request) }
                },
                onDecline: {
                  Task { await decline(request) }
                },
                onBlock: {
                  guard !groupConversationIDs.contains(request.conversationID) else { return }
                  requestToBlock = request
                  showingBlockSheet = true
                }
              )
              .listRowSeparator(.visible)
              .accessibilityIdentifier("mls.request.\(request.conversationID)")
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Chat Requests")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await loadRequests() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Refresh")
          .disabled(isLoading)
        }
      }
      .refreshable {
        await loadRequests()
      }
      .task(id: appState.userDID) {
        loadGeneration = UUID()
        requests = []
        membersByConvo = [:]
        groupConversationIDs = []
        senderProfiles = [:]
        processingConvoIDs = []
        isLoading = false
        await loadRequests()
      }
      .onDisappear { loadGeneration = UUID() }
      .alert("Chat Requests", isPresented: $showingErrorAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "An unknown error occurred.")
      }
      .sheet(isPresented: $showingBlockSheet) {
        if let request = requestToBlock {
          let members = membersByConvo[request.conversationID] ?? []
          let senderDID = members.first(where: { $0 != appState.userDID }) ?? ""
          let profile = senderProfiles[senderDID]
          BlockChatSenderSheet(
            senderDid: senderDID,
            senderHandle: profile?.handle,
            senderDisplayName: profile?.displayName,
            requestId: request.conversationID,
            onBlocked: {
              Task { await loadRequests() }
            }
          )
        }
      }
    }
  }

  @MainActor
  private func loadRequests() async {
    guard !isLoading else { return }
    let userDID = appState.userDID
    let generation = loadGeneration
    isLoading = true
    defer { if loadGeneration == generation { isLoading = false } }

    do {
      let candidate = await appState.getMLSConversationManager()
      guard !Task.isCancelled, appState.userDID == userDID, loadGeneration == generation else {
        throw CancellationError()
      }
      guard let manager = candidate else { throw MLSAPIError.serverUnavailable }
      guard isCurrent(manager, userDID: userDID, generation: generation) else { throw CancellationError() }
      let loaded = try await manager.fetchPendingRequestConversations()
        .filter { $0.currentUserDID == userDID }
        .sorted { $0.createdAt > $1.createdAt }
      var members: [String: [String]] = [:]
      for request in loaded {
        guard isCurrent(manager, userDID: userDID, generation: generation) else { throw CancellationError() }
        members[request.conversationID] = try await manager.fetchConversationMembers(convoId: request.conversationID).map(\.did)
      }
      let senders = Array(Set(members.values.flatMap { $0 }.filter { $0 != userDID }))
      let profiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: senders, using: appState.client, currentUserDID: userDID)
      guard isCurrent(manager, userDID: userDID, generation: generation) else { throw CancellationError() }
      requests = loaded
      groupConversationIDs = Set(loaded.filter {
        manager.conversations[$0.conversationID]?.conversationKind == .value_group
      }.map(\.conversationID))
      membersByConvo = members
      senderProfiles = profiles
    } catch is CancellationError {
    } catch {
      guard appState.userDID == userDID, loadGeneration == generation else { return }
      errorMessage = "Could not load Catbird chat requests. Please try again."
      showingErrorAlert = true
    }
  }

  @MainActor
  private func isCurrent(_ manager: MLSConversationManager, userDID: String, generation: UUID) -> Bool {
    !Task.isCancelled && appState.userDID == userDID && loadGeneration == generation
      && manager.currentUserDID == userDID && !manager.isShuttingDown
      && appState.mlsConversationManager === manager
  }

  @MainActor
  private func accept(_ request: MLSConversationModel) async {
    let userDID = appState.userDID
    let generation = loadGeneration
    guard request.currentUserDID == userDID,
          processingConvoIDs.insert(request.conversationID).inserted else { return }
    defer { if loadGeneration == generation { processingConvoIDs.remove(request.conversationID) } }

    do {
      let candidate = await appState.getMLSConversationManager()
      guard !Task.isCancelled, appState.userDID == userDID, loadGeneration == generation else { throw CancellationError() }
      guard let manager = candidate else { throw MLSAPIError.serverUnavailable }
      guard isCurrent(manager, userDID: userDID, generation: generation) else { throw CancellationError() }
      let pending = try await manager.fetchPendingRequestConversations()
      guard pending.contains(where: { $0.conversationID == request.conversationID && $0.currentUserDID == userDID }) else {
        await loadRequests()
        return
      }
      try await MLSChatRequestAcceptance.perform(
        conversationID: request.conversationID,
        isCurrent: { isCurrent(manager, userDID: userDID, generation: generation) },
        accept: { try await manager.acceptConversationRequest(convoId: $0) },
        didAccept: { conversationID in
          if let onAcceptedConversation { await onAcceptedConversation(conversationID) }
          dismiss()
        })
    } catch is CancellationError {
    } catch {
      guard appState.userDID == userDID, loadGeneration == generation else { return }
      errorMessage = "Could not accept this chat request. It has been kept so you can try again."
      showingErrorAlert = true
    }
  }

  @MainActor
  private func decline(_ request: MLSConversationModel) async {
    let userDID = appState.userDID
    let generation = loadGeneration
    guard request.currentUserDID == userDID,
          processingConvoIDs.insert(request.conversationID).inserted else { return }
    defer { if loadGeneration == generation { processingConvoIDs.remove(request.conversationID) } }
    do {
      let candidate = await appState.getMLSConversationManager()
      guard !Task.isCancelled, appState.userDID == userDID, loadGeneration == generation else { throw CancellationError() }
      guard let manager = candidate else { throw MLSAPIError.serverUnavailable }
      guard isCurrent(manager, userDID: userDID, generation: generation) else { throw CancellationError() }
      let pending = try await manager.fetchPendingRequestConversations()
      guard pending.contains(where: { $0.conversationID == request.conversationID && $0.currentUserDID == userDID }),
            isCurrent(manager, userDID: userDID, generation: generation) else { throw CancellationError() }
      try await manager.declineConversationRequest(convoId: request.conversationID)
      guard isCurrent(manager, userDID: userDID, generation: generation) else { throw CancellationError() }
      await loadRequests()
    } catch is CancellationError {
    } catch {
      guard appState.userDID == userDID, loadGeneration == generation else { return }
      errorMessage = "Could not decline this chat request. Please try again."
      showingErrorAlert = true
    }
  }

}

private struct MLSChatRequestRow: View {
  let request: MLSConversationModel
  let senderDID: String
  let senderProfile: MLSProfileEnricher.ProfileData?
  let isGroup: Bool
  let memberPreview: String
  let isProcessing: Bool
  let onAccept: () -> Void
  let onDecline: () -> Void
  let onBlock: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        if isGroup {
          Image(systemName: "person.2.fill")
            .frame(width: 44, height: 44)
            .background(.quaternary, in: Circle())
        } else {
          AsyncProfileImage(url: senderProfile?.avatarURL, size: 44)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(displayName)
            .designCallout()
            .foregroundColor(.primary)
            .lineLimit(1)

          Text(handleText)
            .designFootnote()
            .foregroundColor(.secondary)
            .lineLimit(1)

          if !isGroup, let title = request.title, !title.isEmpty {
            Text(title)
              .designFootnote()
              .foregroundColor(.secondary)
              .lineLimit(3)
          }

          HStack(spacing: 8) {
            Spacer()

            Text(request.createdAt.formatted(date: .abbreviated, time: .shortened))
              .designCaption()
              .foregroundColor(.secondary)
          }
          .designCaption()
          .foregroundColor(.secondary)
        }

        Spacer()
      }

      HStack(spacing: 12) {
        Button(role: .destructive, action: onDecline) {
          if isProcessing {
            ProgressView()
              .tint(.secondary)
          } else {
            Text("Decline")
          }
        }
        .buttonStyle(.bordered)
        .disabled(isProcessing)

        if !isGroup {
          Button(role: .destructive, action: onBlock) {
            Text("Block")
          }
          .buttonStyle(.bordered)
          .tint(.red)
          .disabled(isProcessing)
        }

        Spacer()

        Button(action: onAccept) {
          if isProcessing {
            ProgressView()
              .tint(.white)
          } else {
            Text("Accept")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isProcessing)
      }
    }
    .padding(.vertical, 8)
  }

  private var displayName: String {
    if isGroup { return MLSChatRequestPresentation.groupTitle(request.title) }
    if let profile = senderProfile {
      return profile.displayName ?? "@\(profile.handle)"
    }
    return shortDID(senderDID)
  }

  private var handleText: String {
    if isGroup { return memberPreview.isEmpty ? "Encrypted group conversation" : "With \(memberPreview)" }
    if let profile = senderProfile {
      return "@\(profile.handle)"
    }
    return shortDID(senderDID)
  }

  private func shortDID(_ did: String) -> String {
    guard did.count > 18 else { return did }
    return "\(did.prefix(12))…\(did.suffix(6))"
  }
}


#Preview("MLSChatRequestsView") {
  NavigationStack {
    MLSChatRequestsView(onAcceptedConversation: nil)
  }
  .previewWithAuthenticatedState()
}


@MainActor
enum MLSChatRequestAcceptance {
  static func perform(
    conversationID: String,
    isCurrent: () -> Bool,
    accept: (String) async throws -> Void,
    didAccept: (String) async -> Void
  ) async throws {
    guard isCurrent() else { throw CancellationError() }
    try await accept(conversationID)
    guard isCurrent() else { throw CancellationError() }
    await didAccept(conversationID)
  }
}


enum MLSChatRequestPresentation {
  static func groupTitle(_ title: String?) -> String {
    let knownTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return knownTitle.isEmpty ? "Group chat invitation" : knownTitle
  }
}
