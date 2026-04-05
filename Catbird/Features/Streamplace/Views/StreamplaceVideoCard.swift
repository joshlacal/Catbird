import SwiftUI

struct StreamplaceVideoCard: View {
  let video: StreamplaceService.VideoRecord
  let thumbnail: CGImage?
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Thumbnail
      ZStack {
        if let thumbnail {
          Image(decorative: thumbnail, scale: 1.0)
            .resizable()
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .clipped()
        } else {
          Rectangle()
            .fill(Color.gray.opacity(0.2))
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .overlay { ProgressView() }
        }

        // Play button overlay
        Image(systemName: "play.circle.fill")
          .font(.system(size: 44))
          .foregroundStyle(.white.opacity(0.9))
          .shadow(radius: 4)

        // Duration badge
        VStack {
          Spacer()
          HStack {
            Spacer()
            Text(video.formattedDuration)
              .appFont(AppTextRole.caption)
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(.black.opacity(0.7)))
              .padding(8)
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))

      // Title
      Text(video.video.title)
        .appFont(AppTextRole.headline)
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .primary, currentScheme: colorScheme))
        .lineLimit(2)

      // Date
      Text(video.video.createdAt.date, style: .date)
        .appFont(AppTextRole.caption)
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
    }
    .padding(.vertical, 4)
  }
}
