//
//  FeedsLaunchpadGlass.swift
//  Catbird
//
//  Per-element Liquid Glass for the drawer launchpad. Exactly three element
//  groups carry glass (selected feed cell, big default-feed button, header
//  action buttons); everything else sits bare on the drawer's backdrop blur.
//  Pre-iOS-26 falls back to ultraThinMaterial chips.
//

#if os(iOS)
import SwiftUI

struct LaunchpadGlassChip: ViewModifier {
  let cornerRadius: CGFloat
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if !isEnabled {
      content
    } else if #available(iOS 26.0, *) {
      content.glassEffect(
        .regular.interactive(),
        in: .rect(cornerRadius: cornerRadius, style: .continuous)
      )
    } else {
      content.background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.ultraThinMaterial)
      )
    }
  }
}

struct LaunchpadGlassCircle: ViewModifier {
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if !isEnabled {
      content
    } else if #available(iOS 26.0, *) {
      content.glassEffect(.regular.interactive(), in: .circle)
    } else {
      content.background(Circle().fill(.ultraThinMaterial))
    }
  }
}

/// Selection state for launchpad feed cells: the selected cell carries
/// interactive glass with a stable glassEffectID so selection changes morph
/// the glass between cells. The drop-target state shows an accent ring +
/// scale instead of the legacy accent fill.
struct LaunchpadSelectionGlass: ViewModifier {
  let isSelected: Bool
  let isDropTarget: Bool
  let cornerRadius: CGFloat
  let namespace: Namespace.ID
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      selectionSurface(content)
        .overlay {
          if isDropTarget {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
              .stroke(Color.accentColor, lineWidth: 2)
          }
        }
        .scaleEffect(isDropTarget ? 1.04 : 1.0)
        .animation(.spring(duration: 0.25), value: isDropTarget)
    } else {
      content
    }
  }

  @ViewBuilder
  private func selectionSurface(_ content: Content) -> some View {
    if #available(iOS 26.0, *) {
      if isSelected {
        content
          .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: cornerRadius, style: .continuous)
          )
          .glassEffectID("selected-feed", in: namespace)
      } else {
        content
      }
    } else if isSelected {
      content.background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.ultraThinMaterial)
      )
    } else {
      content
    }
  }
}
#endif

#if !os(iOS)
import SwiftUI

struct LaunchpadGlassChip: ViewModifier {
  let cornerRadius: CGFloat
  let isEnabled: Bool
  func body(content: Content) -> some View { content }
}

struct LaunchpadGlassCircle: ViewModifier {
  let isEnabled: Bool
  func body(content: Content) -> some View { content }
}

struct LaunchpadSelectionGlass: ViewModifier {
  let isSelected: Bool
  let isDropTarget: Bool
  let cornerRadius: CGFloat
  let namespace: Namespace.ID
  let isEnabled: Bool
  func body(content: Content) -> some View { content }
}
#endif
