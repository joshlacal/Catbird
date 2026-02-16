import NukeUI
import SwiftUI

// MARK: - TileCardView

/// Renders a DASL Web Tile as a metadata card (name, icon, screenshot, description)
/// This is the default presentation in feeds and chat; tapping activates live mode on iOS 26+
struct TileCardView: View {
  let tile: TileEmbedData
  var onActivate: (() -> Void)?

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button {
      onActivate?()
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        // Banner image (screenshot)
        if let screenshotURL = tile.screenshotURL {
          LazyImage(url: screenshotURL) { state in
            if let image = state.image {
              image
                .resizable()
                .scaledToFill()
            } else if state.isLoading {
              Rectangle()
                .fill(bannerBackground)
                .overlay(ProgressView().scaleEffect(0.8))
            } else {
              bannerPlaceholder
            }
          }
          .frame(height: 140)
          .frame(maxWidth: .infinity)
          .clipped()
        } else {
          bannerPlaceholder
        }

        // Metadata
        HStack(spacing: 10) {
          // Icon
          if let iconURL = tile.iconURL {
            LazyImage(url: iconURL) { state in
              if let image = state.image {
                image
                  .resizable()
                  .scaledToFill()
              } else {
                tileIconPlaceholder
              }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))
          }

          VStack(alignment: .leading, spacing: 2) {
            Text(tile.name)
              .font(.caption)
              .fontWeight(.semibold)
              .foregroundStyle(.primary)
              .lineLimit(1)

            if let description = tile.tileDescription {
              Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            }
          }

          Spacer(minLength: 0)

          // Tile indicator
          Image(systemName: "square.grid.2x2")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.8))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.gray.opacity(0.2), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }

  // MARK: - Subviews

  private var bannerPlaceholder: some View {
    ZStack {
      Rectangle()
        .fill(bannerBackground)

      VStack(spacing: 6) {
        Image(systemName: "square.grid.2x2")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("Web Tile")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: 80)
    .frame(maxWidth: .infinity)
  }

  private var tileIconPlaceholder: some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(Color.gray.opacity(0.15))
      .overlay(
        Image(systemName: "square.grid.2x2")
          .font(.caption2)
          .foregroundStyle(.secondary)
      )
  }

  private var bannerBackground: Color {
    colorScheme == .dark ? Color.gray.opacity(0.15) : Color.gray.opacity(0.08)
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    TileCardView(
      tile: TileEmbedData(
        uri: "at://did:plc:example/ing.dasl.masl/abc123",
        recordCID: "bafyreib...",
        tileCID: "bafkreic...",
        name: "Minesweeper",
        tileDescription: "Classic Minesweeper game as a Web Tile",
        iconURL: nil,
        screenshotURL: nil,
        sizing: TileSizing(width: 400, height: 300),
        manifest: nil
      )
    )

    TileCardView(
      tile: TileEmbedData(
        uri: "at://did:plc:example/ing.dasl.masl/def456",
        recordCID: "bafyreic...",
        tileCID: "bafkreid...",
        name: "The Internet Transition",
        tileDescription: "An interactive presentation about the future of the web",
        iconURL: URL(string: "https://example.com/icon.png"),
        screenshotURL: URL(string: "https://example.com/banner.jpg"),
        sizing: nil,
        manifest: nil
      )
    )
  }
  .padding()
}
