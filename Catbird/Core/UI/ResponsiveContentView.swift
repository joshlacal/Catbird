//
//  ResponsiveContentView.swift
//  Catbird
//
//  Created by Claude Code on 1/26/25.
//

import SwiftUI

// MARK: - Responsive Content Container

/// A responsive container that adapts content width based on screen size and size class
/// Provides optimal reading width on iPad while maintaining full width on iPhone
struct ResponsiveContentView<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  private let content: Content
  private let maxWidth: CGFloat?
  private let alignment: HorizontalAlignment
  
  init(
    maxWidth: CGFloat? = nil,
    alignment: HorizontalAlignment = .center,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.maxWidth = maxWidth
    self.alignment = alignment
  }
  
  var body: some View {
    HStack {
      if alignment == .center {
        Spacer(minLength: 0)
      }
      
      content
        .frame(maxWidth: effectiveMaxWidth)
      
      if alignment == .center {
        Spacer(minLength: 0)
      }
    }
  }
  
  private var effectiveMaxWidth: CGFloat? {
    // Use custom maxWidth if provided
    if let maxWidth = maxWidth {
      return maxWidth
    }
    
    // Default responsive behavior
    if horizontalSizeClass == .regular {
      // iPad or large iPhone in landscape
      return 600
    } else {
      // iPhone in portrait or compact width
      return .infinity
    }
  }
}

// MARK: - Device Detection Utilities

struct DeviceInfo {
  static let isIPad = UIDevice.current.userInterfaceIdiom == .pad
  static let isIPhone = UIDevice.current.userInterfaceIdiom == .phone
  
  static var screenWidth: CGFloat {
    UIScreen.main.bounds.width
  }
  
  static var screenHeight: CGFloat {
    UIScreen.main.bounds.height
  }
  
  /// Returns true if the device is likely to benefit from constrained content width
  static var shouldConstrainContentWidth: Bool {
    return isIPad || screenWidth > 768
  }
}

// MARK: - Responsive Grid Configuration

struct ResponsiveGridConfig {
  let columns: Int
  let spacing: CGFloat
  let itemAspectRatio: CGFloat?
  
  static func feedGrid(for screenWidth: CGFloat) -> ResponsiveGridConfig {
    switch screenWidth {
    case ..<320:
      return ResponsiveGridConfig(columns: 2, spacing: 12, itemAspectRatio: 1.0)
    case ..<375:
      return ResponsiveGridConfig(columns: 3, spacing: 14, itemAspectRatio: 1.0)
    case ..<768:
      return ResponsiveGridConfig(columns: 4, spacing: 16, itemAspectRatio: 1.0)
    case ..<1024:
      return ResponsiveGridConfig(columns: 5, spacing: 18, itemAspectRatio: 1.0)
    default:
      return ResponsiveGridConfig(columns: 6, spacing: 20, itemAspectRatio: 1.0)
    }
  }
  
  static func settingsGrid(for screenWidth: CGFloat) -> ResponsiveGridConfig {
    switch screenWidth {
    case ..<768:
      return ResponsiveGridConfig(columns: 1, spacing: 16, itemAspectRatio: nil)
    case ..<1024:
      return ResponsiveGridConfig(columns: 2, spacing: 20, itemAspectRatio: nil)
    default:
      return ResponsiveGridConfig(columns: 3, spacing: 24, itemAspectRatio: nil)
    }
  }
}

// MARK: - View Modifiers

extension View {
  /// Applies responsive content width constraints
  func responsiveContentWidth(
    maxWidth: CGFloat? = nil,
    alignment: HorizontalAlignment = .center
  ) -> some View {
    ResponsiveContentView(maxWidth: maxWidth, alignment: alignment) {
      self
    }
  }
  
  /// Applies device-specific padding
  func responsivePadding() -> some View {
    self.padding(.horizontal, DeviceInfo.isIPad ? 24 : 16)
  }
  
  /// Applies responsive frame constraints for main content areas
  func mainContentFrame() -> some View {
    self.responsiveContentWidth(maxWidth: DeviceInfo.shouldConstrainContentWidth ? 600 : nil)
  }
}

// MARK: - Responsive Adaptive Grid

struct ResponsiveAdaptiveGrid<Content: View>: View {
  private let config: ResponsiveGridConfig
  private let content: Content
  
  init(config: ResponsiveGridConfig, @ViewBuilder content: () -> Content) {
    self.config = config
    self.content = content()
  }
  
  var body: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: config.spacing), count: config.columns),
      spacing: config.spacing
    ) {
      content
    }
  }
}

// MARK: - Additional Modifiers for Common Cases

extension View {
  /// Applies responsive layout optimized for main app content (feeds, profiles, etc.)
  func responsiveAppContent() -> some View {
    self.responsiveContentWidth(maxWidth: DeviceInfo.isIPad ? 700 : nil)
  }
  
  /// Applies responsive layout optimized for reading content (articles, long text)
  func responsiveReadingContent() -> some View {
    self.responsiveContentWidth(maxWidth: DeviceInfo.isIPad ? 600 : nil)
  }
  
  /// Applies responsive layout optimized for settings and forms
  func responsiveFormContent() -> some View {
    self.responsiveContentWidth(maxWidth: DeviceInfo.isIPad ? 500 : nil)
  }
}

// MARK: - Preview

#Preview("Responsive Content") {
  VStack(spacing: 20) {
    Text("Regular Content")
      .frame(maxWidth: .infinity)
      .padding()
      .background(Color.blue.opacity(0.2))
    
    Text("Responsive Content")
      .responsiveContentWidth()
      .padding()
      .background(Color.green.opacity(0.2))
    
    Text("Custom Max Width")
      .responsiveContentWidth(maxWidth: 400)
      .padding()
      .background(Color.orange.opacity(0.2))
    
    Text("App Content")
      .responsiveAppContent()
      .padding()
      .background(Color.purple.opacity(0.2))
  }
  .padding()
}
