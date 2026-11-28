//
//  CatbirdCatalogSurfaces.swift
//  Catbird
//
//  Root catalog surface router (`CatbirdCatalogSurfaceView`) plus primary
//  offline mocked surfaces: Feed, Thread, Profile, and Search.
//

#if DEBUG
import Petrel
import SwiftUI

/// Renders a single deterministic catalog surface inside an already-configured
/// `CatbirdCatalogSession` (zero auth, zero live network).
struct CatbirdCatalogSurfaceView: View {
  let surface: CatbirdCatalogSurface
  let config: CatbirdCatalogLaunchConfig
  let session: CatbirdCatalogSession

  var body: some View {
    Group {
      switch surface {
      case .kit:
        CatbirdKitGallery(
          themeManager: session.appState.themeManager,
          fontManager: session.appState.fontManager,
          showsControls: !config.hideChrome,
          embedInNavigationStack: true
        )
      case .feed:
        CatalogFeedSurface(appState: session.appState)
      case .thread:
        CatalogThreadSurface(appState: session.appState)
      case .profile:
        CatalogProfileSurface(appState: session.appState)
      case .search:
        CatalogSearchSurface(appState: session.appState)
      case .chat:
        CatalogChatSurface(appState: session.appState)
      case .composer:
        CatalogComposerSurface(session: session)
      case .settings:
        SettingsView()
      case .onboarding:
        LoginView(
          isAddingNewAccount: false,
          initialAuthMode: .selection,
          isPresentedModally: false
        )
        .environment(\.skyAnimationPaused, true)
      case .askCatbird:
        CatalogAskCatbirdSurface()
      case .notifications:
        CatalogNotificationsSurface(appState: session.appState)
      case .widgets:
        CatalogWidgetsSurface()
      }
    }
    .environment(session.appState)
    .environment(session.sceneContext)
    .environment(AppStateManager.shared)
    .modelContainer(session.modelContainer)
    .applyAppStateEnvironment(session.appState)
    .applyTheme(session.appState.themeManager)
    .fontManager(session.appState.fontManager)
    .environment(\.toastManager, session.appState.toastManager)
    .environment(\.isPreviewMode, true)
    .environment(\.previewNetworkMode, .mock)
    .environment(\.dynamicTypeSize, config.dynamicType)
    .environment(\.layoutDirection, config.layoutDirection)
    .preferredColorScheme(config.preferredColorScheme)
  }
}

// MARK: - Feed Surface

struct CatalogFeedSurface: View {
  let appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @State private var path = NavigationPath()
  @State private var selectedFeedChip = 0

  private static let shapes: [PreviewFixtures.PostShape] = [
    .textShort, .facets, .images4, .externalThumb, .recordWithMedia,
    .quotePost, .quoteBlocked, .quoteDetached, .quoteNotfound, .selfLabels
  ]

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.lg) {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
              CatbirdChip(title: Text(verbatim: "Following"), isSelected: selectedFeedChip == 0) {
                selectedFeedChip = 0
              }
              CatbirdChip(title: Text(verbatim: "Discover"), isSelected: selectedFeedChip == 1) {
                selectedFeedChip = 1
              }
              CatbirdChip(title: Text(verbatim: "Science"), isSelected: selectedFeedChip == 2) {
                selectedFeedChip = 2
              }
            }
            .padding(.horizontal, Space.screenMargin)
          }

          ForEach(Self.shapes, id: \.self) { shape in
            if let post = PreviewFixtures.post(shape) {
              PostView(
                post: post,
                grandparentAuthor: nil,
                isParentPost: false,
                isSelectable: false,
                path: $path,
                appState: appState
              )
              .padding(.horizontal, Space.screenMargin)
            }
          }

          if let videoPost = PreviewFixtures.videoPost {
            PostView(
              post: videoPost,
              grandparentAuthor: nil,
              isParentPost: false,
              isSelectable: false,
              path: $path,
              appState: appState
            )
            .padding(.horizontal, Space.screenMargin)
          }
        }
        .padding(.vertical, Space.md)
      }
      .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
      .navigationTitle(Text(verbatim: "Following"))
    }
    .accessibilityIdentifier("catalog.surface.content.feed")
  }
}

