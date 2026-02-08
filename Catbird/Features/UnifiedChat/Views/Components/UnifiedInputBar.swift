import SwiftUI

/// Floating pill-style input bar with Liquid Glass support for iOS 26+
struct UnifiedInputBar: View {
  @Binding var text: String
  let onSend: (String) -> Void
  var attachedEmbed: UnifiedEmbed?
  var onRemoveEmbed: (() -> Void)?
  var onAttachTapped: (() -> Void)?

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var isFocused: Bool

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedEmbed != nil
  }

  var body: some View {
    VStack(spacing: 8) {
      // Attached embed preview
      if let embed = attachedEmbed {
        attachedEmbedPreview(embed)
      }

      // Input row
      inputRow
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .inputBarBackground()
  }

  // MARK: - Input Row

  private var inputRow: some View {
    HStack(spacing: 12) {
      // Attach button (optional)
      if let onAttach = onAttachTapped {
        Button(action: onAttach) {
          Image(systemName: "plus.circle.fill")
            .font(.title2)
            .foregroundStyle(.secondary)
        }
      }

      // Text field
      TextField("Message", text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...5)
        .focused($isFocused)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
          Capsule()
            .fill(Color.gray.opacity(0.1))
        )

      // Send button
      Button(action: sendMessage) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
          .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
      }
      .disabled(!canSend)
      .animation(.easeInOut(duration: 0.2), value: canSend)
    }
  }

  // MARK: - Attached Embed Preview

  @ViewBuilder
  private func attachedEmbedPreview(_ embed: UnifiedEmbed) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(embedTitle(for: embed))
          .font(.caption)
          .fontWeight(.medium)
          .lineLimit(1)

        Text(embedSubtitle(for: embed))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button {
        onRemoveEmbed?()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.gray.opacity(0.1))
    )
  }

  private func embedTitle(for embed: UnifiedEmbed) -> String {
    switch embed {
    case .blueskyRecord:
      return "Shared Post"
    case .link(let link):
      return link.title ?? "Link"
    case .gif:
      return "GIF"
    case .post(let post):
      return post.authorHandle ?? "Shared Post"
    }
  }

  private func embedSubtitle(for embed: UnifiedEmbed) -> String {
    switch embed {
    case .blueskyRecord(let record):
      return record.uri
    case .link(let link):
      return link.url.host ?? link.url.absoluteString
    case .gif(let gif):
      return gif.url.absoluteString
    case .post(let post):
      return post.text ?? post.uri
    }
  }

  // MARK: - Actions

  private func sendMessage() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend else { return }
    onSend(trimmed)
    text = ""
  }
}

// MARK: - Liquid Glass Background

private extension View {
  @ViewBuilder
  func inputBarBackground() -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      self
        .background(.clear)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    } else {
      self
        .background(
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Material.regularMaterial)
        )
    }
  }
}

// MARK: - Preview

#Preview {
  VStack {
    Spacer()

    UnifiedInputBar(
      text: .constant(""),
      onSend: { _ in }
    )

    UnifiedInputBar(
      text: .constant("Hello, this is a message!"),
      onSend: { _ in }
    )

    UnifiedInputBar(
      text: .constant(""),
      onSend: { _ in },
      attachedEmbed: .link(LinkEmbedData(
        url: URL(string: "https://example.com")!,
        title: "Example Link",
        description: nil,
        thumbnailURL: nil
      )),
      onRemoveEmbed: {}
    )
  }
  .padding()
  .background(Color.gray.opacity(0.2))
}
