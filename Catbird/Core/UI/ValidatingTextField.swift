import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A text field that displays validation errors.
/// Thin source-compatible wrapper backed by the Kit's `CatbirdTextField`.
struct ValidatingTextField: View {
  @Binding var text: String
  var prompt: String
  var icon: String
  /// Name VoiceOver reads for the field; defaults to the placeholder.
  var label: String?
  var validationError: String?
  var isDisabled: Bool
  #if os(iOS)
  var keyboardType: UIKeyboardType = .default
  var textContentType: UITextContentType?
  #endif
  var submitLabel: SubmitLabel = .done
  var onSubmit: (() -> Void)?

  var body: some View {
    #if os(iOS)
    CatbirdTextField(
      text: $text,
      prompt: prompt,
      label: label,
      leadingSystemImage: icon,
      validationError: validationError,
      isDisabled: isDisabled,
      autocorrectionDisabled: true,
      keyboardType: keyboardType,
      textContentType: textContentType,
      autocapitalization: .never,
      submitLabel: submitLabel,
      onSubmit: onSubmit
    )
    #else
    CatbirdTextField(
      text: $text,
      prompt: prompt,
      label: label,
      leadingSystemImage: icon,
      validationError: validationError,
      isDisabled: isDisabled,
      autocorrectionDisabled: true,
      submitLabel: submitLabel,
      onSubmit: onSubmit
    )
    #endif
  }
}

#Preview {
  AsyncPreviewContent { _ in
    VStack(spacing: Space.md) {
      ValidatingTextField(
        text: .constant("test"),
        prompt: "Enter value",
        icon: "envelope",
        validationError: nil,
        isDisabled: false
      )

      ValidatingTextField(
        text: .constant(""),
        prompt: "Enter value",
        icon: "envelope",
        validationError: "This field is required",
        isDisabled: false
      )

      ValidatingTextField(
        text: .constant("test"),
        prompt: "Enter value",
        icon: "envelope",
        validationError: nil,
        isDisabled: true
      )
    }
    .padding(Space.screenMargin)
  }
}
