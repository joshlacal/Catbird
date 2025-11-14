import SwiftUI
import Petrel
import OSLog

#if os(iOS)

/// Custom message composer for MLS chat with support for GIFs, links, and quote posts
struct MLSMessageComposerView: View {
  @Binding var text: String
  @Binding var attachedEmbed: MLSEmbedData?

  let onSend: (String, MLSEmbedData?) -> Void

  @State private var showingGifPicker = false
  @State private var isDetectingLink = false
  @State private var detectedLinkEmbed: MLSLinkEmbed?

  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var isTextFieldFocused: Bool

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSMessageComposerView")

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.xs) {
      // Embed preview (if attached)
      if let embed = attachedEmbed {
        embedPreviewSection(embed)
      }

      // Message input area
      HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
        // Attachment button
        Menu {
          Button {
            showingGifPicker = true
          } label: {
            Label("Add GIF", systemImage: "photo.on.rectangle")
          }

          // Future: Add quote post and link buttons here
        } label: {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 28))
            .foregroundColor(.accentColor)
        }
        .disabled(attachedEmbed != nil) // Only one embed at a time

        // Text input
        ZStack(alignment: .topLeading) {
          if text.isEmpty {
            Text("Message...")
              .designBody()
              .foregroundColor(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
          }

          TextEditor(text: $text)
            .designBody()
            .frame(minHeight: 38, maxHeight: 100)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .focused($isTextFieldFocused)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .cornerRadius(10)
            .onChange(of: text) { _, newValue in
              // Detect URLs for link previews
              detectLinkInText(newValue)
            }
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(18)

        // Send button
        Button {
          sendMessage()
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 28))
            .foregroundColor(canSend ? .accentColor : .gray)
        }
        .disabled(!canSend)
      }
      .padding(.horizontal, DesignTokens.Spacing.base)
      .padding(.vertical, DesignTokens.Spacing.sm)
    }
    .background(Color(platformColor: .platformSystemBackground))
    .sheet(isPresented: $showingGifPicker) {
      GifPickerView { gif in
        attachGif(gif)
      }
    }
  }

  // MARK: - Embed Preview

  @ViewBuilder
  private func embedPreviewSection(_ embed: MLSEmbedData) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack {
        embedTypeLabel(for: embed)

        Spacer()

        Button {
          attachedEmbed = nil
          detectedLinkEmbed = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
      }

      // Preview content
      embedPreviewContent(embed)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(DesignTokens.Spacing.sm)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(DesignTokens.Size.radiusSM)
    .padding(.horizontal, DesignTokens.Spacing.base)
    .padding(.top, DesignTokens.Spacing.xs)
  }

  @ViewBuilder
  private func embedTypeLabel(for embed: MLSEmbedData) -> some View {
    switch embed {
    case .gif:
      Label("GIF", systemImage: "play.rectangle.fill")
        .designCaption()
        .foregroundColor(.accentColor)
    case .link:
      Label("Link", systemImage: "link")
        .designCaption()
        .foregroundColor(.accentColor)
    case .record:
      Label("Quote Post", systemImage: "quote.bubble")
        .designCaption()
        .foregroundColor(.accentColor)
    }
  }

  @ViewBuilder
  private func embedPreviewContent(_ embed: MLSEmbedData) -> some View {
    switch embed {
    case .gif(let gifEmbed):
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "play.rectangle.fill")
          .font(.system(size: 32))
          .foregroundColor(.secondary)

        VStack(alignment: .leading, spacing: 2) {
          if let title = gifEmbed.title {
            Text(title)
              .designFootnote()
              .lineLimit(1)
          }
          Text("Tenor GIF")
            .designCaption()
            .foregroundColor(.secondary)
        }
      }

    case .link(let linkEmbed):
      VStack(alignment: .leading, spacing: 4) {
        if let domain = linkEmbed.domain {
          Text(domain)
            .designCaption()
            .foregroundColor(.accentColor)
        }

        if let title = linkEmbed.title {
          Text(title)
            .designFootnote()
            .fontWeight(.semibold)
            .lineLimit(2)
        } else {
          Text(linkEmbed.url)
            .designCaption()
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }

    case .record(let recordEmbed):
      VStack(alignment: .leading, spacing: 4) {
        Text("Quote Post")
          .designCaption()
          .foregroundColor(.accentColor)

        if let previewText = recordEmbed.previewText {
          Text(previewText)
            .designFootnote()
            .lineLimit(2)
        }

        Text(recordEmbed.uri)
          .designCaption()
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
  }

  // MARK: - Actions

  private func attachGif(_ gif: TenorGif) {
    // Use the best quality MP4 URL available
    guard let mp4URL = bestMP4URL(from: gif) else {
      logger.error("No MP4 URL available for GIF")
      return
    }

    // Get thumbnail URL
    let thumbnailURL = gif.media_formats.tinygif?.url ?? gif.media_formats.gif?.url

    // Extract dimensions from the mp4 format if available
    let dimensions = gif.media_formats.mp4?.dims
    let width = dimensions?.first
    let height = dimensions?.count ?? 0 > 1 ? dimensions?[1] : nil

    attachedEmbed = .gif(MLSGIFEmbed(
      tenorURL: "https://tenor.com/view/\(gif.id)",
      mp4URL: mp4URL,
      title: gif.content_description,
      thumbnailURL: thumbnailURL,
      width: width,
      height: height
    ))

    logger.info("Attached GIF embed: \(gif.id)")
  }

  private func detectLinkInText(_ text: String) {
    // Cancel if already has embed or is loading
    guard attachedEmbed == nil, !isDetectingLink else { return }

    // Simple URL detection (can be improved with proper regex)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []

    guard let firstMatch = matches.first,
          let range = Range(firstMatch.range, in: text),
          let url = URL(string: String(text[range])) else {
      // Clear detected link if no URL found
      if detectedLinkEmbed != nil {
        detectedLinkEmbed = nil
      }
      return
    }

    // Fetch link metadata (simplified - would use real metadata fetcher in production)
    Task {
      await fetchLinkMetadata(url: url)
    }
  }

  private func fetchLinkMetadata(url: URL) async {
    isDetectingLink = true

    // TODO: Implement proper Open Graph / metadata fetching
    // For now, create a minimal embed with just the URL
    let domain = url.host ?? url.absoluteString

    await MainActor.run {
      let linkEmbed = MLSLinkEmbed(
        url: url.absoluteString,
        title: nil,
        description: nil,
        thumbnailURL: nil,
        domain: domain
      )

      detectedLinkEmbed = linkEmbed

      // Only attach if no other embed is present
      if attachedEmbed == nil {
        attachedEmbed = .link(linkEmbed)
      }

      isDetectingLink = false
    }
  }

  private func sendMessage() {
    guard canSend else { return }

    // Capture values before resetting state to avoid race condition
    let messageText = text
    let messageEmbed = attachedEmbed

    // Reset state immediately for better UX
    text = ""
    attachedEmbed = nil
    detectedLinkEmbed = nil
    isTextFieldFocused = false

    // Call onSend with captured values
    onSend(messageText, messageEmbed)
  }

  // MARK: - Helpers

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedEmbed != nil
  }

  private func bestMP4URL(from gif: TenorGif) -> String? {
    // Prefer higher quality formats
    if let mp4 = gif.media_formats.mp4 {
      return mp4.url
    } else if let loopedMP4 = gif.media_formats.loopedmp4 {
      return loopedMP4.url
    } else if let tinyMP4 = gif.media_formats.tinymp4 {
      return tinyMP4.url
    } else if let nanoMP4 = gif.media_formats.nanomp4 {
      return nanoMP4.url
    }
    return nil
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  struct PreviewWrapper: View {
    @State private var text = ""
    @State private var attachedEmbed: MLSEmbedData?

    var body: some View {
      VStack {
        Spacer()

        MLSMessageComposerView(
          text: $text,
          attachedEmbed: $attachedEmbed,
          onSend: { text, embed in
            print("Send: \(text)")
            print("Embed: \(String(describing: embed))")
          }
        )
      }
      .environment(AppStateManager.shared)
    }
  }

  return PreviewWrapper()
}

#endif
