import SwiftUI
import OSLog

// MARK: - TileEmbedView

/// Top-level tile embed view that switches between card and live modes
/// Card mode works on all iOS versions; live mode requires iOS 26+
struct TileEmbedView: View {
  let tile: TileEmbedData
  @State private var isLive = false
  @State private var resources: [String: CachedTileResource]?
  @State private var isLoadingResources = false
  @State private var loadError: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "TileEmbedView")

  var body: some View {
    Group {
      if isLive, let resources {
        liveView(resources: resources)
      } else {
        TileCardView(tile: tile) {
          activateTile()
        }
        .overlay(alignment: .center) {
          if isLoadingResources {
            ProgressView()
              .padding(8)
              .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
  }

  @ViewBuilder
  private func liveView(resources: [String: CachedTileResource]) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      TileLiveView(
        tile: tile,
        resources: resources,
        onDismiss: {
          withAnimation(.easeInOut(duration: 0.2)) {
            isLive = false
          }
        }
      )
    } else {
      // Fallback: show card with "requires iOS 26" message
      VStack(spacing: 8) {
        TileCardView(tile: tile)
        Text("Live tiles require iOS 26 or later")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func activateTile() {
    guard let manifest = tile.manifest else {
      logger.warning("No manifest available for tile: \(tile.name)")
      return
    }

    guard !isLoadingResources else { return }

    if #available(iOS 26.0, macOS 26.0, *) {
      isLoadingResources = true
      loadError = nil

      Task {
        do {
          // Extract author DID and PDS host from the tile URI
          let (authorDID, pdsHost) = extractATInfo(from: tile.uri)

          let loaded = try await TileResourceLoader.shared.loadResources(
            for: manifest,
            authorDID: authorDID,
            pdsHost: pdsHost
          )

          await MainActor.run {
            resources = loaded
            isLoadingResources = false
            withAnimation(.easeInOut(duration: 0.2)) {
              isLive = true
            }
          }
        } catch {
          logger.error("Failed to load tile resources: \(error.localizedDescription)")
          await MainActor.run {
            isLoadingResources = false
            loadError = error.localizedDescription
          }
        }
      }
    }
  }

  /// Extract author DID and PDS host from an AT URI
  private func extractATInfo(from uri: String) -> (authorDID: String, pdsHost: String) {
    // AT URIs look like: at://did:plc:xxx/ing.dasl.masl/tid
    let parts = uri.replacingOccurrences(of: "at://", with: "").split(separator: "/")
    let did = parts.first.map(String.init) ?? ""
    // Default PDS host — in production, resolve via DID document
    let pdsHost = "bsky.social"
    return (did, pdsHost)
  }
}
