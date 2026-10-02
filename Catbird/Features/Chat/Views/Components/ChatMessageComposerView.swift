import GameController
import SwiftUI

/// Preview of a Bluesky post staged in the DM composer (share-to-chat).
/// Only used for display; the wire embed is the post's strong ref.
struct ChatSharedPostPreview: Equatable {
  let authorDisplayName: String?
  let authorHandle: String?
  let text: String?
}

/// Message composer for Bluesky DM conversations: a growing text field, an
/// optional staged post preview, and a send button.
struct ChatMessageComposerView: View {
  @Binding var text: String
  @Binding var attachedPost: ChatSharedPostPreview?

  let conversationId: String
  let onSend: (String, ChatSharedPostPreview?) -> Void
  var clearsDraftOnSend: Bool = true
  var onTypingChanged: ((Bool) -> Void)? = nil
  var dismissKeyboardOnSend: Bool = false
  var placeholderText: String = "Message"

  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var isTextFieldFocused: Bool

  private var composerTint: Color {
    Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06)
  }

  private var composerStroke: Color {
    Color.primary.opacity(colorScheme == .dark ? 0.3 : 0.12)
  }

  private var composerCornerRadius: CGFloat {
    DesignTokens.Size.radiusXXL + DesignTokens.Spacing.sm
  }

  private var accessibilityConvoIdPrefix: String {
    let filtered = conversationId.unicodeScalars.compactMap { scalar -> Character? in
      guard scalar.isASCII else { return nil }
      let v = scalar.value
      let isAlphaNum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
      return isAlphaNum ? Character(scalar) : nil
    }
    let prefix = String(filtered.prefix(12))
    return prefix.isEmpty ? "unknown" : prefix
  }

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedPost != nil
  }

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      if let post = attachedPost {
        postPreviewSection(post)
      }

      composerContent
        .modifier(
          ComposerGlassPanelModifier(
            tint: composerTint,
            strokeColor: composerStroke,
            cornerRadius: composerCornerRadius
          )
        )
        .accessibilityIdentifier("chat.composer.\(accessibilityConvoIdPrefix)")
    }
  }

  // MARK: - Staged Post Preview

  private func postPreviewSection(_ post: ChatSharedPostPreview) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack {
        Label("Post", systemImage: "text.bubble")
          .designCaption()
          .foregroundColor(.accentColor)

        Spacer()

        Button {
          attachedPost = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .accessibilityLabel("Remove post")
      }

      VStack(alignment: .leading, spacing: 4) {
        if let displayName = post.authorDisplayName {
          Text(displayName)
            .designFootnote()
            .fontWeight(.semibold)
        } else if let handle = post.authorHandle {
          Text("@\(handle)")
            .designFootnote()
            .fontWeight(.semibold)
        }

        if let text = post.text, !text.isEmpty {
          Text(text)
            .designFootnote()
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(DesignTokens.Spacing.sm)
    .padding(.horizontal, DesignTokens.Spacing.base)
    .padding(.top, DesignTokens.Spacing.xs)
  }

  // MARK: - Composer Layout

  private var composerContent: some View {
    HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
      textField
      sendButton
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .safeAreaPadding(.bottom, DesignTokens.Spacing.sm)
    .background(Color.clear)
  }

  private var textField: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholderText)
          .font(.system(size: DesignTokens.FontSize.body))
          .foregroundColor(.secondary)
          .padding(.top, 6)
          .padding(.leading, 5)  // Match TextEditor's internal leading inset
          .padding(.top, 8)  // Match TextEditor's internal top inset
      }

      TextEditor(text: $text)
        .font(.system(size: DesignTokens.FontSize.body))
        .lineSpacing(0)
        .frame(minHeight: 36, maxHeight: 120)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .padding(.top, 6)
        .focused($isTextFieldFocused)
        .accessibilityIdentifier("chat.composer.textInput.\(accessibilityConvoIdPrefix)")
        .onChange(of: text) { _, newValue in
          #if targetEnvironment(macCatalyst)
          // On Catalyst, Enter sends; Shift+Enter or Option+Enter inserts a newline
          if newValue.hasSuffix("\n") {
            let kb = GCKeyboard.coalesced?.keyboardInput
            let modifierHeld =
              kb?.button(forKeyCode: .leftShift)?.isPressed == true
              || kb?.button(forKeyCode: .rightShift)?.isPressed == true
              || kb?.button(forKeyCode: .leftAlt)?.isPressed == true
              || kb?.button(forKeyCode: .rightAlt)?.isPressed == true
            if !modifierHeld {
              text = String(newValue.dropLast())
              if canSend {
                sendMessage()
              }
              return
            }
          }
          #endif
          let isTyping = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          onTypingChanged?(isTyping)
        }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private var sendButton: some View {
    Button {
      sendMessage()
    } label: {
      Image(systemName: "arrow.up")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.white)
        .frame(width: DesignTokens.Size.buttonSM, height: DesignTokens.Size.buttonSM)
        .background(canSend ? Color.accentColor : Color.secondary.opacity(0.25))
        .clipShape(.circle)
    }
    .contentShape(Circle())
    .disabled(!canSend)
    .opacity(canSend ? 1 : 0.5)
    .accessibilityLabel("Send message")
    .accessibilityIdentifier("chat.composer.sendButton.\(accessibilityConvoIdPrefix)")
    .padding(.bottom, 3)
  }

  // MARK: - Actions

  private func sendMessage() {
    guard canSend else { return }

    // The draft owner can retain these values until its matching send succeeds.
    let messageText = text
    let messagePost = attachedPost

    if clearsDraftOnSend {
      text = ""
      attachedPost = nil
    }
    onTypingChanged?(false)
    if dismissKeyboardOnSend {
      isTextFieldFocused = false
    }

    onSend(messageText, messagePost)
  }
}

// MARK: - Glass Panel

private struct ComposerGlassPanelModifier: ViewModifier {
  let tint: Color
  let strokeColor: Color
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content
        .clipShape(ConcentricRectangle())
        .glassEffect(
          .regular.interactive().tint(tint),
          in: .containerRelative
        )
        .shadow(color: Color.black.opacity(0.08), radius: 4)
        .padding(12)
    } else {
      content
        .background(
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.gray.opacity(0.12))
        )
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(strokeColor.opacity(0.6), lineWidth: DesignTokens.Size.borderThin)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
  }
}
