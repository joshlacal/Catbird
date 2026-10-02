//
//  FlexibleHeaderGeometry.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/27/25.
//

/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
View modifiers that stretch a view in a scroll view when a person scrolls beyond the top bounds.
*/

import SwiftUI

@Observable private class FlexibleHeaderGeometry {
    var offset: CGFloat = 0
}

/// A view modifer that stretches content when the containing geometry offset changes.
private struct FlexibleHeaderContentModifier: ViewModifier {
    @Environment(FlexibleHeaderGeometry.self) private var geometry

    var baseHeight: CGFloat = 200

    func body(content: Content) -> some View {
        let height = baseHeight - geometry.offset
        content
            .frame(height: height)
            .padding(.bottom, geometry.offset)
            .offset(y: geometry.offset)
    }
}

/// A view modifier that tracks scroll view geometry to stretch a view with ``FlexibleHeaderContentModifier``.
private struct FlexibleHeaderScrollViewModifier: ViewModifier {
    @State private var geometry = FlexibleHeaderGeometry()

    init() {}

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(geometry.contentOffset.y + geometry.contentInsets.top, 0)
            } action: { _, offset in
                geometry.offset = offset
            }
            .environment(geometry)
    }
}

// MARK: - View Extensions

extension ScrollView {
    /// A function that returns a view after it applies `FlexibleHeaderScrollViewModifier` to it.
    @MainActor func flexibleHeaderScrollView() -> some View {
        modifier(FlexibleHeaderScrollViewModifier())
    }
}

extension View {
    /// A function that returns a view after it applies `FlexibleHeaderContentModifier` to it.
    func flexibleHeaderContent(height: CGFloat = 200) -> some View {
        modifier(FlexibleHeaderContentModifier(baseHeight: height))
    }
}

/// Clips a banner header to a uniform rounded rectangle whose radius matches
/// the concentric radius of the banner's top corners against its container.
/// The zero default inset keeps banners full-bleed while preserving a minimum
/// corner radius on platforms that cannot resolve concentric geometry.
struct ConcentricBannerClip: ViewModifier {
  var horizontalInset: CGFloat = 0
  var minimumCornerRadius: CGFloat = 16

  @State private var resolvedTopRadius: CGFloat?

  init(horizontalInset: CGFloat = 0, minimumCornerRadius: CGFloat = 16) {
    self.horizontalInset = horizontalInset
    self.minimumCornerRadius = minimumCornerRadius
  }

  private var cornerRadius: CGFloat {
    max(resolvedTopRadius ?? 0, minimumCornerRadius)
  }

  func body(content: Content) -> some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .onGeometryChange(for: CGFloat.self) { proxy in
        #if compiler(>=6.4)
        if #available(anyAppleOS 27.0, *),
          let radii = proxy.concentricCornerRadii
        {
          return max(radii.topLeading, radii.topTrailing)
        }
        #endif
        return 0
      } action: { topRadius in
        if topRadius > 0 {
          resolvedTopRadius = topRadius
        }
      }
      .padding(.horizontal, horizontalInset)
  }
}
