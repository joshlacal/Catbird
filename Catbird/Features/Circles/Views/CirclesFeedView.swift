//
//  CirclesFeedView.swift
//  Catbird
//

import Petrel
import PetrelCatbird
import SwiftUI

/// View displaying the unified feed of all Circles the user belongs to.
struct CirclesFeedView: View {
  @Environment(AppState.self) private var appState
  @Environment(AppStateManager.self) private var appStateManager
  @Binding var path: NavigationPath
  @State private var model: CircleFeedModel?
  @State private var errorMessage: String?
  @State private var showingCreateCircleSheet = false
  @State private var authGeneration: Int = 0
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  private var authCoordinator: CircleAppViewAuthCoordinator { .shared }

  init(path: Binding<NavigationPath>) {
    self._path = path
  }

  var body: some View {
    Group {
      if let model, model.accountDID == appState.userDID && !model.isInvalidated {
        switch model.accessState {
        case .active:
          feedListView(model: model)
        case .expired:
          accessExpiredView(model: model)
        case .removed:
          accessRemovedView(model: model)
        case .unsupported:
          unsupportedView
        case .needsAuthorization:
          needsAuthorizationView(model: model)
        }
      } else {
        ProgressView("Loading Circles...")
      }
    }
    .navigationTitle("Circles")
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
#endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingCreateCircleSheet = true
        } label: {
          Image(systemName: "plus")
        }
        .accessibilityLabel("Create Circle")
        .accessibilityHint("Opens sheet to create a new named Circle")
      }
    }
    .sheet(isPresented: $showingCreateCircleSheet) {
      CreateCircleView()
    }
    .task(id: appState.userDID) {
      let currentDID = appState.userDID
      guard !currentDID.isEmpty else { return }

      if model?.accountDID != currentDID || model?.isInvalidated == true {
        model = nil
        errorMessage = nil
      }

      guard model == nil else { return }

      let newModel = CircleFeedModel(
        service: appState.circleService,
        accountDID: currentDID,
        activeDIDProvider: { AppStateManager.shared.lifecycle.userDID }
      )
      model = newModel
      do {
        try await newModel.load()
      } catch {
        if newModel.accountDID == appState.userDID && !newModel.isInvalidated {
          errorMessage = error.localizedDescription
        }
      }
      guard newModel.accountDID == appState.userDID && !newModel.isInvalidated else { return }
      guard newModel.accessState == .needsAuthorization else { return }
      await authorizeCircles(model: newModel)
    }
  }

  // MARK: - Feed List

  @ViewBuilder
  private func feedListView(model: CircleFeedModel) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        if let error = model.error {
          errorBanner(error: error, model: model)
        } else if let errorMessage {
          errorBanner(message: errorMessage, model: model)
        }

        if model.items.isEmpty && !model.isLoading {
          emptyStateView(model: model)
            .padding(.top, 40)
        } else {
          ForEach(Array(model.items.enumerated()), id: \.element.post.post.uri) { index, item in
          PostView.circleRow(
            item: item,
            path: $path,
            appState: appState
          )
          .id("\(item.post.post.uri.uriString())-\(item.post.post.replyCount ?? 0)-\(item.post.post.likeCount ?? 0)-\(item.post.post.viewer?.like != nil)")
          .onAppear {
            if index >= model.items.count - 3 {
              Task {
                try? await model.loadMore()
              }
            }
          }

            Divider()
          }

          if model.isLoading && !model.items.isEmpty {
            ProgressView()
              .padding()
          }
        }
      }
    }
    .refreshable {
      errorMessage = nil
      try? await model.load()
    }
  }

  // MARK: - State Views

  @ViewBuilder
  private func emptyStateView(model: CircleFeedModel) -> some View {
    ContentUnavailableView {
      Label("No Posts in Circles", systemImage: "person.2.circle")
    } description: {
      Text("Posts shared to your private Circles will appear here.")
    } actions: {
      Button("Refresh") {
        Task {
          errorMessage = nil
          try? await model.load()
        }
      }
      .buttonStyle(.bordered)
    }
  }

  @ViewBuilder
  private func accessExpiredView(model: CircleFeedModel) -> some View {
    ContentUnavailableView {
      Label("Access Expired", systemImage: "lock.badge.clock")
    } description: {
      Text("Your session or access token for this Circle has expired. Reauthorize to continue.")
    } actions: {
      Button("Reauthorize") {
        Task {
          try? await model.load()
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }

  @ViewBuilder
  private func accessRemovedView(model: CircleFeedModel) -> some View {
    ContentUnavailableView {
      Label("Circle Unavailable", systemImage: "person.crop.circle.badge.xmark")
    } description: {
      Text("Your access to this Circle was removed or the Circle is no longer available.")
    }
  }

  @MainActor
  private func authorizeCircles(model: CircleFeedModel) async {
    let currentDID = appState.userDID
    guard !currentDID.isEmpty,
          currentDID == model.accountDID,
          !model.isInvalidated,
          let did = try? DID(didString: currentDID) else { return }

    authGeneration += 1
    let generation = authGeneration

    // 1. Gateway progressive scope upgrade: ensure Circle Spaces permission on gateway session.
    // If already granted, ensureGatewayPermission returns immediately without prompting.
    do {
      try await appStateManager.authentication.ensureGatewayPermission(.circleSpaces) { authURL in
        if #available(iOS 17.4, macOS 14.4, *) {
          return try await webAuthenticationSession.authenticate(
            using: authURL,
            callback: .https(host: "catbird.blue", path: "/oauth/permission-callback"),
            preferredBrowserSession: .shared,
            additionalHeaderFields: [:]
          )
        } else {
          return try await webAuthenticationSession.authenticate(
            using: authURL,
            callbackURLScheme: "catbird",
            preferredBrowserSession: .shared
          )
        }
      }
    } catch is CancellationError {
      // User dismissed the consent sheet; leave retryable and do not mark as failure
      return
    } catch let error as GatewayPermissionError where error == .cancelled {
      // User dismissed the consent sheet; leave retryable and do not mark as failure
      return
    } catch let error as GatewayPermissionError where error == .stateChanged {
      // Account switched during flow; do not set error on stale account
      return
    } catch {
      guard generation == authGeneration,
            appState.userDID == currentDID,
            AppStateManager.shared.lifecycle.userDID == currentDID,
            !model.isInvalidated,
            model.accountDID == currentDID else {
        return
      }
      errorMessage = error.localizedDescription
      return
    }

    // Account / generation fence check after gateway upgrade
    guard generation == authGeneration,
          appState.userDID == currentDID,
          AppStateManager.shared.lifecycle.userDID == currentDID,
          !model.isInvalidated,
          model.accountDID == currentDID else {
      return
    }

    // If gateway upgrade granted access, reload the model first to see if access is now active.
    // If model reload succeeds, do NOT unnecessarily prompt AppView again.
    do {
      try await model.load()
    } catch {
      if generation == authGeneration,
         appState.userDID == currentDID,
         !model.isInvalidated,
         model.accountDID == currentDID {
        errorMessage = error.localizedDescription
      }
    }

    // Account / generation fence check after model reload
    guard generation == authGeneration,
          appState.userDID == currentDID,
          AppStateManager.shared.lifecycle.userDID == currentDID,
          !model.isInvalidated,
          model.accountDID == currentDID else {
      return
    }

    // If reload succeeded and accessState is active, we are done!
    guard model.accessState == .needsAuthorization else {
      if model.accessState == .active {
        errorMessage = nil
      }
      return
    }

    // 2. AppView authorization: if AppView still needs user consent, authorize it.
    if authCoordinator.needsAuthorization(for: currentDID) {
      await authCoordinator.authorize(did: did, using: webAuthenticationSession)
    }

    // Account / generation fence check after AppView authorization
    guard generation == authGeneration,
          appState.userDID == currentDID,
          AppStateManager.shared.lifecycle.userDID == currentDID,
          !model.isInvalidated,
          model.accountDID == currentDID else {
      return
    }

    if authCoordinator.state == .authorized {
      do {
        try await model.load()
        if model.accessState == .active {
          errorMessage = nil
        }
      } catch {
        if generation == authGeneration,
           appState.userDID == currentDID,
           !model.isInvalidated,
           model.accountDID == currentDID {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  /// The AppView refused the read for want of its own OAuth grant. This is a
  /// second, separate consent from gateway sign-in, and it is recoverable —
  /// never treated as a deleted Circle.
  @ViewBuilder
  private func needsAuthorizationView(model: CircleFeedModel) -> some View {
    ContentUnavailableView {
      Label("Authorize Circles", systemImage: "lock.shield")
    } description: {
      if let errorMessage {
        Text(errorMessage)
      } else if case .failed(let message) = authCoordinator.state {
        Text(message)
      } else {
        Text(
          "Catbird needs your permission to read your Circles. This approval is separate from signing in."
        )
      }
    } actions: {
      Button("Authorize") {
        Task {
          errorMessage = nil
          await authorizeCircles(model: model)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(authCoordinator.state == .authorizing)
      .accessibilityIdentifier("circles.authorizeAppView")
    }
  }

  private var unsupportedView: some View {
    ContentUnavailableView {
      Label("Circles Unsupported", systemImage: "exclamationmark.triangle")
    } description: {
      Text("This server does not support Spaces protocol for private Circles.")
    }
  }

  @ViewBuilder
  private func errorBanner(error: CircleError, model: CircleFeedModel) -> some View {
    errorBanner(message: error.localizedDescription, model: model)
  }

  @ViewBuilder
  private func errorBanner(message: String, model: CircleFeedModel) -> some View {
    HStack {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.caption)
        .lineLimit(2)
      Spacer()
      Button("Retry") {
        Task {
          errorMessage = nil
          try? await model.load()
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(10)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    .padding(.horizontal)
    .padding(.top, 8)
  }
}
