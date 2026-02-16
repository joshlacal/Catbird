import SwiftUI
import WebKit
import OSLog

// MARK: - TileLiveView

/// Renders a DASL Web Tile as a live, sandboxed WebView
/// Uses WebKit for SwiftUI (iOS 26+) with full security isolation
@available(iOS 26.0, macOS 26.0, *)
struct TileLiveView: View {
  let tile: TileEmbedData
  let resources: [String: CachedTileResource]
  var onDismiss: (() -> Void)?

  @State private var page: WebPage?
  @State private var isLoading = true
  @State private var loadError: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "TileLiveView")

  var body: some View {
    VStack(spacing: 0) {
      // Title bar
      titleBar

      // Tile content
      Group {
        if let page {
          WebView(page)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewMagnificationGestures(.disabled)
        } else if let error = loadError {
          errorView(error)
        } else {
          loadingView
        }
      }
      .frame(maxWidth: .infinity)
      .frame(
        idealHeight: CGFloat(tile.sizing?.height ?? 400)
      )
    }
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    )
    .task {
      await setupTile()
    }
  }

  // MARK: - Title Bar

  private var titleBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "square.grid.2x2.fill")
        .font(.caption2)
        .foregroundStyle(.secondary)

      Text(tile.name)
        .font(.caption)
        .fontWeight(.medium)
        .lineLimit(1)

      Spacer()

      if let onDismiss {
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }

  // MARK: - Loading / Error

  private var loadingView: some View {
    VStack(spacing: 8) {
      ProgressView()
      Text("Loading tile…")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray.opacity(0.05))
  }

  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("Failed to load tile")
        .font(.caption)
        .fontWeight(.medium)
      Text(error)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray.opacity(0.05))
  }

  // MARK: - Setup

  @MainActor
  private func setupTile() async {
    let tileCID = tile.tileCID
    let scheme = TileURLSchemeHandler.scheme(for: tileCID)

    // Create scheme handler with tile resources
    let handler = TileURLSchemeHandler(resources: resources)

    // Configure WebPage with security restrictions
    var config = WebPage.Configuration()
    config.websiteDataStore = .nonPersistent()
    config.suppressesIncrementalRendering = true

    // Register custom scheme handler
    guard let urlScheme = URLScheme(scheme) else {
      loadError = "Invalid tile scheme"
      isLoading = false
      return
    }
    config.urlSchemeHandlers[urlScheme] = handler

    // Create navigation decider that blocks all external navigation
    var decider = TileNavigationDecider(allowedScheme: scheme)

    let webPage = WebPage(configuration: config, navigationDecider: decider)

    // Load the root resource
    guard let rootURL = URL(string: "\(scheme):///") else {
      loadError = "Invalid tile root URL"
      isLoading = false
      return
    }

    do {
      for try await event in webPage.load(URLRequest(url: rootURL)) {
        switch event {
        case .committed:
          logger.debug("Tile navigation committed: \(tileCID, privacy: .public)")
        case .finished:
          logger.debug("Tile loaded: \(tileCID, privacy: .public)")
          page = webPage
          isLoading = false
        default:
          break
        }
      }
    } catch {
      logger.error("Tile load failed: \(error.localizedDescription, privacy: .public)")
      loadError = error.localizedDescription
      isLoading = false
    }
  }
}

// MARK: - TileNavigationDecider

/// Blocks all navigation except within the tile's own custom scheme
@available(iOS 26.0, macOS 26.0, *)
@MainActor
struct TileNavigationDecider: WebPage.NavigationDeciding {
  private let allowedScheme: String
  private let logger = Logger(subsystem: "blue.catbird", category: "TileNavigationDecider")

  init(allowedScheme: String) {
    self.allowedScheme = allowedScheme
  }

  mutating func decidePolicy(
    for action: WebPage.NavigationAction,
    preferences: inout WebPage.NavigationPreferences
  ) async -> WKNavigationActionPolicy {
    let url = action.request.url
    let scheme = url?.scheme ?? ""

    if scheme == allowedScheme || scheme == "blob" || scheme == "data" {
      return .allow
    }

    // Block all external navigation
    logger.warning(
      "Blocked external navigation to: \(url?.absoluteString ?? "nil", privacy: .public)"
    )
    return .cancel
  }
}
