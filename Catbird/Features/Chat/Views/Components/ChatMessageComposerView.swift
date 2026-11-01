import GameController
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Preview of a Bluesky post staged in the DM composer (share-to-chat).
/// Only used for display; the wire embed is the post's strong ref.
struct ChatSharedPostPreview: Equatable {
  let authorDisplayName: String?
  let authorHandle: String?
  let text: String?
}

// MARK: - Editor Metrics

@MainActor
enum ChatComposerEditorMetrics {
  /// TextEditor's own top and bottom text inset.
  static let textInset: CGFloat = 8

  #if os(iOS)
  private static var minimumHeights: [DynamicTypeSize: CGFloat] = [:]
  #endif

  /// One body line as TextEditor's text view lays it out, plus its insets. TextKit's line
  /// is taller than `UIFont.lineHeight`, so a minimum built from the font alone lets the
  /// editor settle a point short of its text on some layouts.
  static func minimumHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
    #if os(iOS)
    if let height = minimumHeights[dynamicTypeSize] { return height }
    let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
    let sizingView = UITextView()
    sizingView.font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    sizingView.textContainerInset = UIEdgeInsets(top: textInset, left: 0, bottom: textInset, right: 0)
    let lineHeight = sizingView.sizeThatFits(CGSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)).height
    let height = max(36, ceil(lineHeight))
    minimumHeights[dynamicTypeSize] = height
    return height
    #else
    return 36
    #endif
  }
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

  #if DEBUG
  var fixtureSendingDisabled: Bool = false

  func sendingDisabledForLocalFixture() -> Self {
    var composer = self
    composer.fixtureSendingDisabled = true
    return composer
  }
  #endif

  @FocusState private var isTextFieldFocused: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private let editorTextInset = ChatComposerEditorMetrics.textInset

  private var minimumEditorHeight: CGFloat {
    ChatComposerEditorMetrics.minimumHeight(for: dynamicTypeSize)
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

  /// Grapheme count of the text that will be sent (the chat service limit
  /// applies to the trimmed text).
  private var messageLength: Int {
    text.trimmingCharacters(in: .whitespacesAndNewlines).count
  }

  private var isOverLimit: Bool {
    messageLength > ChatManager.maxMessageGraphemes
  }

  private var canSend: Bool {
    #if DEBUG
    if fixtureSendingDisabled { return false }
    #endif
    guard !isOverLimit else { return false }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedPost != nil
  }

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      if let post = attachedPost {
        postPreviewSection(post)
      }

      composerContent
    }
    .modifier(ComposerGlassPanelModifier(cornerRadius: composerCornerRadius))
    .accessibilityIdentifier("chat.composer.\(accessibilityConvoIdPrefix)")
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
      VStack(spacing: 2) {
        if messageLength > ChatManager.maxMessageGraphemes - 100 {
          characterCounter
        }
        sendButton
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.vertical, DesignTokens.Spacing.md)
    .background(Color.clear)
  }

  private var textField: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholderText)
          .font(.body)
          .foregroundColor(.secondary)
          .padding(.top, 4)
          .padding(.leading, 5)  // Match TextEditor's internal leading inset
          .padding(.top, editorTextInset)  // Match TextEditor's internal top inset
          .accessibilityHidden(true)
      }

      TextEditor(text: $text)
        .font(.body)
        .lineSpacing(0)
        .frame(minHeight: minimumEditorHeight, maxHeight: 120)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .padding(.vertical, 4)
        .focused($isTextFieldFocused)
        .accessibilityLabel(placeholderText)
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

  private var characterCounter: some View {
    Text("\(messageLength.formatted())/\(ChatManager.maxMessageGraphemes.formatted())")
      .font(.caption2.monospacedDigit())
      .foregroundStyle(isOverLimit ? Color.red : Color.secondary)
      .fixedSize()
      .accessibilityLabel(
        isOverLimit
          ? "Message too long. \(messageLength) of \(ChatManager.maxMessageGraphemes) characters."
          : "\(messageLength) of \(ChatManager.maxMessageGraphemes) characters"
      )
  }

  private var sendButton: some View {
    Button {
      sendMessage()
    } label: {
      Image(systemName: "arrow.up")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(canSend ? Color.white : Color.secondary)
        .frame(width: DesignTokens.Size.buttonSM, height: DesignTokens.Size.buttonSM)
        .background(canSend ? Color.accentColor : Color.secondary.opacity(0.15))
        .clipShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Circle())
    }
    .disabled(!canSend)
    .accessibilityLabel("Send message")
    .accessibilityIdentifier("chat.composer.sendButton.\(accessibilityConvoIdPrefix)")
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
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    Group {
      if reduceTransparency {
        content
          .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground), in: shape)
          .overlay { shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.2)) }
      } else if #available(iOS 26.0, macOS 26.0, *) {
        content
          .glassEffect(.regular.interactive(), in: shape)
      } else {
        content
          .background(.regularMaterial, in: shape)
          .overlay { shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.2)) }
      }
    }
    .padding(12)
  }
}
