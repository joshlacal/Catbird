//
//  NotificationWidgetDesignSystem.swift
//  CatbirdNotificationWidget
//

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Spacing (4pt Grid)

/// 4pt widget spacing scale mirroring `Space` in the main app.
enum NotificationWidgetSpacing {
  static let hairline: CGFloat = 2
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 20
  static let xxl: CGFloat = 24
}

// MARK: - Corner Radius (Continuous)

/// Continuous corner radius scale mirroring `Radius` in the main app.
enum NotificationWidgetRadius: CGFloat, CaseIterable, Sendable {
  case xs = 4
  case sm = 8
  case md = 12
  case lg = 16

  var value: CGFloat { rawValue }

  var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: rawValue, style: .continuous)
  }
}

// MARK: - Typography (Dynamic Type Scaled)

/// Semantic typography roles for the notification widget, scaling with Dynamic Type
/// via `@ScaledMetric` and clamped cleanly for Home Screen and Lock Screen widgets.
enum NotificationWidgetTextRole: Sendable {
  case inlineHeadline
  case headerSmallCaps
  case heroCount
  case caption
  case timestamp
  case signedOut
  case circularIcon
  case circularCount
  case rectangularIcon
  case rectangularBody

  var baseSize: CGFloat {
    switch self {
    case .inlineHeadline: return 17
    case .headerSmallCaps: return 17
    case .heroCount: return 72
    case .caption: return 12
    case .timestamp: return 11
    case .signedOut: return 15
    case .circularIcon: return 20
    case .circularCount: return 24
    case .rectangularIcon: return 18
    case .rectangularBody: return 17
    }
  }

  var maxSize: CGFloat {
    switch self {
    case .inlineHeadline: return 21
    case .headerSmallCaps: return 20
    case .heroCount: return 80
    case .caption: return 15
    case .timestamp: return 14
    case .signedOut: return 18
    case .circularIcon: return 22
    case .circularCount: return 28
    case .rectangularIcon: return 20
    case .rectangularBody: return 20
    }
  }

  var relativeTextStyle: Font.TextStyle {
    switch self {
    case .inlineHeadline, .headerSmallCaps: return .headline
    case .heroCount: return .largeTitle
    case .caption: return .caption
    case .timestamp: return .caption2
    case .signedOut: return .subheadline
    case .circularIcon, .circularCount: return .title3
    case .rectangularIcon, .rectangularBody: return .body
    }
  }

  var weight: Font.Weight {
    switch self {
    case .inlineHeadline: return .semibold
    case .headerSmallCaps: return .heavy
    case .heroCount, .circularCount: return .bold
    case .signedOut: return .semibold
    case .caption, .timestamp, .circularIcon, .rectangularIcon, .rectangularBody: return .regular
    }
  }

  var design: Font.Design {
    switch self {
    case .inlineHeadline, .circularIcon, .rectangularIcon: return .default
    default: return .rounded
    }
  }

  var usesLowercaseSmallCaps: Bool {
    self == .headerSmallCaps
  }
}

private struct NotificationWidgetScaledFontModifier: ViewModifier {
  @ScaledMetric private var scaledSize: CGFloat
  let role: NotificationWidgetTextRole

  init(role: NotificationWidgetTextRole) {
    self._scaledSize = ScaledMetric(wrappedValue: role.baseSize, relativeTo: role.relativeTextStyle)
    self.role = role
  }

  func body(content: Content) -> some View {
    let base = Font.system(size: min(scaledSize, role.maxSize), weight: role.weight, design: role.design)
    content.font(role.usesLowercaseSmallCaps ? base.lowercaseSmallCaps() : base)
  }
}

extension View {
  func notificationWidgetFont(_ role: NotificationWidgetTextRole) -> some View {
    modifier(NotificationWidgetScaledFontModifier(role: role))
  }
}

// MARK: - Adaptive Surface Background

/// Theme-adaptive container surface for Home Screen notification widgets.
/// Avoids legacy `.*Material` and hardcoded black/white overlays, respecting Reduce Transparency.
struct NotificationWidgetSurfaceBackground: View {
  let accentColor: Color
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ZStack {
      Color(uiColor: .secondarySystemGroupedBackground)
      if !reduceTransparency {
        LinearGradient(
          colors: [
            accentColor.opacity(0.18),
            accentColor.opacity(0.06)
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
      ContainerRelativeShape()
        .strokeBorder(accentColor.opacity(reduceTransparency ? 0.35 : 0.20), lineWidth: 1)
    }
  }
}
#endif
