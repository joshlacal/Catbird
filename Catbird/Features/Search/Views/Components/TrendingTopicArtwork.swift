import Nuke
import NukeUI
import SwiftUI

/// One decorative, static preview. The topic's enclosing button owns all navigation and speech.
struct TrendingTopicArtwork: View {
  @Environment(AppState.self) private var appState
  let link: String
  var showParticipants = true

  var body: some View {
    TrendingTopicArtworkPresentation(preview: appState.topicPreview(for: link), showParticipants: showParticipants)
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

struct TrendingTopicArtworkPresentation: View {
  let preview: TrendingTopicPreview
  var showParticipants = true
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack {
        if !preview.media.isEmpty {
          ForEach(Array(preview.media.enumerated()), id: \.element.id) { index, card in
            LazyImage(request: TrendingTopicImageRequests.request(card.url, size: CGSize(width: 62, height: 72))) { state in
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
      if showParticipants && !preview.participants.isEmpty {
        HStack(spacing: -6) {
          ForEach(preview.participants) { participant in
            LazyImage(request: TrendingTopicImageRequests.request(participant.avatar, size: CGSize(width: 26, height: 26))) { state in
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

  var body: some View {
    Text(title)
      .appFont(fontManager.scaledCustomFont(size: size, weight: .bold, width: 120, relativeTo: .title3))
      .foregroundStyle(.primary)
      .multilineTextAlignment(.leading)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
  }
}
