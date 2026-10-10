//
//  ProfileBannerHeader.swift
//  Catbird
//
//  The profile screen's stretchy banner: image (or gradient fallback),
//  concentric-corner clip, and flexible-header pull-to-zoom.
//

import NukeUI
import Petrel
import SwiftUI

/// The banner at the top of a profile screen.
///
/// Owns its full treatment: the image is pinned to the proposed frame and
/// cropped, and the concentric clip is applied inside the flexible-header
/// modifier so the mask stretches and stays pinned during pull-to-zoom.
///
/// Pass the profile's DID and labels so the moderation policy can decide the
/// banner. A banner the policy blurs renders a neutral placeholder and is never
/// downloaded.
struct ProfileBannerHeader: View {
  let bannerURL: URL?
  let did: String?
  let labels: [ComAtprotoLabelDefs.Label]?

  @Environment(\.moderationPolicy) private var moderationPolicy
  @Environment(\.displayScale) private var displayScale

  init(bannerURL: URL?, did: String? = nil, labels: [ComAtprotoLabelDefs.Label]? = nil) {
    self.bannerURL = bannerURL
    self.did = did
    self.labels = labels
  }

  var body: some View {
    let isConcealed = moderationPolicy.concealsBanner(did: did, labels: labels)
    bannerImage(isConcealed: isConcealed)
      .contentShape(Rectangle())
      .accessibilityLabel(isConcealed ? "Profile banner hidden" : "Profile banner")
      .modifier(ConcentricBannerClip())
      .flexibleHeaderContent()
  }

  @ViewBuilder
  private func bannerImage(isConcealed: Bool) -> some View {
    ZStack(alignment: .center) {
      if isConcealed {
        concealedPlaceholder
      } else if let bannerURL {
        LazyImage(request: ImageRequestFactory.image(bannerURL, pointSize: CGSize(width: 800, height: 200), scale: displayScale)) { state in
          if let image = state.image {
            Color.clear
              .overlay {
                image
                  .resizable()
                  .aspectRatio(contentMode: .fill)
              }
              .overlay {
                Color.black.opacity(0.15)
              }
              .clipped()
          } else if state.error != nil {
            fallbackGradient
          } else {
            fallbackGradient
              .overlay(ProgressView().tint(.white))
          }
        }
      } else {
        fallbackGradient
      }
    }
    .clipped()
  }

  private var fallbackGradient: some View {
    Rectangle()
      .fill(Color.accentColor.opacity(0.25))
  }

  /// Shown in place of a banner the moderation policy blurs.
  private var concealedPlaceholder: some View {
    Rectangle()
      .fill(Color.gray.opacity(0.2))
      .overlay {
        Image(systemName: "eye.slash.fill")
          .font(.title2)
          .foregroundStyle(Color.secondary.opacity(0.5))
      }
  }
}
