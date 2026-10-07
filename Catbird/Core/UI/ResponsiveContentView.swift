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
    #if os(macOS)
    return 700
    #else
    if horizontalSizeClass == .regular {
      // iPad or large iPhone in landscape
      return 600
    } else {
      // iPhone in portrait or compact width
      return .infinity
    }
    #endif
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
  
  /// Applies wider horizontal padding when the scene has regular width
  func responsivePadding() -> some View {
    modifier(SizeClassHorizontalPadding(regular: 24, compact: 16))
  }
  
  /// Applies responsive frame constraints for main content areas
  func mainContentFrame() -> some View {
    #if os(macOS)
    self.responsiveContentWidth(maxWidth: 700)
    #else
    modifier(SizeClassContentWidth(regularMaxWidth: 600))
    #endif
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
    modifier(SizeClassContentWidth(regularMaxWidth: 700))
  }
  
  /// Applies responsive layout optimized for reading content (articles, long text)
  func responsiveReadingContent() -> some View {
    modifier(SizeClassContentWidth(regularMaxWidth: 600))
  }
  
  /// Applies responsive layout optimized for settings and forms
  func responsiveFormContent() -> some View {
    modifier(SizeClassContentWidth(regularMaxWidth: 500))
  }
}

// MARK: - Size Class Modifiers

/// Caps content width in a regular-width scene and leaves it full width in a
/// compact one. Reads the size class where it is applied, so the cap follows
/// the scene as it resizes (iPad Split View, an iPhone Duo folding or unfolding).
private struct SizeClassContentWidth: ViewModifier {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let regularMaxWidth: CGFloat

  func body(content: Content) -> some View {
    content.responsiveContentWidth(maxWidth: horizontalSizeClass == .regular ? regularMaxWidth : nil)
  }
}

private struct SizeClassHorizontalPadding: ViewModifier {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let regular: CGFloat
  let compact: CGFloat

  func body(content: Content) -> some View {
    content.padding(.horizontal, horizontalSizeClass == .regular ? regular : compact)
  }
}

// MARK: - Preview

#Preview("Responsive Content") {
  VStack(spacing: 20) {
    Text("Regular Content")
      .frame(maxWidth: .infinity)
      .padding()
      .background { Color.blue.opacity(0.2) }
    
    Text("Responsive Content")
      .responsiveContentWidth()
      .padding()
      .background { Color.green.opacity(0.2) }
    
    Text("Custom Max Width")
      .responsiveContentWidth(maxWidth: 400)
      .padding()
      .background { Color.orange.opacity(0.2) }
    
    Text("App Content")
      .responsiveAppContent()
      .padding()
      .background { Color.purple.opacity(0.2) }
  }
  .padding()
}
