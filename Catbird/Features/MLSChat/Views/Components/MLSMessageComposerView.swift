import CatbirdMLSCore
import SwiftUI
import Petrel
import OSLog

#if os(iOS)

/// Custom message composer for MLS chat with support for GIFs, links, and quote posts
struct MLSMessageComposerView: View {
  @Binding var text: String
  @Binding var attachedEmbed: MLSEmbedData?

  let conversationId: String
  let onSend: (String, MLSEmbedData?) -> Void

  @Environment(AppState.self) private var appState
  @State private var showingGifPicker = false
  @State private var showingPostPicker = false
  @State private var isDetectingLink = false
  @State private var detectedLinkEmbed: MLSLinkEmbed?
  @State private var typingIndicatorTask: Task<Void, Never>?
  @State private var lastTypingSent: Date = .distantPast

  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var isTextFieldFocused: Bool

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSMessageComposerView")
  
  /// Minimum interval between typing indicator sends (to avoid spamming)
  private let typingDebounceInterval: TimeInterval = 3.0

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.xs) {
      // Embed preview (if attached)
      if let embed = attachedEmbed {
        embedPreviewSection(embed)
      }

      // Message input area
      composerContainer
    }
    .sheet(isPresented: $showingGifPicker) {
      GifPickerView { gif in
        attachGif(gif)
      }
    }
    .sheet(isPresented: $showingPostPicker) {
      MLSPostPickerView { post in
        attachPost(post)
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
    case .post:
      Label("Post", systemImage: "text.bubble")
        .designCaption()
        .foregroundColor(.accentColor)
    }
  }

  // MARK: - Composer Layout

  @ViewBuilder
  private var composerContainer: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: DesignTokens.Spacing.sm) {
        composerContent
      }
    } else {
      composerContent
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
  }

  private var composerContent: some View {
    HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
      attachmentMenu
      textField
      sendButton
    }
    .padding(.horizontal, DesignTokens.Spacing.base)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(GlassFrameModifier())
  }

  private var attachmentMenu: some View {
    Menu {
      Button {
        showingGifPicker = true
      } label: {
        Label("Add GIF", systemImage: "photo.on.rectangle")
      }

      Button {
        showingPostPicker = true
      } label: {
        Label("Share Post", systemImage: "text.bubble")
      }
    } label: {
      Image(systemName: "plus.circle.fill")
        .font(.system(size: 28))
        .foregroundColor(.accentColor)
    }
    .disabled(attachedEmbed != nil) // Only one embed at a time
  }

  @ViewBuilder
  private var textField: some View {
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
          
          // Send typing indicator (debounced)
          sendTypingIndicatorIfNeeded(isTyping: !newValue.isEmpty)
        }
        .onDisappear {
          // Send stop typing when view disappears
          sendStopTyping()
        }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .modifier(GlassTextModifier())
  }

  @ViewBuilder
  private var sendButton: some View {
    Button {
      sendMessage()
    } label: {
      Image(systemName: "arrow.up")
        .font(.system(size: 16, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .foregroundColor(canSend ? .primary : .secondary)
    }
    .contentShape(Capsule())
    .disabled(!canSend)
    .modifier(GlassSendButtonModifier(canSend: canSend))
    .accessibilityLabel("Send message")
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

    case .post(let postEmbed):
      VStack(alignment: .leading, spacing: 4) {
        if let displayName = postEmbed.authorDisplayName {
          Text(displayName)
            .designFootnote()
            .fontWeight(.semibold)
        } else if let handle = postEmbed.authorHandle {
          Text("@\(handle)")
            .designFootnote()
            .fontWeight(.semibold)
        }

        if let text = postEmbed.text {
          Text(text)
            .designFootnote()
            .lineLimit(2)
        }
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

    // Note: Full Open Graph metadata fetching would require network requests.
    // Current implementation creates a minimal embed with just the URL and domain.
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

    // Cancel any pending typing indicator task
    typingIndicatorTask?.cancel()
    typingIndicatorTask = nil
    
    // Send stop typing indicator
    sendStopTyping()

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

  private func attachPost(_ post: AppBskyFeedDefs.PostView) {
    // Extract post data
    let uri = post.uri.uriString()
    let cidString = post.cid.string

    // Extract author info
    let authorDid = post.author.did.description
    let authorHandle = post.author.handle.description
    let authorDisplayName = post.author.displayName
    let authorAvatar = post.author.finalAvatarURL()

    // Extract post text
    let postText: String
    if case let .knownType(record) = post.record,
       let feedPost = record as? AppBskyFeedPost {
      postText = feedPost.text
    } else {
      postText = ""
    }

    // Extract engagement counts
    let likeCount = post.likeCount
    let replyCount = post.replyCount
    let repostCount = post.repostCount

    // Extract images if present
    var images: [MLSPostImage]?
    if let embed = post.embed {
      switch embed {
      case .appBskyEmbedImagesView(let imagesView):
        let mappedImages = imagesView.images.compactMap { imageView -> MLSPostImage? in
          guard let fullsize = imageView.fullsize.url, let thumb = imageView.thumb.url else {
            return nil
          }
          return MLSPostImage(
            thumb: thumb,
            fullsize: fullsize,
            alt: imageView.alt
          )
        }
        images = mappedImages.isEmpty ? nil : mappedImages
      default:
        break
      }
    }

    // Create post embed
    attachedEmbed = .post(MLSPostEmbed(
      uri: uri,
      cid: cidString,
      authorDid: authorDid,
      authorHandle: authorHandle,
      authorDisplayName: authorDisplayName,
      authorAvatar: authorAvatar,
      text: postText,
      createdAt: post.indexedAt.date,
      likeCount: likeCount,
      replyCount: replyCount,
      repostCount: repostCount,
      images: images
    ))

    logger.info("Attached post embed: \(uri)")
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
  
  // MARK: - Typing Indicators
  
  /// Send typing indicator if enough time has passed since last send
  private func sendTypingIndicatorIfNeeded(isTyping: Bool) {
    let now = Date()
    
    // If starting to type, debounce to avoid spamming
    if isTyping {
      guard now.timeIntervalSince(lastTypingSent) >= typingDebounceInterval else { return }
      lastTypingSent = now
    }
    
    // Cancel any pending typing task
    typingIndicatorTask?.cancel()
    
    // Send the typing indicator
    typingIndicatorTask = Task {
      do {
        guard let manager = await appState.getMLSConversationManager() else {
          logger.warning("Cannot send typing indicator: manager not available")
          return
        }
        
        _ = try await manager.sendTypingIndicator(convoId: conversationId, isTyping: isTyping)
        logger.debug("Sent typing indicator: isTyping=\(isTyping)")
      } catch {
        logger.warning("Failed to send typing indicator: \(error.localizedDescription)")
      }
    }
    
    // If typing, schedule automatic stop after timeout
    if isTyping {
      Task {
        try? await Task.sleep(for: .seconds(5))
        
        // If user hasn't typed anything new, send stop typing
        if Date().timeIntervalSince(lastTypingSent) >= 5 {
          sendStopTyping()
        }
      }
    }
  }
  
  /// Send stop typing indicator
  private func sendStopTyping() {
    Task {
      do {
        guard let manager = await appState.getMLSConversationManager() else { return }
        _ = try await manager.sendTypingIndicator(convoId: conversationId, isTyping: false)
      } catch {
        // Silently ignore stop typing failures
      }
    }
  }
}

// MARK: - Glass Effect Modifiers

private struct GlassFrameModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(
          .regular.tint(Color.accentColor.opacity(0.14)).interactive(),
          in: .rect(cornerRadius: 22)
        )
    } else {
      content
    }
  }
}

private struct GlassTextModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(
          .regular.tint(Color.secondary.opacity(0.25)).interactive(),
          in: .rect(cornerRadius: 16)
        )
    } else {
      content
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
  }
}

private struct GlassSendButtonModifier: ViewModifier {
  let canSend: Bool

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(
          .regular.tint((canSend ? Color.accentColor : Color.secondary).opacity(0.6)).interactive(),
          in: .capsule
        )
    } else {
      content
        .background(
          Capsule()
            .fill((canSend ? Color.accentColor : Color.secondary).opacity(0.15))
        )
    }
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
          conversationId: "preview-convo-id",
          onSend: { text, embed in
            _ = (text, embed)
          }
        )
      }
      .environment(AppStateManager.shared)
    }
  }

  return PreviewWrapper()
}

#endif
