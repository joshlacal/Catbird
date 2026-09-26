import CatbirdMLSCore
import SwiftUI

/// Classify using Rust's verified, account-scoped projection before starting
/// ordinary history, media, reactions, or send-readiness work.
struct MLSRequestConversationGate<Ordinary: View>: View {
  @Environment(AppState.self) private var appState
  let conversationID: String
  var onAccepted: ((String) -> Void)? = nil
  @ViewBuilder let ordinary: () -> Ordinary
  @State private var request: DirectRequestView?
  @State private var resolved = false
  @State private var error = false

  var body: some View {
    Group {
      if let request, request.consent != .accepted || !request.capabilities.canSend {
        MLSDirectRequestDetailView(request: request, onAccepted: onAccepted) { self.request = $0 }
      } else if resolved {
        ordinary()
      } else if error {
        ContentUnavailableView {
          Label("Unable to check this conversation", systemImage: "lock.fill")
        } actions: {
          Button("Retry") { Task { await refresh() } }
        }
      } else { ProgressView("Checking encrypted conversation…") }
    }
    .task(id: "\(appState.userDID):\(conversationID)") {
      resolved = false
      request = nil
      await refresh()
    }
  }

  @MainActor private func refresh() async {
    let account = appState.userDID
    let maxWaitTime: TimeInterval = 10.0
    let checkInterval: TimeInterval = 0.2
    var elapsed: TimeInterval = 0

    while !Task.isCancelled && elapsed < maxWaitTime {
      if CatbirdMLSCore.MLSClient.isSuspensionInProgress || CatbirdMLSCore.MLSCoreContext.isSuspensionInProgress {
        do { try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000)) } catch { return }
        elapsed += checkInterval
        continue
      }

      do {
        guard MLSConversationIdentityBoundary.isCanonicalStableID(conversationID),
              let manager = await appState.getMLSConversationManager(),
              manager.currentUserDID == account else { throw CancellationError() }
        let classification = try await manager.classifyDirectRequestConversation(conversationId: conversationID)
        let verified: DirectRequestView?
        switch classification {
        case .legacyV1:
          verified = nil
        case .verifiedRequest, .requestAwaitingProjection, .unknown:
          verified = try await manager.refreshRequestPreview(conversationId: conversationID)
        }
        guard !Task.isCancelled, appState.userDID == account, appState.mlsConversationManager === manager else { return }
        request = verified
        resolved = true
        error = false
        return
      } catch is CancellationError {
        return
      } catch let err {
        let desc = err.localizedDescription
        if desc.contains("suspension") || desc.contains("Database open blocked") || desc.contains("still in progress") || desc.contains("temporarily unavailable") || desc.contains("Connection is closed") || desc.contains("out of memory") {
          do { try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000)) } catch { return }
          elapsed += checkInterval
          continue
        }
        self.error = true
        return
      }
    }
    if !Task.isCancelled && !resolved {
      self.error = true
    }
  }
}

struct MLSDirectRequestDetailView: View {
  @Environment(AppState.self) private var appState
  let request: DirectRequestView
  var onAccepted: ((String) -> Void)? = nil
  let onChange: (DirectRequestView) -> Void
  @State private var busy = false
  @State private var error: String?
  @State private var blockSender: String?
  @State private var showBlock = false
  /// Bumped by every user action so an automatic refresh that started before
  /// it can never overwrite the action's newer result.
  @State private var actionGeneration = 0

