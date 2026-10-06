import NukeUI
import SwiftUI
import Petrel

struct ActivitySubscriptionsView: View {
  @Environment(AppState.self) private var appState: AppState
  /// Present only inside the Settings sheet, whose stack can't push app destinations like profiles.
  @Environment(\.settingsDraftGuard) private var settingsDraftGuard

  private var service: ActivitySubscriptionService { appState.activitySubscriptionService }

  var body: some View {
    List {
      introductionSection

      if let error = service.lastError {
        Section("Status") {
          Text(UserFacingError.message(for: error, action: "load your subscriptions") ?? "Couldn’t load your subscriptions. Pull to refresh to try again.")
            .foregroundStyle(.red)
            .appBody()
        }
      }

      if service.isLoading && service.subscriptions.isEmpty {
        Section("Subscriptions") {
          HStack {
            ProgressView()
            Text("Loading subscriptions…")
              .appBody()
          }
        }
      } else if service.subscriptions.isEmpty {
        Section("Subscriptions") {
          Text("You aren’t subscribed to anyone yet. Visit a profile and tap the bell to get alerts when they post.")
            .appBody()
            .foregroundStyle(.secondary)
        }
      } else {
        Section("Subscriptions") {
          ForEach(service.subscriptions) { entry in
            Group {
              if settingsDraftGuard == nil {
                NavigationLink(value: NavigationDestination.profile(entry.profile.did)) {
                  ActivitySubscriptionRow(entry: entry)
                }
              } else {
                ActivitySubscriptionRow(entry: entry)
              }
            }
            .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
          }
        }
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.automatic)
    #endif
    .themedPrimaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .navigationTitle("People I Subscribe To")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task {
      if service.subscriptions.isEmpty && !service.isLoading {
        await service.refreshSubscriptions()
      }
    }
    .refreshable {
      await service.refreshSubscriptions()
    }
  }

  private var introductionSection: some View {
    Section("How it works") {
      Text("Get an alert when people you subscribe to post. Change or turn off alerts here, and use the bell on any profile to add more people.")
        .appBody()
        .foregroundStyle(.secondary)
    }
  }
}

private struct ActivitySubscriptionRow: View {
  @Environment(AppState.self) private var appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  let entry: ActivitySubscriptionService.SubscriptionEntry
  @State private var actionError: String?

  private var service: ActivitySubscriptionService { appState.activitySubscriptionService }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        avatarView

        VStack(alignment: .leading, spacing: 2) {
          Text(entry.profile.displayNameOrHandle)
            .fontWeight(.semibold)
            .appBody()
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text("@\(entry.profile.handle)")
            .appSubheadline()
            .foregroundStyle(.secondary)
        }

        Spacer()

        if service.isUpdating(did: entry.id) {
          ProgressView()
        } else {
          subscriptionMenu
        }
      }

      if let actionError {
        Text(actionError)
          .appCaption()
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
  }

  private var avatarView: some View {
    let url = entry.profile.avatar.flatMap { URL(string: $0.uriString()) }

    return LazyImage(url: url) { state in
      if let image = state.image {
        image.resizable().aspectRatio(contentMode: .fill)
      } else if state.error != nil {
        Color.systemGray5
      } else {
        ProgressView()
      }
    }
    .frame(width: 44, height: 44)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  private var subscriptionMenu: some View {
    Menu {
      Button {
        updateSubscription(posts: true, replies: false)
      } label: {
        Label("Posts Only", systemImage: currentState == .postsOnly ? "checkmark" : "bell")
      }

      Button {
        updateSubscription(posts: false, replies: true)
      } label: {
        Label("Replies Only", systemImage: currentState == .repliesOnly ? "checkmark" : "arrowshape.turn.up.left")
      }

      Button {
        updateSubscription(posts: true, replies: true)
      } label: {
        Label("Posts and Replies", systemImage: currentState == .postsAndReplies ? "checkmark" : "bubble.left.and.bubble.right")
      }

      if currentState != .none {
        Button(role: .destructive) {
          updateSubscription(posts: false, replies: false)
        } label: {
          Label("Turn Off", systemImage: "bell.slash")
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text(currentState.title)
          .appSubheadline()
          .foregroundStyle(.secondary)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  private var currentState: SubscriptionState {
    guard let subscription = entry.subscription else { return .none }
    switch (subscription.post, subscription.reply) {
    case (true, true): return .postsAndReplies
    case (true, false): return .postsOnly
    case (false, true): return .repliesOnly
    default: return .none
    }
  }

  private func updateSubscription(posts: Bool, replies: Bool) {
    actionError = nil

    Task {
      do {
        try await service.setSubscription(for: entry.id, posts: posts, replies: replies)
      } catch {
        actionError = UserFacingError.message(for: error, action: "update this subscription")
      }
    }
  }

  private enum SubscriptionState: Equatable {
    case none
    case postsOnly
    case postsAndReplies
    case repliesOnly

    var title: String {
      switch self {
      case .none:
        return "Off"
      case .postsOnly:
        return "Posts"
      case .postsAndReplies:
        return "Posts & Replies"
      case .repliesOnly:
        return "Replies"
      }
    }
  }
}

#Preview("ActivitySubscriptionsView") {
  NavigationStack {
    ActivitySubscriptionsView()
  }
  .previewWithAuthenticatedState()
}
