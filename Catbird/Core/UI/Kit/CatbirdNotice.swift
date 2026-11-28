//
//  CatbirdNotice.swift
//  Catbird
//
//  Tinted inline banner: icon, optional title, message, optional action.
//  Colors resolve from `@Environment(\.catbirdTheme)` via `CatbirdTone`.
//

import SwiftUI

struct CatbirdNotice: View {
  var tone: CatbirdTone
  let title: Text?
  let message: Text
  let actionTitle: Text?
  var action: (() -> Void)?

  @Environment(\.catbirdTheme) private var theme

  init(
    tone: CatbirdTone = .info, title: LocalizedStringKey? = nil, message: LocalizedStringKey,
    actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil
  ) {
    self.init(
      tone: tone, title: title.map { Text($0) }, message: Text(message),
      actionTitle: actionTitle.map { Text($0) }, action: action)
  }

  init(
    tone: CatbirdTone = .info, title: Text? = nil, message: Text, actionTitle: Text? = nil,
    action: (() -> Void)? = nil
  ) {
    self.tone = tone
    self.title = title
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    let toneColor = tone.color(in: theme)
    HStack(alignment: .top, spacing: Space.md) {
      Image(systemName: tone.systemImage)
        .catbirdSymbol(.row, weight: .semibold)
        .foregroundStyle(toneColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Space.xs) {
        if let title {
          title
            .appFont(AppTextRole.subheadline.weight(.semibold))
            .foregroundStyle(theme.text(.primary))
        }
        message
          .appFont(AppTextRole.footnote)
          .foregroundStyle(title == nil ? theme.text(.primary) : theme.text(.secondary))
          .fixedSize(horizontal: false, vertical: true)
        if let actionTitle, let action {
          Button(action: action) { actionTitle }
            .buttonStyle(.catbird(.quiet, size: .sm))
            .tint(toneColor)
            .padding(.leading, -Space.md)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .catbirdCard(.notice(tone))
    .accessibilityElement(children: .contain)
  }
}

#Preview("Notices") {
  VStack(spacing: Space.md) {
    CatbirdNotice(
      tone: .info, title: Text(verbatim: "Heads up"), message: Text(verbatim: "This is informational."))
    CatbirdNotice(
      tone: .warning, message: Text(verbatim: "Careful with this."),
      actionTitle: Text(verbatim: "Review"), action: {})
    CatbirdNotice(
      tone: .error, title: Text(verbatim: "Something failed"), message: Text(verbatim: "Try again."))
    CatbirdNotice(tone: .success, message: Text(verbatim: "Saved."))
  }
  .padding(Space.screenMargin)
}
