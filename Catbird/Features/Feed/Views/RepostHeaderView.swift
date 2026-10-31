//
//  RepostHeaderView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/9/23.
//

import Petrel
import SwiftUI

struct RepostHeaderView: View {
  @Environment(AppState.self) private var appState: AppState?
  @Environment(\.colorScheme) private var colorScheme
  /// The reposter fields the header renders. The full profile is about 2 KB
  /// inline, and every view temporary in the body would copy it.
  private let reposterDID: DID
  private let reposterName: String
  private let reposterVerification: AppBskyActorDefs.VerificationState?
  @Binding var path: NavigationPath

  init(reposter: AppBskyActorDefs.ProfileViewBasic, path: Binding<NavigationPath>) {
    reposterDID = reposter.did
    reposterName = reposter.displayName ?? reposter.handle.description
    reposterVerification = reposter.verification
    _path = path
  }

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      Image(systemName: "arrow.2.squarepath")
        .foregroundColor(metadataColor)
        .appFont(AppTextRole.subheadline)

      repostedByText
        .appFont(AppTextRole.body)
        .textScale(.secondary)
        .foregroundColor(metadataColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .allowsTightening(true)
        .offset(y: -2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(repostedByAccessibilityLabel)

    }
    .onTapGesture {
      path.append(NavigationDestination.profile(reposterDID.didString()))
    }
    .padding(.leading, 3)
  }

  /// Same theme-aware secondary color as the post header's handle and time.
  private var metadataColor: Color {
    guard let appState else { return .secondary }
    return Color.adaptiveText(
      appState: appState, themeManager: appState.themeManager,
      style: .secondary, currentScheme: colorScheme)
  }

  /// "Reposted by <name> [badge]" as composed `Text` so the inline verified
  /// badge keeps the surrounding typography and truncation.
  private var repostedByText: Text {
    let base = Text("Reposted by \(reposterName)")
    let hideBadges = appState?.preferencesManager.hideVerificationBadges ?? false
    if let badge = VerificationBadge.inlineText(for: reposterVerification, did: reposterDID, hideBadges: hideBadges) {
      return base + Text(verbatim: " ") + badge.font(.caption2)
    }
    return base
  }

  private var repostedByAccessibilityLabel: String {
    let hideBadges = appState?.preferencesManager.hideVerificationBadges ?? false
    if let kind = VerificationBadge.kind(for: reposterVerification, did: reposterDID, hideBadges: hideBadges) {
      return "Reposted by \(reposterName), \(kind.accessibilityLabel)"
    }
    return "Reposted by \(reposterName)"
  }
}

#Preview("Repost Header") {
  AsyncPreviewContent { appState in
    RepostHeaderPreviewLoader(appState: appState)
  }
}

private struct RepostHeaderPreviewLoader: View {
  let appState: AppState
  @State private var reposter: AppBskyActorDefs.ProfileViewBasic?

  var body: some View {
    Group {
      if let reposter {
        RepostHeaderView(
          reposter: reposter,
          path: .constant(NavigationPath())
        )
        .padding()
      } else {
        ProgressView("Loading…")
      }
    }
    .task {
      if let feedPost = await PreviewData.firstRepost(from: appState),
         case .appBskyFeedDefsReasonRepost(let reasonRepost) = feedPost.reason {
        reposter = reasonRepost.by
      }
    }
  }
}
