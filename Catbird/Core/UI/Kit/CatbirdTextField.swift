//
//  CatbirdTextField.swift
//  Catbird
//
//  Single-line text input and search field aligned with docs/brand/08-components/text-field.md.
//  Features continuous Radius.sm corners, CatbirdTheme surfaces/borders, animated focus ring,
//  inline semantic danger validation message, and >=44pt clear button hit target.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct CatbirdTextField: View {
  @Binding var text: String
  var prompt: String
  /// VoiceOver label; defaults to `prompt`.
  var label: String?
  var leadingSystemImage: String?
  var validationError: String?
  var isDisabled: Bool
  var isSecure: Bool
  var autocorrectionDisabled: Bool
  #if os(iOS)
  var keyboardType: UIKeyboardType
  var textContentType: UITextContentType?
  var autocapitalization: TextInputAutocapitalization?
  #endif
  var submitLabel: SubmitLabel
  var onSubmit: (() -> Void)?

  @FocusState private var isFocused: Bool
  @Environment(\.catbirdTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  private var increased: Bool { theme.isHighContrast || contrast == .increased }
  private var hasError: Bool { validationError != nil }

  #if os(iOS)
  init(
    text: Binding<String>,
    prompt: String,
    label: String? = nil,
    leadingSystemImage: String? = nil,
    validationError: String? = nil,
    isDisabled: Bool = false,
    isSecure: Bool = false,
    autocorrectionDisabled: Bool = false,
    keyboardType: UIKeyboardType = .default,
    textContentType: UITextContentType? = nil,
    autocapitalization: TextInputAutocapitalization? = nil,
    submitLabel: SubmitLabel = .done,
    onSubmit: (() -> Void)? = nil
  ) {
    self._text = text
    self.prompt = prompt
    self.label = label
    self.leadingSystemImage = leadingSystemImage
    self.validationError = validationError
    self.isDisabled = isDisabled
    self.isSecure = isSecure
    self.autocorrectionDisabled = autocorrectionDisabled
    self.keyboardType = keyboardType
    self.textContentType = textContentType
    self.autocapitalization = autocapitalization
    self.submitLabel = submitLabel
    self.onSubmit = onSubmit
  }
  #else
  init(
    text: Binding<String>,
    prompt: String,
    label: String? = nil,
    leadingSystemImage: String? = nil,
    validationError: String? = nil,
    isDisabled: Bool = false,
    isSecure: Bool = false,
    autocorrectionDisabled: Bool = false,
    submitLabel: SubmitLabel = .done,
    onSubmit: (() -> Void)? = nil
  ) {
    self._text = text
    self.prompt = prompt
    self.label = label
    self.leadingSystemImage = leadingSystemImage
    self.validationError = validationError
    self.isDisabled = isDisabled
    self.isSecure = isSecure
    self.autocorrectionDisabled = autocorrectionDisabled
    self.submitLabel = submitLabel
    self.onSubmit = onSubmit
  }
  #endif

  private var borderColor: Color {
    if hasError {
      return theme.semantic(.danger)
    }
    if isFocused {
      return theme.accentChrome
    }
    return theme.border(increased ? .prominent : .subtle)
  }

  private var borderWidth: CGFloat {
    (hasError || isFocused || increased) ? 1.5 : 1
  }

  private var leadingIconColor: Color {
    if hasError {
      return theme.semantic(.danger)
    }
    if isFocused && text.isEmpty {
      return theme.accentChrome
    }
    return theme.text(.secondary)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      HStack(spacing: Space.sm) {
        if let leadingSystemImage {
          Image(systemName: leadingSystemImage)
            .catbirdSymbol(.row)
            .foregroundStyle(leadingIconColor)
            .frame(minWidth: AvatarSize.xs)
            .accessibilityHidden(true)
        }

        inputField
          .appFont(AppTextRole.body)
          .foregroundStyle(theme.text(.primary))
          .focused($isFocused)
          .autocorrectionDisabled(autocorrectionDisabled)
          .modifier(platformInputModifier)
          .submitLabel(submitLabel)
          .onSubmit {
            self.onSubmit?()
          }

        if !text.isEmpty && !isDisabled {
          Button {
            Self.triggerClearHaptic()
            self.text = ""
            self.isFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
              .catbirdSymbol(.compact)
              .foregroundStyle(theme.text(.secondary))
              .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.trailing, -Space.md)
          .accessibilityLabel("Clear Text")
        }
      }
      .padding(.horizontal, Space.md)
      .frame(minHeight: ControlHeight.minHitTarget)
      .background(
        Radius.sm.shape
          .fill(theme.surface(isFocused ? .elevated : .card))
      )
      .overlay {
        Radius.sm.shape
          .strokeBorder(borderColor, lineWidth: borderWidth)
      }
      .overlay {
        if isFocused {
          Radius.sm.shape
            .stroke(
              (hasError ? theme.semantic(.danger) : theme.accentChrome).opacity(0.25),
              lineWidth: 2
            )
            .padding(-Space.hairline)
        }
      }
      .opacity(isDisabled ? 0.45 : 1)
      .disabled(isDisabled)
      .catbirdAnimation(MotionIntent.instant, value: isFocused)
      .catbirdAnimation(MotionIntent.instant, value: hasError)

      if let validationError {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
          Image(systemName: "exclamationmark.circle.fill")
            .catbirdSymbol(.inline)
            .accessibilityHidden(true)
          Text(validationError)
            .appFont(AppTextRole.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.semantic(.danger))
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .combine)
      }
    }
  }

  @ViewBuilder private var inputField: some View {
    let fieldLabel = label ?? prompt
    if isSecure {
      SecureField(fieldLabel, text: $text, prompt: Text(prompt))
    } else {
      TextField(fieldLabel, text: $text, prompt: Text(prompt))
    }
  }

  private var platformInputModifier: PlatformTextFieldInputModifier {
    #if os(iOS)
    return PlatformTextFieldInputModifier(
      keyboardType: keyboardType,
      textContentType: textContentType,
      autocapitalization: autocapitalization
    )
    #else
    return PlatformTextFieldInputModifier()
    #endif
  }

  private static func triggerClearHaptic() {
    #if os(iOS)
    PlatformHaptics.light()
    #endif
  }
}

