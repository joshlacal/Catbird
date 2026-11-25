//
//  CatbirdChip.swift
//  Catbird
//
//  Capsule tonal chip. Accent parts use `.tint`, so `.tint(_:)` re-tints a chip.
//  Interactive chips get a real 44pt hit target (inside the Button label).
//

import SwiftUI

enum CatbirdChipSize: CaseIterable, Sendable {
  case sm, md

  var height: CGFloat { self == .sm ? ControlHeight.sm - 4 : ControlHeight.sm }
  var textRole: AppTextRole { self == .sm ? .caption : .footnote }
}

struct CatbirdChip: View {
  let title: Text
  var systemImage: String?
  var isSelected = false
  var size: CatbirdChipSize = .md
  var action: (() -> Void)?

  @Environment(\.colorSchemeContrast) private var contrast

  init(
    title: LocalizedStringKey, systemImage: String? = nil, isSelected: Bool = false,
    size: CatbirdChipSize = .md, action: (() -> Void)? = nil
  ) {
    self.init(
      title: Text(title), systemImage: systemImage, isSelected: isSelected, size: size,
      action: action)
  }

  init(
    title: Text, systemImage: String? = nil, isSelected: Bool = false,
    size: CatbirdChipSize = .md, action: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isSelected = isSelected
    self.size = size
    self.action = action
  }

  var body: some View {
    if let action {
      Button(action: action) {
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
    .fontWeight(.semibold)
    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(TintShapeStyle()))
    .padding(.horizontal, size == .sm ? Space.sm : Space.md)
    .frame(minHeight: size.height)
    .background(
      Capsule(style: .continuous)
        .fill(
          isSelected
            ? AnyShapeStyle(TintShapeStyle())
            : AnyShapeStyle(TintShapeStyle().opacity(contrast == .increased ? 0.22 : 0.14)))
    )
    .catbirdAnimation(Motion.instant, value: isSelected)
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
