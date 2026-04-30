import CatbirdMLSCore
import OSLog
import Petrel
import SensitiveContentAnalysis
import SwiftUI

private let mlsImageViewLogger = Logger(subsystem: "blue.catbird", category: "MLSImageView")

/// Renders an image embed in an MLS chat message.
/// Handles: placeholder -> download -> decrypt -> cache -> display.
struct MLSImageView: View {
  let imageEmbed: MLSImageEmbed

  @Environment(AppState.self) private var appState
  @State private var image: PlatformImage?
  @State private var loadState: LoadState = .idle
  @State private var analysisResult: ImageAnalysisResult = .notAvailable
  @State private var isRevealed = false
  @State private var showSensitiveModal = false
  @State private var showFullscreen = false
  @Namespace private var imageTransition

  /// Whether the user is allowed to reveal sensitive content.
  /// Adults with adult content enabled can reveal; minors and users with adult content off cannot.
  @MainActor
  private var canRevealSensitiveContent: Bool {
    appState.ageVerificationManager.currentAgeGroup == .adult && appState.isAdultContentEnabled
  }

  /// Aspect ratio from the embed metadata. Used only for the placeholder —
  /// the loaded image uses its actual decoded dimensions, since metadata is
  /// occasionally wrong (e.g. EXIF rotation not applied at upload time).
  private var metadataAspectRatio: CGFloat {
    let w = CGFloat(max(imageEmbed.width, 1))
    let h = CGFloat(max(imageEmbed.height, 1))
    let raw = w / h
    // Clamp absurd ratios so a wrong-metadata placeholder doesn't reserve a
    // 400pt-tall cell that the self-sizing collection view fails to shrink
    // when the actual image arrives at a much smaller height.
    return min(max(raw, 0.5), 2.5)
  }

  /// Maximum image dimensions within the bubble. Bubble width is 280 and
  /// media-only bubbles draw the image edge-to-edge (no padding), so the
  /// image fills the full bubble width.
  private let maxImageWidth: CGFloat = 280
  private let maxImageHeight: CGFloat = 400
  /// Corner radius matches the bubble in `UnifiedMessageBubble` so the image
  /// surface IS the bubble surface (no padding ring).
  private let bubbleCornerRadius: CGFloat = 18

  /// Placeholder dimensions derived from (clamped) metadata.
  private var placeholderSize: CGSize {
    fittedSize(forAspectRatio: metadataAspectRatio)
  }

  /// Display size for a loaded image — uses the image's *actual* aspect ratio
  /// from its decoded pixel dimensions, ignoring (potentially wrong) metadata.
  private func loadedDisplaySize(for image: PlatformImage) -> CGSize {
    let w = max(image.size.width, 1)
    let h = max(image.size.height, 1)
    return fittedSize(forAspectRatio: w / h)
  }

  /// Fits an aspect ratio inside the (maxImageWidth × maxImageHeight) box,
  /// returning the exact display dimensions (no SwiftUI aspectRatio trickery).
  private func fittedSize(forAspectRatio ratio: CGFloat) -> CGSize {
    let safeRatio = ratio > 0 ? ratio : 1.0
    let widthBound = maxImageWidth
    let heightForWidth = widthBound / safeRatio
    if heightForWidth <= maxImageHeight {
      return CGSize(width: widthBound, height: heightForWidth)
    }
    return CGSize(width: maxImageHeight * safeRatio, height: maxImageHeight)
  }

  enum LoadState {
    case idle
    case loading
    case loaded
    case expired
    case error(String)
  }

  var body: some View {
    Group {
      switch loadState {
      case .idle, .loading:
        placeholder
          .overlay {
            if case .loading = loadState {
              ProgressView()
            }
          }

      case .loaded:
        if let image {
          loadedImageView(image)
        }

      case .expired:
        expiredView

      case .error(let message):
        errorView(message)
      }
    }
    .task { await loadImage() }
  }

  // MARK: - Placeholder

  @ViewBuilder
  private var placeholder: some View {
    let size = placeholderSize
    RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
      .fill(.quaternary)
      .frame(width: size.width, height: size.height)
  }

