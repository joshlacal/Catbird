import SwiftUI
import CatbirdMLSCore
import Petrel
import PetrelCatbird

#if os(iOS)
import VisionKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Fullscreen image viewer for MLS chat images.
/// Reuses ZoomableImageViewController from ViewImageGridView for consistent zoom behavior.
/// Starts with thumbnail for instant presentation, then asynchronously decodes
/// full-resolution original from disk cache or network so zoom, Live Text, and sharing
/// retain full quality.
struct MLSFullscreenImageView: View {
  let thumbnail: PlatformImage
  let imageEmbed: MLSImageEmbed?
  let userDID: String
  let altText: String?

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var fullImage: PlatformImage?
  @State private var showControls = true
  @State private var isAltTextExpanded = false
  @State private var liveTextEnabled = false
  #if os(iOS)
  @State private var liveTextSupported = ImageAnalyzer.isSupported
  #else
  @State private var liveTextSupported = false
  #endif

  init(
    thumbnail: PlatformImage,
    imageEmbed: MLSImageEmbed? = nil,
    userDID: String = "",
    altText: String? = nil
  ) {
    self.thumbnail = thumbnail
    self.imageEmbed = imageEmbed
    self.userDID = userDID
    self.altText = altText ?? imageEmbed?.altText
  }

  private var displayImage: PlatformImage {
    fullImage ?? thumbnail
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      #if os(iOS)
      MLSZoomableUIImageWrapper(
        uiImage: displayImage,
        altText: altText,
        liveTextEnabled: $liveTextEnabled,
        liveTextSupported: liveTextSupported
      )
      .ignoresSafeArea()
      .onTapGesture {
        withAnimation { showControls.toggle() }
      }
      #else
      Image(nsImage: displayImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .onTapGesture {
          withAnimation { showControls.toggle() }
        }
      #endif

      if showControls {
        controlsOverlay
      }
    }
    #if os(iOS)
    .statusBarHidden(!showControls)
    #endif
    .task {
      await loadFullResolutionImage()
    }
  }

  // MARK: - Full Resolution Loading

  private func loadFullResolutionImage() async {
    guard let imageEmbed else { return }
    let effectiveDID = userDID.isEmpty ? appState.userDID : userDID

    // 1. Check disk cache first for full-resolution original
    if let original = await MLSImageCache.shared.getOriginal(blobId: imageEmbed.blobId, userDID: effectiveDID) {
      fullImage = original
      return
    }

    // 2. On disk miss, download and decrypt using authenticated path
    guard let deviceId = await resolveActorDeviceId(effectiveDID: effectiveDID) else { return }

    do {
      let (responseCode, output) = try await appState.client.blue.catbird.chat.getBlob(
        input: .init(actorDeviceId: deviceId, blobId: imageEmbed.blobId)
      )

      guard (200...299).contains(responseCode), let output else { return }
      let ciphertext = output.data

      let plaintext = try BlobCrypto.decrypt(
        ciphertext: ciphertext,
        key: imageEmbed.key,
        iv: imageEmbed.iv,
        expectedSHA256: imageEmbed.sha256
      )

      await MLSImageCache.shared.put(blobId: imageEmbed.blobId, userDID: effectiveDID, imageData: plaintext)

      if let decodedOriginal = PlatformImage(data: plaintext) {
        fullImage = decodedOriginal
      }
    } catch {
      // Retain thumbnail display on download/decrypt failure
    }
  }

  private func resolveActorDeviceId(effectiveDID: String) async -> String? {
    if let deviceUuid = try? MLSOrchestratorCredentialAdapter().getDeviceUuid(userDid: effectiveDID),
       !deviceUuid.isEmpty, UUID(uuidString: deviceUuid) != nil {
      return deviceUuid
    }
    if let conversationManager = await appState.getMLSConversationManager() {
      if conversationManager.protocolAuthorityMode == .rustFull {
        if let registered = try? await conversationManager.registeredDeviceInfoForPushTokenRegistration(),
           !registered.deviceId.isEmpty, UUID(uuidString: registered.deviceId) != nil {
          return registered.deviceId
        }
      } else {
        if let registered = await conversationManager.mlsClient.getDeviceInfo(for: effectiveDID),
           !registered.deviceId.isEmpty, UUID(uuidString: registered.deviceId) != nil {
          return registered.deviceId
        }
      }
    }
    let normalizedUserDid = effectiveDID.trimmingCharacters(in: .whitespacesAndNewlines)
    let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? .standard
    if let data = sharedDefaults.data(forKey: "blue.catbird.mls.deviceInfoByUser"),
       let decoded = try? JSONDecoder().decode([String: MLSDeviceManager.UserDeviceInfo].self, from: data),
       let info = decoded[normalizedUserDid],
       !info.deviceId.isEmpty, UUID(uuidString: info.deviceId) != nil {
      return info.deviceId
    }
    return nil
  }

  // MARK: - Controls

