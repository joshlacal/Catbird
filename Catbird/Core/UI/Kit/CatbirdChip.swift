//
//  CatbirdChip.swift
//  Catbird
//
//  Capsule tonal chip backed by `@Environment(\.catbirdTheme)`.
//  Accent parts use `.tint`, so `.tint(_:)` re-tints a chip. Selected labels use `theme.onAccent`
//  for WCAG AA contrast. Interactive chips get a real 44pt hit target inside the Button label.
//

import SwiftUI

enum CatbirdChipSize: CaseIterable, Sendable {
  case sm, md

  var height: CGFloat { self == .sm ? ControlHeight.sm - Space.xs : ControlHeight.sm }
  var textRole: AppTextRole { self == .sm ? .caption.weight(.semibold) : .footnote.weight(.semibold) }
}

struct CatbirdChip: View {
  let title: Text
  var systemImage: String?
  var isSelected = false
  var size: CatbirdChipSize = .md
  var haptic = true
  var action: (() -> Void)?

  @Environment(\.catbirdTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  private var increased: Bool { theme.isHighContrast || contrast == .increased }

  init(
    title: LocalizedStringKey,
    systemImage: String? = nil,
    isSelected: Bool = false,
    size: CatbirdChipSize = .md,
    haptic: Bool = true,
    action: (() -> Void)? = nil
  ) {
    self.init(
      title: Text(title),
      systemImage: systemImage,
      isSelected: isSelected,
      size: size,
      haptic: haptic,
      action: action
    )
  }

  init(
    title: Text,
    systemImage: String? = nil,
    isSelected: Bool = false,
    size: CatbirdChipSize = .md,
    haptic: Bool = true,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isSelected = isSelected
    self.size = size
    self.haptic = haptic
    self.action = action
  }

  var body: some View {
    if let action {
      Button {
        if self.haptic {
          Self.triggerSelectionHaptic()
        }
        action()
      } label: {
        // The hit target must live inside the label: a Button only hit-tests its label.
        chip
          .frame(minHeight: ControlHeight.minHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    } else {
      chip
    }
  }

  private var chip: some View {
    HStack(spacing: Space.xs) {
      if let systemImage {
        Image(systemName: systemImage).accessibilityHidden(true)
      }
      title.lineLimit(1)
    }
    .appFont(size.textRole)
    .foregroundStyle(isSelected ? AnyShapeStyle(theme.onAccent) : AnyShapeStyle(TintShapeStyle()))
    .padding(.horizontal, size == .sm ? Space.sm : Space.md)
    .frame(minHeight: size.height)
    .background(
      Capsule(style: .continuous)
        .fill(
          isSelected
            ? AnyShapeStyle(TintShapeStyle())
            : AnyShapeStyle(TintShapeStyle().opacity(increased ? 0.22 : 0.14))
        )
    )
    .overlay {
      if increased && !isSelected {
        Capsule(style: .continuous)
          .strokeBorder(TintShapeStyle().opacity(0.45), lineWidth: 1)
      }
    }
    .catbirdAnimation(MotionIntent.instant, value: isSelected)
  }

  private static func triggerSelectionHaptic() {
    #if os(iOS)
    PlatformHaptics.selection()
    #endif
  }
}

#Preview("Chips") {
  HStack {
    CatbirdChip(title: Text(verbatim: "Following"), isSelected: true, action: {})
    CatbirdChip(title: Text(verbatim: "Popular"), systemImage: "flame", action: {})
    CatbirdChip(title: Text(verbatim: "Small"), size: .sm)
  }
  .padding(Space.screenMargin)
}
