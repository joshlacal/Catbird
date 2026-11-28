//
//  CatbirdCatalogProfiles.swift
//  Catbird
//
//  Canonical offline visual QA surfaces (`CatbirdCatalogSurface`) and the
//  6 orthogonal trap profiles (`CatbirdTrapProfile`) tailored to Catbird's
//  real theme, accent, font, Dynamic Type, Liquid Glass, and resizability axes.
//

#if DEBUG
import CoreGraphics
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
  /// Posted when `blue.catbird://catalog?...` arrives while `-CatbirdCatalog` is active.
  static let catbirdCatalogRouteChanged = Notification.Name("blue.catbird.catalogRouteChanged")
}

// MARK: - Surfaces

/// Canonical visual QA surfaces reachable offline via `-CatbirdCatalog <surface>`.
enum CatbirdCatalogSurface: String, CaseIterable, Identifiable, Sendable, Hashable {
  case kit
  case feed
  case thread
  case profile
  case search
  case chat
  case composer
  case settings
  case onboarding
  case askCatbird = "ask-catbird"
  case notifications
  case widgets

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .kit: return "Kit Gallery"
    case .feed: return "Home Feed"
    case .thread: return "Thread Detail"
    case .profile: return "Profile"
    case .search: return "Search & Discovery"
    case .chat: return "Messages & E2EE"
    case .composer: return "Post Composer"
    case .settings: return "Settings"
    case .onboarding: return "Welcome & Login"
    case .askCatbird: return "Ask Catbird"
    case .notifications: return "Notifications"
    case .widgets: return "Widgets"
    }
  }

  static func parse(_ raw: String) -> CatbirdCatalogSurface? {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "askcatbird" { return .askCatbird }
    return CatbirdCatalogSurface(rawValue: normalized)
  }
}

// MARK: - Orthogonal Trap Profiles

/// Six orthogonal visual regression profiles tailored to Catbird's real theme,
/// accent, font, Dynamic Type, Liquid Glass, and resizability axes.
enum CatbirdTrapProfile: String, CaseIterable, Identifiable, Sendable, Hashable {
  case baselineLight = "baseline-light"
  case dimAccentTrap = "dim-accent-trap"
  case oledFontTrap = "oled-font-trap"
  case a11yAX3Narrow = "a11y-ax3-narrow"
  case glassReduceTransparency = "glass-reduce-transparency"
  case resizabilityWideRTL = "resizability-wide-rtl"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .baselineLight: return "Baseline Light"
    case .dimAccentTrap: return "Dim + Sunrise Accent Trap"
    case .oledFontTrap: return "True Black + Monospaced Font Trap"
    case .a11yAX3Narrow: return "AX3 + Narrow SE"
    case .glassReduceTransparency: return "Dim + Reduce Transparency"
    case .resizabilityWideRTL: return "Wide + RTL + Asymmetric Insets"
    }
  }

  var theme: String {
    switch self {
    case .baselineLight, .a11yAX3Narrow, .resizabilityWideRTL: return "light"
    case .dimAccentTrap, .oledFontTrap, .glassReduceTransparency: return "dark"
    }
  }

  var darkThemeMode: String { self == .oledFontTrap ? "black" : "dim" }

  var accentColor: String {
    switch self {
    case .dimAccentTrap: return AccentColorOption.sunrise.rawValue
    case .oledFontTrap: return AccentColorOption.lavender.rawValue
    default: return AccentColorOption.catbird.rawValue
    }
  }

  var fontStyle: String { self == .oledFontTrap ? "monospaced" : "system" }
  var fontSize: String { self == .oledFontTrap ? "large" : "default" }
  var lineSpacing: String { self == .oledFontTrap ? "tight" : "normal" }
  var dynamicTypeSize: DynamicTypeSize { self == .a11yAX3Narrow ? .accessibility3 : .large }
  var boldText: Bool { self == .a11yAX3Narrow }
  var reduceTransparency: Bool { self == .glassReduceTransparency }
  var reduceMotion: Bool { self == .glassReduceTransparency }
  var increaseContrast: Bool { self == .a11yAX3Narrow }
  var layoutDirection: LayoutDirection { self == .resizabilityWideRTL ? .rightToLeft : .leftToRight }

  var viewportSize: CGSize {
    switch self {
    case .a11yAX3Narrow: return CGSize(width: 375, height: 667)
    case .resizabilityWideRTL: return CGSize(width: 744, height: 1133)
    default: return CGSize(width: 402, height: 874)
    }
  }

  #if os(iOS)
  var uiContentSizeCategory: UIContentSizeCategory {
    self == .a11yAX3Narrow ? .accessibilityExtraLarge : .large
  }

  var uiSafeAreaInsets: UIEdgeInsets {
    self == .resizabilityWideRTL ? UIEdgeInsets(top: 13, left: 31, bottom: 47, right: 7) : .zero
  }
  #endif
}
#endif