  // MARK: - Loaded Image

  @ViewBuilder
  private func loadedImageView(_ platformImg: PlatformImage) -> some View {
    switch analysisResult {
    case .sensitive(let policy):
      if policy == .simpleInterventions {
        sensitiveBlurView(platformImg)
      } else {
        sensitiveModalView(platformImg)
      }
    default:
      let size = loadedDisplaySize(for: platformImg)
      platformSwiftUIImage(platformImg)
        .resizable()
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        .matchedTransitionSource(id: imageEmbed.blobId, in: imageTransition) { source in
          source.clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        }
        .onTapGesture { showFullscreen = true }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullscreen) {
          MLSFullscreenImageView(image: platformImg, altText: imageEmbed.altText)
            .navigationTransition(.zoom(sourceID: imageEmbed.blobId, in: imageTransition))
        }
        #else
        .sheet(isPresented: $showFullscreen) {
          MLSFullscreenImageView(image: platformImg, altText: imageEmbed.altText)
        }
        #endif
    }
  }

  // MARK: - Platform Image Helper

  private func platformSwiftUIImage(_ img: PlatformImage) -> Image {
    #if os(iOS)
    Image(uiImage: img)
    #else
    Image(nsImage: img)
    #endif
  }

  // MARK: - Sensitive Content (Simple Interventions)

  @ViewBuilder
  private func sensitiveBlurView(_ platformImg: PlatformImage) -> some View {
    let size = loadedDisplaySize(for: platformImg)
    ZStack {
      platformSwiftUIImage(platformImg)
        .resizable()
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        .blur(radius: isRevealed ? 0 : 30)

      if !isRevealed {
        VStack(spacing: 8) {
          Image(systemName: "eye.slash.fill")
            .font(.title2)
          Text("This may contain sensitive content")
            .font(.caption)
          if canRevealSensitiveContent {
            Button("Show") {
              withAnimation { isRevealed = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
        .foregroundStyle(.white)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
    .matchedTransitionSource(id: imageEmbed.blobId, in: imageTransition) { source in
      source.clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
    }
    .onTapGesture {
      if isRevealed {
        showFullscreen = true
      }
    }
    #if os(iOS)
    .fullScreenCover(isPresented: $showFullscreen) {
      MLSFullscreenImageView(image: platformImg, altText: imageEmbed.altText)
        .navigationTransition(.zoom(sourceID: imageEmbed.blobId, in: imageTransition))
    }
    #else
    .sheet(isPresented: $showFullscreen) {
      MLSFullscreenImageView(image: platformImg, altText: imageEmbed.altText)
    }
    #endif
  }

  // MARK: - Sensitive Content (Descriptive Interventions)

  @ViewBuilder
  private func sensitiveModalView(_ platformImg: PlatformImage) -> some View {
    let size = loadedDisplaySize(for: platformImg)
    Button {
      showSensitiveModal = true
    } label: {
      VStack(spacing: 8) {
        Image(systemName: "eye.slash.fill")
          .font(.title2)
        Text("This image may not be appropriate")
          .font(.caption)
        Text("Tap to learn more")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(width: size.width, height: size.height)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
    }
    .sheet(isPresented: $showSensitiveModal) {
      SensitiveContentModalView(
        image: platformImg,
        canReveal: canRevealSensitiveContent,
        onReveal: { isRevealed = true; showSensitiveModal = false },
        onDismiss: { showSensitiveModal = false }
      )
    }
  }

  // MARK: - Expired

  @ViewBuilder
  private var expiredView: some View {
    let size = placeholderSize
    VStack(spacing: 4) {
      Image(systemName: "photo.badge.exclamationmark")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("Image no longer available")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let alt = imageEmbed.altText {
        Text(alt)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: size.width, height: size.height)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
  }

  // MARK: - Error

  @ViewBuilder
  private func errorView(_ message: String) -> some View {
    let size = placeholderSize
    VStack(spacing: 4) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(width: size.width, height: size.height)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
  }

  // MARK: - Diagnostics

  /// Logs metadata-vs-actual dimensions for an image. If the aspect ratios
  /// disagree the bubble will mis-size — that's the empty-space-below symptom.
  private func logImageDimensions(decoded: PlatformImage, source: String, payloadBytes: Int? = nil) {
    let metaW = imageEmbed.width
    let metaH = imageEmbed.height
    let metaRatio = CGFloat(max(metaW, 1)) / CGFloat(max(metaH, 1))

    let actualPointW = decoded.size.width
    let actualPointH = decoded.size.height
    let scale = decoded.imageScale
    let actualPixelW = actualPointW * scale
    let actualPixelH = actualPointH * scale
    let actualRatio = actualPointW / max(actualPointH, 1)

    let placeholder = placeholderSize
    let display = loadedDisplaySize(for: decoded)

    let mismatched = abs(metaRatio - actualRatio) > 0.05
    let bytesNote = payloadBytes.map { " bytes=\($0)" } ?? ""

    let message =
      "blob=\(imageEmbed.blobId) src=\(source)\(bytesNote) " +
      "meta=\(metaW)x\(metaH) ratio=\(String(format: "%.3f", metaRatio)) " +
      "actual=\(Int(actualPixelW))x\(Int(actualPixelH))px (\(Int(actualPointW))x\(Int(actualPointH))pt @\(scale)x) " +
      "ratio=\(String(format: "%.3f", actualRatio)) " +
      "placeholder=\(Int(placeholder.width))x\(Int(placeholder.height)) " +
      "display=\(Int(display.width))x\(Int(display.height)) " +
      "contentType=\(imageEmbed.contentType)"

    if mismatched {
      mlsImageViewLogger.warning("ASPECT MISMATCH \(message, privacy: .public)")
    } else {
      mlsImageViewLogger.debug("\(message, privacy: .public)")
    }
  }

  // MARK: - Loading

  private func loadImage() async {
    // Check cache first
    if let cached = await MLSImageCache.shared.get(blobId: imageEmbed.blobId) {
      image = cached
      logImageDimensions(decoded: cached, source: "cache")
      // Run SCA on cached image too (respects app-level toggle)
      #if os(iOS)
      let cgImage = cached.cgImage
      #else
      let cgImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil)
      #endif
      if appState.appSettings.sensitiveContentScanningEnabled, let cgImage {
        analysisResult = await ImageContentAnalyzer.shared.analyze(cgImage)
      }
      loadState = .loaded
      return
    }

    loadState = .loading

    do {
      // Download encrypted blob via generated Petrel endpoint
      let (responseCode, output) = try await appState.client.blue.catbird.mlschat.getBlob(
        input: .init(blobId: imageEmbed.blobId)
      )

      guard (200...299).contains(responseCode), let output else {
        if responseCode == 404 {
          loadState = .expired
        } else {
          loadState = .error("Could not load image")
        }
        return
      }

      let ciphertext = output.data

      // Decrypt
      let plaintext = try BlobCrypto.decrypt(
        ciphertext: ciphertext,
        key: imageEmbed.key,
        iv: imageEmbed.iv,
        expectedSHA256: imageEmbed.sha256
      )

      // Validate image format
      guard let decodedImage = PlatformImage(data: plaintext) else {
        loadState = .error("Invalid image data")
        return
      }

      logImageDimensions(decoded: decodedImage, source: "network", payloadBytes: plaintext.count)

      // Cache
      await MLSImageCache.shared.put(blobId: imageEmbed.blobId, imageData: plaintext)

      // SensitiveContentAnalysis check (respects app-level toggle)
      #if os(iOS)
      if appState.appSettings.sensitiveContentScanningEnabled, let cgImage = decodedImage.cgImage {
        analysisResult = await ImageContentAnalyzer.shared.analyze(cgImage)
      }
      #else
      if appState.appSettings.sensitiveContentScanningEnabled,
         let cgImage = decodedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        analysisResult = await ImageContentAnalyzer.shared.analyze(cgImage)
      }
      #endif

      image = decodedImage
      loadState = .loaded
    } catch is BlobCryptoError {
      loadState = .error("Image could not be verified")
    } catch {
      loadState = .error("Could not load image")
    }
  }
}
