import Petrel
import SwiftUI

extension AppBskyActorDefs.StatusView {
  /// Whether this status is the live status and currently active, including a
  /// client-side expiry check against `expiresAt`.
  var isLiveNow: Bool {
    guard status == "app.bsky.actor.status#live", isActive == true else { return false }
    if let expiresAt = expiresAt {
      return expiresAt.date > Date()
    }
    return true
  }

  /// The external URL attached to the status embed, if any.
  var liveEmbedURL: URL? {
    guard case let .appBskyEmbedExternalView(view) = embed else { return nil }
    return view.external.uri.url ?? URL(string: view.external.uri.uriString())
  }
}

/// Red "LIVE" capsule shown over a profile avatar while the account has an
/// active live status. Tapping opens the status embed's external URL via the
/// app's URL handling; without an embed the badge is non-interactive.
struct LiveStatusBadge: View {
  let embedURL: URL?

  @Environment(AppState.self) private var appState

  init(embedURL: URL? = nil) {
    self.embedURL = embedURL
  }

  var body: some View {
    if let embedURL {
      Button {
        _ = appState.urlHandler.handle(embedURL)
      } label: {
        badgeLabel
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Live now")
      .accessibilityHint("Opens the live stream link")
    } else {
      badgeLabel
        .accessibilityLabel("Live now")
    }
  }

  private var badgeLabel: some View {
    Text("LIVE")
      .designFont(
        size: DesignTokens.FontSize.micro,
        weight: .bold,
        letterSpacing: DesignTokens.LetterSpacing.wide
      )
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.red))
      .padding(DesignTokens.Size.borderBold)
      .background(Capsule().fill(Color.systemBackground))
      .contentShape(Capsule())
  }
}

#Preview("LiveStatusBadge") {
  VStack(spacing: 12) {
    LiveStatusBadge()
    LiveStatusBadge(embedURL: URL(string: "https://example.com/live"))
  }
  .padding()
  .previewWithMockEnvironment()
}
