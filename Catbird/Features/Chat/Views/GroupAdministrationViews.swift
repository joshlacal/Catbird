import OSLog
import SwiftUI
import Petrel

// MARK: - Add Members

/// Owner-only sheet for adding members to a Bluesky group conversation,
/// reusing the shared contact picker from the new-conversation flow.
struct AddGroupMembersSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let convoId: String
  let existingMemberDIDs: Set<String>

  @State private var selectedDIDs: Set<String> = []
  @State private var selectionOrder: [String] = []
  @State private var selectedProfiles: [String: MLSParticipantViewModel] = [:]
  @State private var isAdding = false
  @State private var errorMessage: String?

  /// Selections that aren't already in the group; the picker has no exclusion
  /// support, so already-added picks are silently dropped at submit time.
  private var newMemberDIDs: [String] {
    selectionOrder.filter { !existingMemberDIDs.contains($0) }
  }

  var body: some View {
    NavigationStack {
      ContactSearchList(
        selectionMode: .multi,
        showMLSStatus: false,
        selectedDIDs: $selectedDIDs,
        selectionOrder: $selectionOrder,
        selectedProfiles: $selectedProfiles
      )
      .navigationTitle("Add Members")
    #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isAdding)
        }

        ToolbarItem(placement: .confirmationAction) {
          if isAdding {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Button("Add") {
              addSelectedMembers()
            }
            .fontWeight(.semibold)
            .disabled(newMemberDIDs.isEmpty)
          }
        }
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

  private func addSelectedMembers() {
    let members = newMemberDIDs
    Task {
      isAdding = true
      defer { isAdding = false }
      do {
        try await appState.chatManager.addGroupMembers(convoId: convoId, memberDIDs: members)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

// MARK: - Join Requests

/// Owner-only list of pending join requests with approve/reject actions.
struct GroupJoinRequestsView: View {
  @Environment(AppState.self) private var appState

  let convoId: String

  @State private var requests: [ChatBskyGroupDefs.JoinRequestView] = []
  @State private var isLoading = true
  @State private var processingDIDs: Set<String> = []
  @State private var errorMessage: String?

  var body: some View {
    List {
      if isLoading {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .listRowBackground(Color.clear)
      } else if requests.isEmpty {
        ContentUnavailableView(
          "No Join Requests",
          systemImage: "person.crop.circle.badge.questionmark",
          description: Text("When someone asks to join through the invite link, their request will show up here.")
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      } else {
        ForEach(requests, id: \.requestedBy.did) { request in
          JoinRequestRow(
            request: request,
            isProcessing: processingDIDs.contains(request.requestedBy.did.didString()),
            onApprove: { resolve(request, approve: true) },
            onReject: { resolve(request, approve: false) }
          )
        }
      }
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: requests.map { $0.requestedBy.did })
    .navigationTitle("Join Requests")
  #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
  #endif
    .task {
      await loadRequests()
      await appState.chatManager.markJoinRequestsRead(convoId: convoId)
    }
    .refreshable {
      await loadRequests()
    }
    .alert("Error", isPresented: errorAlertBinding) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }

  private var errorAlertBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func loadRequests() async {
    do {
      requests = try await appState.chatManager.listJoinRequests(convoId: convoId)
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  private func resolve(_ request: ChatBskyGroupDefs.JoinRequestView, approve: Bool) {
    let memberDID = request.requestedBy.did.didString()
    Task {
      processingDIDs.insert(memberDID)
      defer { processingDIDs.remove(memberDID) }
      do {
        if approve {
          try await appState.chatManager.approveJoinRequest(convoId: convoId, memberDID: memberDID)
        } else {
          try await appState.chatManager.rejectJoinRequest(convoId: convoId, memberDID: memberDID)
        }
        requests.removeAll { $0.requestedBy.did.didString() == memberDID }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

private struct JoinRequestRow: View {
  let request: ChatBskyGroupDefs.JoinRequestView
  let isProcessing: Bool
  let onApprove: () -> Void
  let onReject: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      ChatProfileAvatarView(profile: request.requestedBy, size: 40)

      VStack(alignment: .leading, spacing: 2) {
        Text(request.requestedBy.chatDisplayName)
          .appFont(AppTextRole.body)
          .fontWeight(.medium)
          .lineLimit(1)

        Text("@\(request.requestedBy.handle.description) · \(request.requestedAt.date.formatted(.relative(presentation: .named)))")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if isProcessing {
        ProgressView()
          .scaleEffect(0.8)
      } else {
        Button("Reject", role: .destructive) {
          onReject()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)

        Button("Approve") {
          onApprove()
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
      }
    }
    .buttonStyle(.borderless)
  }
}