// MARK: - Thread Surface

struct CatalogThreadSurface: View {
  let appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @State private var path = NavigationPath()

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.md) {
          if let root = PreviewFixtures.post(.replyRoot) {
            PostView(
              post: root,
              grandparentAuthor: nil,
              isParentPost: true,
              isSelectable: false,
              path: $path,
              appState: appState
            )
          }

          if let anchor = PreviewFixtures.post(.replyL1) ?? PreviewFixtures.post(.facets) {
            ThreadViewMainPostView(
              post: anchor,
              showLine: true,
              path: $path,
              appState: appState
            )
          }

          CatbirdNotice(
            tone: .info,
            title: Text(verbatim: "Who can reply"),
            message: Text(verbatim: "Mentioned accounts and followers can reply to this thread.")
          )

          ForEach([PreviewFixtures.PostShape.replyL2Appstore, .replyL3], id: \.self) { shape in
            if let reply = PreviewFixtures.post(shape) {
              PostView(
                post: reply,
                grandparentAuthor: nil,
                isParentPost: false,
                isSelectable: false,
                path: $path,
                appState: appState
              )
            }
          }
        }
        .padding(Space.screenMargin)
      }
      .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
      .navigationTitle(Text(verbatim: "Post"))
    }
    .accessibilityIdentifier("catalog.surface.content.thread")
  }
}

// MARK: - Profile Surface

struct CatalogProfileSurface: View {
  let appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @State private var path = NavigationPath()
  @State private var followState: FollowButtonState = .notFollowing
  @State private var selectedTab = 0

