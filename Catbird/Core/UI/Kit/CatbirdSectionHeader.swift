//
//  CatbirdSectionHeader.swift
//  Catbird
//
//  Consistent section heading with optional subtitle and trailing action.
//

import SwiftUI

enum CatbirdSectionHeaderStyle: Sendable {
  /// Standard list/card group heading (`.headline`).
  case standard
  /// Prominent discovery/feed section heading (`.title3`, semibold).
  case prominent

  var textRole: AppTextRole {
    switch self {
    case .standard: return .headline
    case .prominent: return .title3.weight(.semibold)
    }
  }
}

struct CatbirdSectionHeader<Trailing: View>: View {
  let title: Text
  let subtitle: Text?
  var style: CatbirdSectionHeaderStyle
  @ViewBuilder var trailing: () -> Trailing

  @Environment(\.catbirdTheme) private var theme

  init(
    _ title: LocalizedStringKey,
    subtitle: LocalizedStringKey? = nil,
    style: CatbirdSectionHeaderStyle = .standard,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.title = Text(title)
    self.subtitle = subtitle.map { Text($0) }
    self.style = style
    self.trailing = trailing
  }

  init(
    title: Text,
    subtitle: Text? = nil,
    style: CatbirdSectionHeaderStyle = .standard,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.style = style
    self.trailing = trailing
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: Space.hairline) {
        title
          .appFont(style.textRole)
          .foregroundStyle(theme.text(.primary))
          .accessibilityAddTraits(.isHeader)
        if let subtitle {
          subtitle
            .appFont(AppTextRole.footnote)
            .foregroundStyle(theme.text(.secondary))
        }
      }
      Spacer(minLength: Space.sm)
      trailing()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension CatbirdSectionHeader where Trailing == EmptyView {
  init(
    _ title: LocalizedStringKey,
    subtitle: LocalizedStringKey? = nil,
    style: CatbirdSectionHeaderStyle = .standard
  ) {
    self.init(title, subtitle: subtitle, style: style) {
      EmptyView()
    }
  }

  init(
    title: Text,
    subtitle: Text? = nil,
    style: CatbirdSectionHeaderStyle = .standard
  ) {
    self.init(title: title, subtitle: subtitle, style: style) {
      EmptyView()
    }
  }
}

extension CatbirdSectionHeader where Trailing == CatbirdSectionHeaderAction {
  init(
    _ title: LocalizedStringKey,
    subtitle: LocalizedStringKey? = nil,
    style: CatbirdSectionHeaderStyle = .standard,
    actionTitle: LocalizedStringKey,
    action: @escaping () -> Void
  ) {
    self.init(title, subtitle: subtitle, style: style) {
      CatbirdSectionHeaderAction(title: Text(actionTitle), action: action)
    }
  }
}

struct CatbirdSectionHeaderAction: View {
  let title: Text
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      title
    }
    .buttonStyle(.catbird(.quiet, size: .sm))
  }
}

#Preview("Section headers") {
  VStack(spacing: Space.lg) {
    CatbirdSectionHeader("Trending Feeds", subtitle: "Updated hourly", style: .prominent, actionTitle: "See All") {}
    CatbirdSectionHeader("Recent Searches")
  }
  .padding(Space.screenMargin)
}