  @ViewBuilder
  private var controlsOverlay: some View {
    VStack {
      // Top bar
      HStack {
        Spacer()

        if liveTextSupported {
          Button {
            liveTextEnabled.toggle()
          } label: {
            Image(systemName: liveTextEnabled ? "text.viewfinder.fill" : "text.viewfinder")
              .font(.title3)
              .foregroundColor(.white)
              .frame(width: 44, height: 44)
          }
        }

        Button {
          shareImage()
        } label: {
          Image(systemName: "square.and.arrow.up")
            .font(.title3)
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
        }

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.title3)
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
        }
      }
      .padding(.horizontal, 8)
      .background(
        LinearGradient(
          colors: [.black.opacity(0.5), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea(edges: .top)
      )

      Spacer()

      // Alt text at bottom
      if let alt = altText, !alt.isEmpty {
        VStack(spacing: 4) {
          Text(alt)
            .appFont(AppTextRole.caption)
            .lineLimit(isAltTextExpanded ? nil : 2)
            .multilineTextAlignment(.leading)

          if !isAltTextExpanded {
            Text("Show More")
              .appFont(AppTextRole.caption2)
              .foregroundColor(.accentColor)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Material.ultraThin)
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.bottom, 16)
        .onTapGesture {
          withAnimation(.easeInOut(duration: 0.2)) {
            isAltTextExpanded.toggle()
          }
        }
      }
    }
  }

  // MARK: - Share

  private func shareImage() {
    let imageToShare = displayImage
    #if os(iOS)
    guard let imageData = imageToShare.jpegData(compressionQuality: 0.95) else { return }

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).jpg")

    do {
      try imageData.write(to: tempURL)

      guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first(where: { $0.isKeyWindow }),
            let rootVC = window.rootViewController?.topmostPresentedViewController()
      else { return }

      let activityVC = UIActivityViewController(
        activityItems: [tempURL],
        applicationActivities: nil
      )

      if let popover = activityVC.popoverPresentationController {
        popover.sourceView = rootVC.view
        popover.sourceRect = CGRect(
          x: rootVC.view.bounds.midX,
          y: rootVC.view.bounds.midY,
          width: 0, height: 0
        )
        popover.permittedArrowDirections = []
      }

      rootVC.present(activityVC, animated: true)

      DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        try? FileManager.default.removeItem(at: tempURL)
      }
    } catch {}
    #else
    guard let imageData = imageToShare.jpegImageData(compressionQuality: 0.95) else { return }

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).jpg")

    do {
      try imageData.write(to: tempURL)
      NSWorkspace.shared.activateFileViewerSelecting([tempURL])
    } catch {}
    #endif
  }
}

#if os(iOS)
extension ZoomableImageViewController {
  /// Updates the displayed image with full-resolution original, preserving zoom/scroll position
  /// and re-running Live Text analysis if supported.
  @MainActor
  func updateImage(_ newImage: UIImage) {
    loadViewIfNeeded()
    guard let scrollView = view.subviews.compactMap({ $0 as? UIScrollView }).first,
          let imageView = scrollView.subviews.compactMap({ $0 as? UIImageView }).first else {
      return
    }

    // Avoid re-running work for the same decoded image.
    if let current = imageView.image {
      if current === newImage { return }
      if current.size == newImage.size,
         let currentCG = current.cgImage,
         let newCG = newImage.cgImage,
         currentCG === newCG {
        return
      }
    }

    let currentZoomScale = scrollView.zoomScale
    let currentContentOffset = scrollView.contentOffset

    let hadPlaceholder = imageView.image != nil
    if hadPlaceholder {
      UIView.transition(
        with: imageView,
        duration: 0.2,
        options: [.transitionCrossDissolve, .allowUserInteraction],
        animations: {
          imageView.image = newImage
        },
        completion: { _ in
          scrollView.zoomScale = currentZoomScale
          scrollView.contentOffset = currentContentOffset
        }
      )
    } else {
      imageView.image = newImage
    }

    scrollView.zoomScale = currentZoomScale
    scrollView.contentOffset = currentContentOffset

    // Trigger Live Text analysis if interaction exists
    if let interaction = imageView.interactions.compactMap({ $0 as? ImageAnalysisInteraction }).first {
      Task {
        do {
          let analyzer = ImageAnalyzer()
          let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
          let analysis = try await analyzer.analyze(newImage, configuration: configuration)
          await MainActor.run {
            interaction.analysis = analysis
          }
        } catch {
          print("Failed to analyze image: \(error)")
        }
      }
    }
  }
}

private struct MLSZoomableUIImageWrapper: UIViewControllerRepresentable {
  let uiImage: UIImage
  let altText: String?
  @Binding var liveTextEnabled: Bool
  var liveTextSupported: Bool

  func makeUIViewController(context: Context) -> ZoomableImageViewController {
    ZoomableImageViewController(
      uiImage: uiImage,
      altText: altText,
      liveTextSupported: liveTextSupported
    )
  }

  func updateUIViewController(_ uiViewController: ZoomableImageViewController, context: Context) {
    uiViewController.updateImage(uiImage)
    uiViewController.updateLiveText(enabled: liveTextEnabled)
  }
}
#endif