private struct PlatformTextFieldInputModifier: ViewModifier {
  #if os(iOS)
  let keyboardType: UIKeyboardType
  let textContentType: UITextContentType?
  let autocapitalization: TextInputAutocapitalization?
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .keyboardType(keyboardType)
      .textContentType(textContentType)
      .textInputAutocapitalization(autocapitalization)
    #else
    content
      .textFieldStyle(.plain)
    #endif
  }
}

/// Non-native search field primitive for inline search contexts (composers, pickers, sheets).
/// For root navigation lists, prefer native SwiftUI `.searchable(...)`.
struct CatbirdSearchField: View {
  @Binding var text: String
  var prompt: String = "Search"
  var isDisabled: Bool = false
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?

  var body: some View {
    HStack(spacing: Space.sm) {
      CatbirdTextField(
        text: $text,
        prompt: prompt,
        leadingSystemImage: "magnifyingglass",
        isDisabled: isDisabled,
        autocorrectionDisabled: true,
        submitLabel: .search,
        onSubmit: onSubmit
      )
      if let onCancel, !text.isEmpty {
        Button("Cancel", action: onCancel)
          .buttonStyle(.catbird(.quiet, size: .sm))
      }
    }
  }
}

#Preview("Text fields") {
  VStack(spacing: Space.md) {
    CatbirdTextField(
      text: .constant(""),
      prompt: "Handle or email",
      leadingSystemImage: "at"
    )
    CatbirdTextField(
      text: .constant("alice.bsky.social"),
      prompt: "Handle",
      leadingSystemImage: "at",
      validationError: "Couldn't resolve that handle."
    )
    CatbirdSearchField(text: .constant("catbird"), prompt: "Search feeds", onCancel: {})
  }
  .padding(Space.screenMargin)
}
