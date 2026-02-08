import OSLog
import Petrel
import SwiftUI
import CatbirdMLSService
import CatbirdMLSCore

#if os(iOS)

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
  @State private var membersByConvo: [String: [String]] = [:]  // convoId -> member DIDs
  @State private var isLoading = false
  @State private var processingConvoIDs: Set<String> = []
  @State private var errorMessage: String?
  @State private var showingErrorAlert = false

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
                isProcessing: processingConvoIDs.contains(request.conversationID),
                onAccept: {
                  Task { await accept(request) }
                },
                onDecline: {
                  Task { await decline(request) }
                },
                onBlock: {
                  requestToBlock = request
                  showingBlockSheet = true
                }
              )
              .listRowSeparator(.visible)
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
      .task {
        await loadRequests()
      }
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

    isLoading = true
    defer { isLoading = false }

    do {
      guard let manager = await appState.getMLSConversationManager() else {
        throw MLSAPIError.serverUnavailable
      }

      // Fetch pending request conversations from local storage
      requests = try await manager.fetchPendingRequestConversations()
        .sorted { $0.createdAt > $1.createdAt }

      // Load members for each conversation to get sender DIDs
      for request in requests {
        if let convoMembers = try? await manager.fetchConversationMembers(convoId: request.conversationID) {
          membersByConvo[request.conversationID] = convoMembers.map(\.did)
        }
      }

      // Get all unique sender DIDs (non-current user members)
      let senderDIDs = Array(Set(membersByConvo.values.flatMap { $0 }.filter { $0 != appState.userDID }))
      senderProfiles = await appState.mlsProfileEnricher.ensureProfiles(
        for: senderDIDs,
        using: appState.client,
        currentUserDID: appState.userDID
      )

    } catch {
      logger.error("Failed to load chat requests: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }

  @MainActor
  private func accept(_ request: MLSConversationModel) async {
    guard processingConvoIDs.insert(request.conversationID).inserted else { return }
    defer { processingConvoIDs.remove(request.conversationID) }

    do {
      guard let manager = await appState.getMLSConversationManager() else {
        throw MLSAPIError.serverUnavailable
      }

      // Accept is local-only - just update the requestState
      try await manager.acceptConversationRequest(convoId: request.conversationID)

      if let onAcceptedConversation {
        await onAcceptedConversation(request.conversationID)
      }

      dismiss()
    } catch {
      logger.error("Failed to accept chat request: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }

  @MainActor
  private func decline(_ request: MLSConversationModel) async {
    guard processingConvoIDs.insert(request.conversationID).inserted else { return }
    defer { processingConvoIDs.remove(request.conversationID) }

    do {
      guard let manager = await appState.getMLSConversationManager() else {
        throw MLSAPIError.serverUnavailable
      }

      // Decline leaves the MLS group on server and deletes local data
      try await manager.declineConversationRequest(convoId: request.conversationID)
      await loadRequests()
    } catch {
      logger.error("Failed to decline chat request: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }
}

private struct MLSChatRequestRow: View {
  let request: MLSConversationModel
  let senderDID: String
  let senderProfile: MLSProfileEnricher.ProfileData?
  let isProcessing: Bool
  let onAccept: () -> Void
  let onDecline: () -> Void
  let onBlock: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        AsyncProfileImage(url: senderProfile?.avatarURL, size: 44)

        VStack(alignment: .leading, spacing: 4) {
          Text(displayName)
            .designCallout()
            .foregroundColor(.primary)
            .lineLimit(1)

          Text(handleText)
            .designFootnote()
            .foregroundColor(.secondary)
            .lineLimit(1)

          if let title = request.title, !title.isEmpty {
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

        Button(role: .destructive, action: onBlock) {
          Text("Block")
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(isProcessing)

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
    if let profile = senderProfile {
      return profile.displayName ?? "@\(profile.handle)"
    }
    return shortDID(senderDID)
  }

  private var handleText: String {
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

#endif

