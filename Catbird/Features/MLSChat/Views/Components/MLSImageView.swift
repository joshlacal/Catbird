import CatbirdMLSCore
import Petrel
import SensitiveContentAnalysis
import SwiftUI

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

  private var aspectRatio: CGFloat {
    let w = CGFloat(max(imageEmbed.width, 1))
    let h = CGFloat(max(imageEmbed.height, 1))
    return w / h
  }

  /// Maximum image dimensions within the bubble (280 - 8 padding).
  private let maxImageWidth: CGFloat = 272
  private let maxImageHeight: CGFloat = 400

  /// Pre-calculated image height based on aspect ratio, clamped to max dimensions.
  private var calculatedImageHeight: CGFloat {
    let fitHeight = maxImageWidth / aspectRatio
    if fitHeight <= maxImageHeight {
      return fitHeight
    }
    return maxImageHeight
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
    RoundedRectangle(cornerRadius: 12)
      .fill(.quaternary)
      .frame(maxWidth: maxImageWidth)
      .frame(height: calculatedImageHeight)
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
      platformSwiftUIImage(platformImg)
        .resizable()
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: maxImageWidth, maxHeight: maxImageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .matchedTransitionSource(id: imageEmbed.blobId, in: imageTransition) { source in
          source.clipShape(RoundedRectangle(cornerRadius: 12))
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
    ZStack {
      platformSwiftUIImage(platformImg)
        .resizable()
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: maxImageWidth, maxHeight: maxImageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
    .contentShape(RoundedRectangle(cornerRadius: 12))
    .matchedTransitionSource(id: imageEmbed.blobId, in: imageTransition) { source in
      source.clipShape(RoundedRectangle(cornerRadius: 12))
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
      .frame(maxWidth: maxImageWidth)
      .frame(height: calculatedImageHeight)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
    .frame(maxWidth: maxImageWidth)
    .frame(height: calculatedImageHeight)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Error

  @ViewBuilder
  private func errorView(_ message: String) -> some View {
    VStack(spacing: 4) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: maxImageWidth)
    .frame(height: calculatedImageHeight)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Loading

  private func loadImage() async {
    // Check cache first
    if let cached = await MLSImageCache.shared.get(blobId: imageEmbed.blobId) {
      image = cached
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
