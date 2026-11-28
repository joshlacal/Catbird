//
//  CatbirdSheetChrome.swift
//  Catbird
//
//  Standardized sheet chrome and Cancel/Done toolbar conventions so modal sheets share
//  themed surfaces, detents, drag indicators, corner radius, and toolbar placements.
//

import SwiftUI

private struct CatbirdSheetChromeModifier: ViewModifier {
  let detents: Set<PresentationDetent>
  let dragIndicator: Visibility
  let cornerRadius: Radius
  let usesGroupedBackground: Bool

  @Environment(\.catbirdTheme) private var theme

  private var backgroundColor: Color {
    theme.surface(usesGroupedBackground ? .grouped : .canvas)
  }

  func body(content: Content) -> some View {
    content
      .background(backgroundColor)
      .presentationDetents(detents)
      .presentationDragIndicator(dragIndicator)
      .presentationCornerRadius(cornerRadius.value)
      .presentationBackground(backgroundColor)
  }
}

private struct CatbirdSheetToolbarModifier: ViewModifier {
  let cancelTitle: LocalizedStringKey
  let onCancel: () -> Void
  let confirmTitle: LocalizedStringKey?
  let confirmDisabled: Bool
  let confirmLoading: Bool
  let onConfirm: (() -> Void)?

  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(cancelTitle, role: .cancel, action: onCancel)
      }
      if let confirmTitle, let onConfirm {
        ToolbarItem(placement: .confirmationAction) {
          if confirmLoading {
            ProgressView()
          } else {
            Button(confirmTitle, action: onConfirm)
              .disabled(confirmDisabled)
          }
        }
      }
    }
  }
}

extension View {
  /// Apply standardized Catbird sheet presentation chrome (theme-aware background, detents,
  /// drag indicator, and continuous corner radius).
  func catbirdSheetChrome(
    detents: Set<PresentationDetent> = [.large],
    dragIndicator: Visibility = .visible,
    cornerRadius: Radius = .xl,
    usesGroupedBackground: Bool = false
  ) -> some View {
    modifier(
      CatbirdSheetChromeModifier(
        detents: detents,
        dragIndicator: dragIndicator,
        cornerRadius: cornerRadius,
        usesGroupedBackground: usesGroupedBackground
      )
    )
  }

  /// Install canonical `.cancellationAction` (Cancel) and optional `.confirmationAction` (Done/Save)
  /// toolbar buttons on a modal sheet's navigation stack.
  func catbirdSheetToolbar(
    cancelTitle: LocalizedStringKey = "Cancel",
    onCancel: @escaping () -> Void,
    confirmTitle: LocalizedStringKey? = nil,
    confirmDisabled: Bool = false,
    confirmLoading: Bool = false,
    onConfirm: (() -> Void)? = nil
  ) -> some View {
    modifier(
      CatbirdSheetToolbarModifier(
        cancelTitle: cancelTitle,
        onCancel: onCancel,
        confirmTitle: confirmTitle,
        confirmDisabled: confirmDisabled,
        confirmLoading: confirmLoading,
        onConfirm: onConfirm
      )
    )
  }
}

#Preview("Sheet chrome") {
  NavigationStack {
    VStack(spacing: Space.md) {
      Text(verbatim: "Standardized Catbird Sheet")
        .appFont(AppTextRole.headline)
    }
    .padding(Space.screenMargin)
    .navigationTitle(Text(verbatim: "Sheet"))
    .catbirdSheetToolbar(onCancel: {}, confirmTitle: "Done", onConfirm: {})
  }
  .catbirdSheetChrome(detents: [.medium, .large])
}
