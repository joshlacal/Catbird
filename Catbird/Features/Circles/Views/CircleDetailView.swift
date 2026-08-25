//
//  CircleDetailView.swift
//  Catbird
//

import SwiftUI
import Petrel
import PetrelCatbird

/// View displaying the feed and details for a single specific Circle Space.
struct CircleDetailView: View {
  let circle: CircleSummary
  @Environment(AppState.self) private var appState
  @Binding var path: NavigationPath
  @State private var model: CircleFeedModel?
  @State private var errorMessage: String?

  init(circle: CircleSummary, path: Binding<NavigationPath>) {
    self.circle = circle
    self._path = path
  }

  var body: some View {
    Group {
      if let model {
        switch model.accessState {
        case .active:
          feedContent(model: model)
        case .expired:
          accessExpiredView(model: model)
        case .removed:
          accessRemovedView
        case .unsupported:
          unsupportedView
        }
      } else {
        ProgressView("Loading \(circle.name)...")
      }
    }
    .navigationTitle(circle.name)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task {
      if model == nil {
        let newModel = CircleFeedModel(
          service: appState.circleService,
          space: circle.uri,
          accountDID: appState.userDID ?? ""
        )
        self.model = newModel
        do {
          try await newModel.load()
        } catch {
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  // MARK: - Feed Content

  @ViewBuilder
  private func feedContent(model: CircleFeedModel) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        headerView
          .padding()

        Divider()

        if let error = model.error {
          errorBanner(error: error, model: model)
        }

        if model.items.isEmpty && !model.isLoading {
          emptyStateView
            .padding(.top, 40)
        } else {
          ForEach(Array(model.items.enumerated()), id: \.element.post.post.uri) { index, item in
            PostView.circleRow(
              item: item,
              path: $path,
              appState: appState
            )
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
      try? await model.load()
    }
  }

  // MARK: - Header

  private var headerView: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Image(systemName: "person.2.circle.fill")
          .font(.system(size: 36))
          .foregroundStyle(Color.accentColor)

        VStack(alignment: .leading, spacing: 2) {
          Text(circle.name)
            .font(.title3.weight(.bold))

          Text("Owner: @\(circle.owner.didString())")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
    }
  }

  // MARK: - State Views

  private var emptyStateView: some View {
    ContentUnavailableView {
      Label("No Posts Yet", systemImage: "bubble.left.and.bubble.right")
    } description: {
      Text("Posts shared to this Circle will appear here.")
    }
  }

  @ViewBuilder
  private func accessExpiredView(model: CircleFeedModel) -> some View {
    ContentUnavailableView {
      Label("Access Expired", systemImage: "lock.badge.clock")
    } description: {
      Text("Your access to \(circle.name) has expired. Reauthorize to continue.")
    } actions: {
      Button("Reauthorize") {
        Task {
          try? await model.load()
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private var accessRemovedView: some View {
    ContentUnavailableView {
      Label("Circle Unavailable", systemImage: "person.crop.circle.badge.xmark")
    } description: {
      Text("Your access to \(circle.name) was removed or the Circle was deleted.")
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