  var body: some View {
    let profile = PreviewFixtures.profileReal ?? PreviewFixtures.profileBot
    let posts = Array((PreviewFixtures.authorFeedBot?.feed ?? []).prefix(4))

    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.lg) {
          headerCard(profile: profile)
          tabStrip

          ForEach(posts, id: \.post.cid) { item in
            PostView(
              post: item.post,
              grandparentAuthor: nil,
              isParentPost: false,
              isSelectable: false,
              path: $path,
              appState: appState
            )
          }
        }
        .padding(Space.screenMargin)
      }
      .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
      .navigationTitle(Text(verbatim: "Profile"))
    }
    .accessibilityIdentifier("catalog.surface.content.profile")
  }

  private func headerCard(profile: AppBskyActorDefs.ProfileViewDetailed?) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      BrandGradientFill()
        .frame(height: 112)
        .catbirdClip(.md)

      HStack(alignment: .center, spacing: Space.md) {
        AsyncProfileImage(
          url: profile?.finalAvatarURL(),
          size: AvatarSize.xl,
          did: profile?.did.didString() ?? PreviewContainer.fixtureUserDID
        )
        Spacer(minLength: Space.sm)
        FollowButton(state: followState, size: .regular) {
          followState = followState == .following ? .notFollowing : .following
        }
      }

      VStack(alignment: .leading, spacing: Space.xs) {
        Text(verbatim: profile?.displayName ?? "Catbird Fixture")
          .appFont(AppTextRole.title2)
        Text(verbatim: "@\(profile?.handle.description ?? "catbird.blue")")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
      }

      if let description = profile?.description, !description.isEmpty {
        Text(verbatim: description)
          .appFont(AppTextRole.body)
      }

      HStack(spacing: Space.lg) {
        statPill(value: "\(profile?.followersCount ?? 128)", label: "Followers")
        statPill(value: "\(profile?.followsCount ?? 42)", label: "Following")
        statPill(value: "\(profile?.postsCount ?? 64)", label: "Posts")
      }
    }
    .padding(Space.lg)
    .catbirdCard(.panel)
  }

  private var tabStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Space.sm) {
        CatbirdChip(title: Text(verbatim: "Posts"), isSelected: selectedTab == 0) { selectedTab = 0 }
        CatbirdChip(title: Text(verbatim: "Replies"), isSelected: selectedTab == 1) { selectedTab = 1 }
        CatbirdChip(title: Text(verbatim: "Media"), isSelected: selectedTab == 2) { selectedTab = 2 }
        CatbirdChip(title: Text(verbatim: "Feeds"), isSelected: selectedTab == 3) { selectedTab = 3 }
      }
    }
  }

  private func statPill(value: String, label: String) -> some View {
    HStack(spacing: Space.xs) {
      Text(verbatim: value)
        .appFont(AppTextRole.subheadline)
      Text(verbatim: label)
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Search & Discovery Surface

struct CatalogSearchSurface: View {
  let appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @State private var path = NavigationPath()
  @State private var query = ""
  @State private var selectedScope = 0

  var body: some View {
    let actors = Array((PreviewFixtures.searchActors?.actors ?? []).prefix(3))
    let feeds = Array((PreviewFixtures.feedGenerators?.feeds ?? []).prefix(3))
    let trends = Array((PreviewFixtures.trends?.trends ?? []).prefix(3))

    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.xl) {
          scopeBar
          if !trends.isEmpty { trendsSection(trends) }
          if !feeds.isEmpty { feedsSection(feeds) }
          if !actors.isEmpty { actorsSection(actors) }
        }
        .padding(Space.screenMargin)
      }
      .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
      .searchable(text: $query, prompt: Text(verbatim: "Search posts, people, feeds"))
      .navigationTitle(Text(verbatim: "Search"))
    }
    .accessibilityIdentifier("catalog.surface.content.search")
  }

  private var scopeBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Space.sm) {
        CatbirdChip(title: Text(verbatim: "Top"), isSelected: selectedScope == 0) { selectedScope = 0 }
        CatbirdChip(title: Text(verbatim: "Latest"), isSelected: selectedScope == 1) { selectedScope = 1 }
        CatbirdChip(title: Text(verbatim: "People"), isSelected: selectedScope == 2) { selectedScope = 2 }
        CatbirdChip(title: Text(verbatim: "Feeds"), isSelected: selectedScope == 3) { selectedScope = 3 }
        CatbirdChip(title: Text(verbatim: "Packs"), isSelected: selectedScope == 4) { selectedScope = 4 }
      }
    }
  }

  private func trendsSection(_ trends: [AppBskyUnspeccedDefs.TrendView]) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(verbatim: "Trending")
        .appFont(AppTextRole.headline)
      ForEach(trends, id: \.topic) { trend in
        HStack(spacing: Space.md) {
          VStack(alignment: .leading, spacing: Space.xs) {
            Text(verbatim: trend.displayName.isEmpty ? trend.topic : trend.displayName)
              .appFont(AppTextRole.subheadline)
            if let category = trend.category {
              CatbirdBadge(Text(verbatim: category), tone: .accent)
            }
          }
          Spacer(minLength: Space.sm)
          Image(systemName: "chevron.right")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
        .padding(Space.md)
        .catbirdCard(.panel)
      }
    }
  }

  private func feedsSection(_ feeds: [AppBskyFeedDefs.GeneratorView]) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(verbatim: "Discover Feeds")
        .appFont(AppTextRole.headline)
      ForEach(feeds, id: \.uri) { feed in
        HStack(spacing: Space.md) {
          FeedRowView(feed: feed)
          Spacer(minLength: Space.sm)
          FeedLibraryButtonLabel(membership: .absent, size: .compact)
        }
        .padding(Space.md)
        .catbirdCard(.panel)
      }
    }
  }

  private func actorsSection(_ actors: [AppBskyActorDefs.ProfileView]) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(verbatim: "Suggested Accounts")
        .appFont(AppTextRole.headline)
      ForEach(actors, id: \.did) { actor in
        ProfileRowView(profile: actor, path: $path)
      }
    }
  }
}
#endif
