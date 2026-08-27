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
  @Binding var path: NavigationPath
  @State private var model: CircleFeedModel?
  @State private var errorMessage: String?
  @State private var showingCreateCircleSheet = false
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  private var authCoordinator: CircleAppViewAuthCoordinator { .shared }

  init(path: Binding<NavigationPath>) {
    self._path = path
  }

  var body: some View {
    Group {
      if let model {
        switch model.accessState {
        case .active:
          if model.items.isEmpty && !model.isLoading {
            emptyStateView
          } else {
            feedListView(model: model)
          }
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
    .task {
      guard model == nil else { return }

      let newModel = CircleFeedModel(
        service: appState.circleService,
        accountDID: appState.userDID,
        activeDIDProvider: { AppStateManager.shared.lifecycle.userDID }
      )
      model = newModel
      do {
        try await newModel.load()
      } catch {
        errorMessage = error.localizedDescription
      }
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
        }

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
    .refreshable {
      try? await model.load()
    }
  }

  // MARK: - State Views

  private var emptyStateView: some View {
    ContentUnavailableView {
      Label("No Posts in Circles", systemImage: "person.2.circle")
    } description: {
      Text("Posts shared to your private Circles will appear here.")
    } actions: {
      Button("Refresh") {
        Task {
          try? await model?.load()
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
    guard authCoordinator.needsAuthorization,
          let did = try? DID(didString: appState.userDID)
    else { return }

    await authCoordinator.authorize(did: did, using: webAuthenticationSession)
    if authCoordinator.state == .authorized {
      try? await model.load()
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
      if case .failed(let message) = authCoordinator.state {
        Text(message)
      } else {
        Text(
          "Catbird needs your permission to read your Circles. This approval is separate from signing in."
        )
      }
    } actions: {
      Button("Authorize") {
        Task {
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
    HStack {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
      Text(error.localizedDescription)
        .font(.caption)
        .lineLimit(2)
      Spacer()
      Button("Retry") {
        Task {
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
