//
//  MediaBadgeLabel.swift
//  Catbird
//

import SwiftUI

// MARK: - Media Badge

enum AltTextBadgeMetrics {
  static func side(isLarge: Bool) -> CGFloat { isLarge ? 32 : 24 }
}

/// The small dark capsule drawn over the corner of post media ("ALT", "GIF").
/// Every media badge uses this so they share one size, font and background,
/// and all follow the "Larger alt text badges" accessibility setting.
struct MediaBadgeLabel: View {
  let text: String
  let isLarge: Bool

  var body: some View {
    Text(text)
      .appFont(isLarge ? AppTextRole.subheadline : AppTextRole.caption2)
      .fontWeight(.semibold)
      .foregroundStyle(.white)
      .frame(minWidth: AltTextBadgeMetrics.side(isLarge: isLarge))
      .padding(.horizontal, isLarge ? 5 : 3)
      .padding(.vertical, isLarge ? 4 : 2)
      .background(.black.opacity(0.65), in: Capsule())
  }
}
