import Nuke
import NukeUI
import Petrel
import SwiftUI

/// One decorative, static preview. The topic's enclosing button owns all navigation and speech.
struct TrendingTopicArtwork: View {
  @Environment(AppState.self) private var appState
  let link: String
  /// The trend's own "who is chatting" actors from getTrends; preview authors fill any gap.
  var actors: [AppBskyActorDefs.ProfileViewBasic] = []
  var showParticipants = true

  var body: some View {
    let artwork = appState.topicArtwork(for: link, actors: showParticipants ? actors : nil)
    TrendingTopicArtworkPresentation(
      preview: artwork.preview,
      showParticipants: showParticipants,
      participants: artwork.participants
    )
    .task(id: appState.topicPreviewLabelers + "|" + appState.topicPreviewAppliedLabelers + "|\(appState.trendingTopicMediaStore.revision)|" + link) {
      await appState.loadTopicPreview(for: link)
    }
    .onReceive(NotificationCenter.default.publisher(for: PreferencesManager.acceptLabelersHeaderDidChange)) { notification in
      guard ProfileLabelRefresh.matches(notification, preferencesManager: appState.preferencesManager,
        viewerDID: appState.userDID, isActiveViewer: !appState.isAccountSwitchSuspended) else { return }
      appState.trendingTopicMediaStore.invalidate(labelers: appState.topicPreviewLabelers)
    }
  }
}

/// Moderated "who is chatting" avatars shown apart from the media stack (Search rows).
struct TrendingTopicParticipants: View {
  @Environment(AppState.self) private var appState
  let link: String
  let actors: [AppBskyActorDefs.ProfileViewBasic]

  var body: some View {
    TrendingTopicParticipantStack(participants: appState.topicParticipants(for: link, actors: actors))
  }
}

struct TrendingTopicParticipantStack: View {
  let participants: [TrendingTopicPreview.Participant]

  var body: some View {
    if !participants.isEmpty {
      HStack(spacing: -6) {
        ForEach(participants) { participant in
          LazyImage(request: TrendingTopicImageRequests.request(participant.avatar,
            size: TrendingTopicImageRequests.avatarSize, priority: .normal)) { state in
            if let image = state.image {
              image.resizable().scaledToFill()
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
            }
          }
          .pipeline(ImageLoadingManager.shared.pipeline)
          .frame(width: 26, height: 26)
        }
      }
      .accessibilityHidden(true)
      .allowsHitTesting(false)
    }
  }
}

struct TrendingTopicArtworkPresentation: View {
  let preview: TrendingTopicPreview
  var showParticipants = true
  /// Overrides `preview.participants` (e.g. trend actors merged with preview authors).
  var participants: [TrendingTopicPreview.Participant]?
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack {
        if !preview.media.isEmpty {
          ForEach(Array(preview.media.enumerated()), id: \.element.id) { index, card in
            LazyImage(request: TrendingTopicImageRequests.request(card.url,
              size: TrendingTopicImageRequests.cardSize, priority: .normal)) { state in
              if let image = state.image {
                image.resizable().scaledToFill()
                  .frame(width: 62, height: 72)
                  .clipShape(.rect(cornerRadius: 7))
                  .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.background, lineWidth: 2) }
                  .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.15), radius: 3, y: 2)
              }
            }
            .pipeline(ImageLoadingManager.shared.pipeline)
            .frame(width: 62, height: 72)
            .rotationEffect(.degrees(reduceMotion ? 0 : rotation(index)))
            .offset(x: offset(index), y: index == 1 ? -2 : 2)
          }
        }
      }
      .frame(width: 108, height: 86)
      // Rasterize the rotated, shadowed stack once instead of compositing three shadows per frame.
      // The padding keeps rotated corners and shadows inside the offscreen bounds.
      .padding(12)
      .drawingGroup()
      .padding(-12)
      if showParticipants {
        TrendingTopicParticipantStack(participants: participants ?? preview.participants)
          .padding(.horizontal, 8)
      }
    }
    // A late response, failed image or text-only topic cannot resize its row or hosting cell.
    .frame(width: 108, height: showParticipants ? 116 : 86, alignment: .topLeading)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
    .transaction { $0.animation = nil }
  }

  private func offset(_ index: Int) -> CGFloat {
    let center = CGFloat(preview.media.count - 1) / 2
    return (CGFloat(index) - center) * 18 * (layoutDirection == .rightToLeft ? -1 : 1)
  }

  private func rotation(_ index: Int) -> Double {
    let angle = [-9.0, 4.0, 11.0][index % 3]
    return angle * (layoutDirection == .rightToLeft ? -1 : 1)
  }
}

/// Reuses Catbird's existing variable-width accent typography and font preferences.
struct TrendingTopicTitle: View {
  @Environment(\.fontManager) private var fontManager
  let title: String
  var size: CGFloat = 22
  /// nil wraps freely; uniform cards pass a bound and truncate the tail.
  var lineLimit: Int?

  var body: some View {
    Text(title)
      .appFont(fontManager.scaledCustomFont(size: size, weight: .bold, width: 120, relativeTo: .title3))
      .foregroundStyle(.primary)
      .multilineTextAlignment(.leading)
      .lineLimit(lineLimit)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
  }
}
