//
//  ProfileBannerHeader.swift
//  Catbird
//
//  The profile screen's stretchy banner: image (or gradient fallback),
//  concentric-corner clip, and flexible-header pull-to-zoom.
//

import NukeUI
import SwiftUI

/// The banner at the top of a profile screen.
///
/// Owns its full treatment: the image is pinned to the proposed frame and
/// cropped, and the concentric clip is applied inside the flexible-header
/// modifier so the mask stretches and stays pinned during pull-to-zoom.
struct ProfileBannerHeader: View {
  let bannerURL: URL?

  var body: some View {
    bannerImage
      .contentShape(Rectangle())
      .accessibilityLabel("Profile banner")
      .modifier(ConcentricBannerClip())
      .flexibleHeaderContent()
  }

  @ViewBuilder
  private var bannerImage: some View {
    ZStack(alignment: .center) {
      if let bannerURL {
        LazyImage(url: bannerURL) { state in
          if let image = state.image {
            Color.clear
              .overlay {
                image
                  .resizable()
                  .aspectRatio(contentMode: .fill)
              }
              .overlay {
                Color(white: 0, opacity: 0.15)
                  .blendMode(SwiftUI.BlendMode.overlay)
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
}
