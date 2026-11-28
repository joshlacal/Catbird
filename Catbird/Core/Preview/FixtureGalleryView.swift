//
//  FixtureGalleryView.swift
//  Catbird
//
//  DEBUG-only fixture showcase rendering the harvested 35-endpoint Bluesky
//  corpus through real feed, embed, profile, and chat row views offline.
//

#if DEBUG
import Petrel
import SwiftUI

/// Launch-arg-gated (`--fixture-gallery`) view that renders the static preview-fixture
/// corpus through real production components with zero network access.
struct FixtureGalleryView: View {
  @State private var appState: AppState?
  @State private var sceneContext: SceneNavigationContext?
  @State private var path = NavigationPath()

  private static let postShapes: [PreviewFixtures.PostShape] = [
    .textShort, .facets, .images4, .externalThumb, .gallery6, .recordWithMedia, .selfLabels
  ]
  private static let quoteShapes: [PreviewFixtures.PostShape] = [
    .quotePost, .quoteList, .quoteFeedgen, .quoteStarterpack,
    .quoteBlocked, .quoteDetached, .quoteNotfound
  ]

  var body: some View {
    Group {
      if let appState, let sceneContext {
        gallery(appState: appState, sceneContext: sceneContext)
      } else {
        ProgressView {
          Text(verbatim: "Building fixture AppState…")
        }
      }
    }
    .task {
      let state = await PreviewContainer.fixtureAppState()
      appState = state
      sceneContext = SceneNavigationContext(appState: state, sceneID: UUID())
    }
  }

  private func gallery(appState: AppState, sceneContext: SceneNavigationContext) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.lg) {
        postsSection(appState: appState)
        quotesSection
        profilesAndConversationsSection(appState: appState)
      }
      .padding(.vertical, Space.lg)
    }
    .environment(appState)
    .environment(sceneContext)
    .environment(AppStateManager.shared)
    .applyAppStateEnvironment(appState)
    .applyTheme(appState.themeManager)
    .fontManager(appState.fontManager)
    .accessibilityIdentifier("fixture-gallery")
  }

  @ViewBuilder
  private func postsSection(appState: AppState) -> some View {
    section("Posts")
    ForEach(Self.postShapes, id: \.self) { shape in
      labeled(shape.rawValue) {
        if let post = PreviewFixtures.post(shape) {
          PostView(
            post: post,
            grandparentAuthor: nil,
            isParentPost: false,
            isSelectable: false,
            path: $path,
            appState: appState
          )
        }
      }
    }

    section("Video (harvested real post)")
    labeled("post-video-real") {
      if let post = PreviewFixtures.videoPost {
        PostView(
          post: post,
          grandparentAuthor: nil,
          isParentPost: false,
          isSelectable: false,
          path: $path,
          appState: appState
        )
      }
    }
  }

  @ViewBuilder
  private var quotesSection: some View {
    section("Quote unions")
    ForEach(Self.quoteShapes, id: \.self) { shape in
      labeled(shape.rawValue) {
        if let post = PreviewFixtures.post(shape),
           case .appBskyEmbedRecordView(let recordView) = post.embed {
          RecordEmbedView(record: recordView.record, path: $path)
        }
      }
    }
  }

  @ViewBuilder
  private func profilesAndConversationsSection(appState: AppState) -> some View {
    section("Profiles")
    labeled("profile-bot / profile-real") {
      VStack(spacing: Space.sm) {
        if let bot = PreviewFixtures.profileBot {
          ProfileRowView(profile: bot, path: $path)
        }
        if let real = PreviewFixtures.profileReal {
          ProfileRowView(profile: real, path: $path)
        }
      }
    }

    section("Conversations")
    labeled("chat-convos") {
      VStack(spacing: Space.xs) {
        ForEach(PreviewFixtures.chatConvos?.convos ?? [], id: \.id) { convo in
          ConversationRow(convo: convo, currentUserDID: appState.userDID)
        }
      }
    }
  }

  private func section(_ title: String) -> some View {
    Text(verbatim: title)
      .appFont(AppTextRole.title3)
      .padding(.horizontal, Space.screenMargin)
      .padding(.top, Space.sm)
  }

  private func labeled<Content: View>(
    _ tag: String,
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Space.hairline) {
      if !tag.isEmpty {
        Text(verbatim: tag)
          .appFont(AppTextRole.caption2)
          .foregroundStyle(.secondary)
          .padding(.horizontal, Space.screenMargin)
      }
      content()
    }
  }
}
#endif
