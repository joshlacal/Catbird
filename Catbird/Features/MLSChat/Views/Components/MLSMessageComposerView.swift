import CatbirdMLSCore
import CatbirdMLSService
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

  /// Custom message composer for MLS chat with support for GIFs, links, and quote posts
  struct MLSMessageComposerView: View {
    @Binding var text: String
    @Binding var attachedEmbed: MLSEmbedData?

    let conversationId: String
    let onSend: (String, MLSEmbedData?) -> Void
    var supportsEmbeds: Bool = true
    var showsAttachmentMenu: Bool = true
    var dismissKeyboardOnSend: Bool = true
    var placeholderText: String = "Message"

    @State private var showingGifPicker = false
    @State private var showingPostPicker = false
    @State private var isDetectingLink = false
    @State private var detectedLinkEmbed: MLSLinkEmbed?

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTextFieldFocused: Bool

    private var showsAttachments: Bool {
      supportsEmbeds && showsAttachmentMenu
    }

    private var composerTint: Color {
      Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06)
    }

    private var composerStroke: Color {
      Color.primary.opacity(colorScheme == .dark ? 0.3 : 0.12)
    }

    private var panelTint: Color {
      Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.08)
    }

    private var panelStroke: Color {
      Color.primary.opacity(colorScheme == .dark ? 0.32 : 0.14)
    }

    private var accessibilityConvoIdPrefix: String {
      accessibilitySafeIdPrefix(conversationId)
    }

    var body: some View {
      VStack(spacing: DesignTokens.Spacing.sm) {
        // Embed preview (if attached)
        if supportsEmbeds, let embed = attachedEmbed {
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
      ZStack {
        

        composerContent
              .background {
                  composerBackground
              }      }
      .accessibilityIdentifier("mls.composer.\(accessibilityConvoIdPrefix)")
    }

    @ViewBuilder
    private var composerBackground: some View {
      // Edge-to-edge glass background (flush to bezel)
      // On Catalyst, don't ignore safe area to stay within detail view bounds
      if #available(iOS 26.0, *) {
        Color.clear
          .background {
            ConcentricRectangle(corners: .concentric, isUniform: true)
              .stroke(composerStroke, lineWidth: DesignTokens.Size.borderThin)

          }
          #if !targetEnvironment(macCatalyst)
          .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
          #endif
      } else {
        RoundedRectangle(
          cornerRadius: DesignTokens.Size.radiusXXL + DesignTokens.Spacing.sm,
          style: .continuous
        )
        .fill(.ultraThinMaterial)
        .overlay {
          RoundedRectangle(
            cornerRadius: DesignTokens.Size.radiusXXL + DesignTokens.Spacing.sm,
            style: .continuous
          )
          .strokeBorder(composerStroke, lineWidth: DesignTokens.Size.borderThin)
        }
        #if !targetEnvironment(macCatalyst)
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        #endif
      }
    }

    private var composerContent: some View {
      HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
        if showsAttachments {
          attachmentMenu
        }
        textField
        sendButton
      }
      .padding(.horizontal, DesignTokens.Spacing.base)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .safeAreaPadding(.bottom, DesignTokens.Spacing.sm)
      .background(Color.clear)
    }

    private var attachmentMenu: some View {
      let isEnabled = attachedEmbed == nil

      return Menu {
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
        Image(systemName: "plus")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
          .frame(width: DesignTokens.Size.buttonSM, height: DesignTokens.Size.buttonSM)
          .accessibilityLabel("Add attachment")
      }
      .disabled(!isEnabled)  // Only one embed at a time
    }

    @ViewBuilder
    private var textField: some View {
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text(placeholderText)
            .designBody()
            .foregroundColor(.secondary)
            .padding(.leading, 5)  // Match TextEditor's internal leading inset
            .padding(.top, 8)  // Match TextEditor's internal top inset
        }

        TextEditor(text: $text)
          .designBody()
          .frame(minHeight: 36, maxHeight: 120)
          .scrollContentBackground(.hidden)
          .background(Color.clear)
          .focused($isTextFieldFocused)
          .accessibilityIdentifier("mls.composer.textInput.\(accessibilityConvoIdPrefix)")
          .onChange(of: text) { _, newValue in
            // Detect URLs for link previews
            if supportsEmbeds {
              detectLinkInText(newValue)
            }
          }
      }
      .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sendButton: some View {
      Button {
        sendMessage()
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(canSend ? Color.white : Color.secondary)
          .frame(width: DesignTokens.Size.buttonSM, height: DesignTokens.Size.buttonSM)
          .background(Color.accentColor)
          .clipShape(.circle)

      }
      .contentShape(Circle())
      .disabled(!canSend)
      .accessibilityLabel("Send message")
      .accessibilityIdentifier("mls.composer.sendButton.\(accessibilityConvoIdPrefix)")
    }

    private func accessibilitySafeIdPrefix(_ value: String, maxLength: Int = 12) -> String {
      let filtered = value.unicodeScalars.compactMap { scalar -> Character? in
        guard scalar.isASCII else { return nil }
        let v = scalar.value
        let isAlphaNum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        return isAlphaNum ? Character(scalar) : nil
      }
      let prefix = String(filtered.prefix(maxLength))
      return prefix.isEmpty ? "unknown" : prefix
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
      guard supportsEmbeds else { return }
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

      attachedEmbed = .gif(
        MLSGIFEmbed(
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
      guard supportsEmbeds else { return }
      // Cancel if already has embed or is loading
      guard attachedEmbed == nil, !isDetectingLink else { return }

      // Simple URL detection (can be improved with proper regex)
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
      let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []

      guard let firstMatch = matches.first,
        let range = Range(firstMatch.range, in: text),
        let url = URL(string: String(text[range]))
      else {
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

      // Capture values before resetting state to avoid race condition
      let messageText = text
      let messageEmbed = supportsEmbeds ? attachedEmbed : nil

      // Reset state immediately for better UX
      text = ""
      attachedEmbed = nil
      detectedLinkEmbed = nil
      if dismissKeyboardOnSend {
        isTextFieldFocused = false
      }

      // Call onSend with captured values
      onSend(messageText, messageEmbed)
    }

    private func attachPost(_ post: AppBskyFeedDefs.PostView) {
      guard supportsEmbeds else { return }
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
      if case .knownType(let record) = post.record,
        let feedPost = record as? AppBskyFeedPost
      {
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
      attachedEmbed = .post(
        MLSPostEmbed(
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

    // Typing indicator functions have been removed.
  }

  // MARK: - Glass Effect Modifiers

  private struct GlassPanelModifier: ViewModifier {
    let tint: Color
    let strokeColor: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
      if #available(iOS 26.0, *) {
        content
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
          .glassEffect(
            .regular.tint(tint).interactive(),
            in: .rect(cornerRadius: cornerRadius)
          )
          .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
              .strokeBorder(strokeColor, lineWidth: DesignTokens.Size.borderThin)
          }
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

  private struct GlassAccessoryButtonModifier: ViewModifier {
    let isEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
      let fill = Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08)
      let stroke = Color.primary.opacity(colorScheme == .dark ? 0.28 : 0.12)

      content
        .background(
          Circle()
            .fill(fill)
        )
        .overlay {
          Circle()
            .strokeBorder(stroke, lineWidth: DesignTokens.Size.borderThin)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
  }

  private struct GlassSendButtonModifier: ViewModifier {
    let canSend: Bool

    func body(content: Content) -> some View {
      let fill = canSend ? Color.accentColor : Color.secondary.opacity(0.25)
      let stroke = Color.white.opacity(canSend ? 0.28 : 0.12)

      content
        .background(
          Circle()
            .fill(fill)
        )
        .overlay {
          Circle()
            .strokeBorder(stroke, lineWidth: DesignTokens.Size.borderThin)
        }
    }
  }

  // MARK: - Preview

  #Preview("Empty Composer") {
    MLSMessageComposerPreview()
  }

  #Preview("With Text") {
    MLSMessageComposerPreview(initialText: "Hello, this is a test message!")
  }

  #Preview("With Link Embed") {
    MLSMessageComposerPreview(
      initialText: "Check this out: https://bsky.app",
      initialEmbed: .link(
        MLSLinkEmbed(
          url: "https://bsky.app",
          title: "Bluesky Social",
          description: "What’s next in social media",
          thumbnailURL: nil,
          domain: "bsky.app"
        )
      )
    )
  }

  private struct MLSMessageComposerPreview: View {
    @State private var text: String
    @State private var attachedEmbed: MLSEmbedData?

    init(initialText: String = "", initialEmbed: MLSEmbedData? = nil) {
      _text = State(initialValue: initialText)
      _attachedEmbed = State(initialValue: initialEmbed)
    }

    var body: some View {
      ZStack(alignment: .bottom) {
        Color(.systemBackground)
          .ignoresSafeArea()

          MLSMessageComposerView(
            text: $text,
            attachedEmbed: $attachedEmbed,
            conversationId: "preview-convo-id",
            onSend: { _, _ in }
          )
      }
    }

}

#endif


#Preview("GIF Embed Content") {
    MLSMessageComposerPreview(
        initialEmbed: .gif(
            MLSGIFEmbed(
                tenorURL: "https://tenor.com/view/12345",
                mp4URL: "https://media.tenor.com/12345.mp4",
                title: "Funny Cat",
                thumbnailURL: "https://media.tenor.com/12345_tn.jpg",
                width: 320,
                height: 180
            )
        )
    )
}