  var body: some View {
    MLSRequestPresentation(
      consent: request.consent, preview: request.capabilities.canPreview ? request.preview : nil, busy: busy,
      canAccept: request.capabilities.canAccept, canClose: request.capabilities.canClose, error: error,
      onAccept: { Task { await act(.accept) } },
      onDecline: { Task { await act(.decline) } },
      onBlock: { Task { await act(.block) } },
      onRefresh: { Task { await act(.refresh) } },
      onOpenInvitation: { reference in
        guard reference.recipientDid == appState.userDID || reference.invitedByDid == appState.userDID else { return }
        appState.navigationManager.targetMLSConversationId = reference.conversationId
      }
    )
    .navigationTitle("Message Request")
    .accessibilityIdentifier("encrypted-request-detail")
    .confirmationDialog("Block this sender and close the request?", isPresented: $showBlock, titleVisibility: .visible) {
      Button("Block and Close", role: .destructive) { Task { await act(.confirmBlock) } }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("Your Bluesky block is published first. The request closes only after the server confirms it.")
    }
    .task(id: request.conversationId) {
      while !Task.isCancelled {
        await poll()
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
      }
    }
  }

  /// Automatic refresh. It never holds the action gate (a tap or a confirmed
  /// block during it must not be dropped) and never touches `error` (a failed
  /// action must stay visible); failures here are retried on the next tick.
  @MainActor private func poll() async {
    guard !busy else { return }
    let account = appState.userDID
    let generation = actionGeneration
    guard let manager = await appState.getMLSConversationManager(), manager.currentUserDID == account,
          let updated = try? await manager.refreshRequestPreview(conversationId: request.conversationId)
    else { return }
    func current() -> Bool {
      !Task.isCancelled && !busy && generation == actionGeneration
        && appState.userDID == account && appState.mlsConversationManager === manager
    }
    guard current(),
          (try? await MLSRequestNotificationPreviewCache.project(updated, accountDID: account, database: manager.database)) != nil,
          current() else { return }
    onChange(updated)
  }

  private enum Action { case accept, decline, block, confirmBlock, refresh }

  @MainActor private func act(_ action: Action) async {
    guard !busy else { return }
    let account = appState.userDID
    busy = true
    actionGeneration += 1
    defer { busy = false }
    do {
      guard let manager = await appState.getMLSConversationManager(), manager.currentUserDID == account,
            appState.userDID == account else { throw CancellationError() }
      switch action {
      case .accept:
        guard request.consent == .incomingPending && request.capabilities.canAccept else { return }
        try await manager.acceptConversationRequest(convoId: request.conversationId)
        if let onAccepted {
          await MainActor.run {
            onAccepted(request.conversationId)
          }
        }
      case .decline:
        guard request.capabilities.canClose else { return }
        try await manager.declineConversationRequest(convoId: request.conversationId)
      case .block:
        guard request.consent == .incomingPending,
              let sender = request.introduction?.senderDid, sender != account else {
          error = "The verified sender identity is unavailable. Refresh this request and try again."
          return
        }
        blockSender = sender
        showBlock = true
        return
      case .confirmBlock:
        guard let sender = blockSender, sender == request.introduction?.senderDid,
              request.consent == .incomingPending else { return }
        if !(await appState.graphManager.isBlocking(did: sender)) {
          guard try await appState.graphManager.block(did: sender) else {
            error = "The sender could not be blocked. Please try again."
            return
          }
        }
        guard appState.userDID == account, appState.mlsConversationManager === manager else { return }
        _ = try await manager.closeDirectRequest(conversationId: request.conversationId)
      case .refresh: break
      }
      let updated = try await manager.refreshRequestPreview(conversationId: request.conversationId)
      guard !Task.isCancelled, appState.userDID == account, appState.mlsConversationManager === manager else { return }
      try await MLSRequestNotificationPreviewCache.project(updated, accountDID: account, database: manager.database)
      guard appState.userDID == account, appState.mlsConversationManager === manager else { return }
      onChange(updated)
      error = nil
    } catch is CancellationError { } catch {
      guard appState.userDID == account else { return }
      self.error = "Could not update this request. Your saved introduction is still available."
    }
  }
}

#if os(iOS)
struct MLSConversationDetailView: View {
  let conversationId: String
  var body: some View {
    MLSRequestConversationGate(conversationID: conversationId) {
      MLSOrdinaryConversationDetailView(conversationId: conversationId)
    }
  }
}
#endif
