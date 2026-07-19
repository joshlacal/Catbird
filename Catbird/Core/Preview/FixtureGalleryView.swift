#if DEBUG
  import Petrel
  import SwiftUI

  /// Launch-arg-gated (`--fixture-gallery`) screen that renders the static preview-fixture
  /// corpus through the real feed components, so the corpus can be visually verified on a
  /// simulator without credentials. See `scripts/preview-fixtures/README.md` (workspace root).
  struct FixtureGalleryView: View {
    @State private var appState: AppState?
    @State private var path = NavigationPath()

    private static let postShapes: [PreviewFixtures.PostShape] = [
      .textShort, .facets, .images4, .externalThumb, .gallery6, .recordWithMedia, .selfLabels,
    ]
    private static let quoteShapes: [PreviewFixtures.PostShape] = [
      .quotePost, .quoteList, .quoteFeedgen, .quoteStarterpack,
      .quoteBlocked, .quoteDetached, .quoteNotfound,
    ]

    var body: some View {
      Group {
        if let appState {
          gallery(appState)
        } else {
          ProgressView("Building fixture AppState…")
        }
      }
      .task {
        appState = await PreviewContainer.fixtureAppState()
      }
    }

    private func gallery(_ appState: AppState) -> some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
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

          section("Quote unions")
          ForEach(Self.quoteShapes, id: \.self) { shape in
            labeled(shape.rawValue) {
              if let post = PreviewFixtures.post(shape),
                 case .appBskyEmbedRecordView(let recordView) = post.embed {
                RecordEmbedView(record: recordView.record, labels: nil, path: $path)
              }
            }
          }

          section("Profiles")
          labeled("profile-bot / profile-real") {
            VStack(spacing: 8) {
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
            VStack(spacing: 4) {
              ForEach(PreviewFixtures.chatConvos?.convos ?? [], id: \.id) { convo in
                ConversationRow(convo: convo, currentUserDID: appState.userDID)
              }
            }
          }
        }
        .padding(.vertical)
      }
      .environment(appState)
      .background(Color(.systemBackground))
      .accessibilityIdentifier("fixture-gallery")
    }

    private func section(_ title: String) -> some View {
      Text(title)
        .font(.title3.bold())
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func labeled(@ViewBuilder _ content: () -> some View) -> some View {
      labeled("", content)
    }

    private func labeled(
      _ tag: String, @ViewBuilder _ content: () -> some View
    ) -> some View {
      VStack(alignment: .leading, spacing: 2) {
        if !tag.isEmpty {
          Text(tag)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        }
        content()
      }
    }
  }
#endif
