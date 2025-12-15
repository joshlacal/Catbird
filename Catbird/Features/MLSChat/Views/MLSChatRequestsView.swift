import OSLog
import Petrel
import SwiftUI

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

  @State private var requests: [BlueCatbirdMlsListChatRequests.ChatRequest] = []
  @State private var senderProfiles: [String: MLSProfileEnricher.ProfileData] = [:]
  @State private var isLoading = false
  @State private var processingRequestIDs: Set<String> = []
  @State private var errorMessage: String?
  @State private var showingErrorAlert = false

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
            ForEach(requests, id: \.id) { request in
              MLSChatRequestRow(
                request: request,
                senderProfile: senderProfiles[request.senderDid],
                isProcessing: processingRequestIDs.contains(request.id),
                onAccept: {
                  Task { await accept(request) }
                },
                onDecline: {
                  Task { await decline(request) }
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
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await loadRequests(refresh: true) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Refresh")
          .disabled(isLoading)
        }
      }
      .refreshable {
        await loadRequests(refresh: true)
      }
      .task {
        await loadRequests(refresh: true)
      }
      .alert("Chat Requests", isPresented: $showingErrorAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "An unknown error occurred.")
      }
    }
  }

  @MainActor
  private func loadRequests(refresh: Bool) async {
    guard !isLoading else { return }

    isLoading = true
    defer { isLoading = false }

    do {
      guard let apiClient = await appState.getMLSAPIClient() else {
        throw MLSAPIError.serverUnavailable
      }

      let response = try await apiClient.listChatRequests(limit: 50, cursor: nil, status: "pending")
      requests = response.requests.sorted { $0.createdAt.date > $1.createdAt.date }

      let senderDIDs = Array(Set(requests.map(\.senderDid)))
      senderProfiles = await appState.mlsProfileEnricher.ensureProfiles(for: senderDIDs, using: appState.client)

    } catch {
      logger.error("Failed to load chat requests: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }

  @MainActor
  private func accept(_ request: BlueCatbirdMlsListChatRequests.ChatRequest) async {
    guard processingRequestIDs.insert(request.id).inserted else { return }
    defer { processingRequestIDs.remove(request.id) }

    do {
      guard let apiClient = await appState.getMLSAPIClient() else {
        throw MLSAPIError.serverUnavailable
      }

      let result = try await apiClient.acceptChatRequest(requestId: request.id)

      if let onAcceptedConversation {
        await onAcceptedConversation(result.convoId)
      } else if let manager = await appState.getMLSConversationManager() {
        try? await manager.syncWithServer()
      }

      dismiss()
    } catch {
      logger.error("Failed to accept chat request: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }

  @MainActor
  private func decline(_ request: BlueCatbirdMlsListChatRequests.ChatRequest) async {
    guard processingRequestIDs.insert(request.id).inserted else { return }
    defer { processingRequestIDs.remove(request.id) }

    do {
      guard let apiClient = await appState.getMLSAPIClient() else {
        throw MLSAPIError.serverUnavailable
      }

      _ = try await apiClient.declineChatRequest(requestId: request.id)
      await loadRequests(refresh: true)
    } catch {
      logger.error("Failed to decline chat request: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }
}

private struct MLSChatRequestRow: View {
  let request: BlueCatbirdMlsListChatRequests.ChatRequest
  let senderProfile: MLSProfileEnricher.ProfileData?
  let isProcessing: Bool
  let onAccept: () -> Void
  let onDecline: () -> Void

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

          if let preview = request.previewText, !preview.isEmpty {
            Text(preview)
              .designFootnote()
              .foregroundColor(.secondary)
              .lineLimit(3)
          }

          HStack(spacing: 8) {
            if let messageCount = request.messageCount, messageCount > 0 {
              Label("\(messageCount)", systemImage: "envelope")
                .labelStyle(.titleAndIcon)
            }

            if request.isGroupInvite == true {
              Label("Group invite", systemImage: "person.3")
                .labelStyle(.titleAndIcon)
            }

            Spacer()

            Text(request.createdAt.date.formatted(date: .abbreviated, time: .shortened))
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

        Button(action: onAccept) {
          if isProcessing {
            ProgressView()
              .tint(.white)
          } else {
            Text(acceptTitle)
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
    return shortDID(request.senderDid)
  }

  private var handleText: String {
    if let profile = senderProfile {
      return "@\(profile.handle)"
    }
    return shortDID(request.senderDid)
  }

  private var acceptTitle: String {
    request.isGroupInvite == true ? "Join" : "Accept"
  }

  private func shortDID(_ did: String) -> String {
    guard did.count > 18 else { return did }
    return "\(did.prefix(12))…\(did.suffix(6))"
  }
}

#endif

