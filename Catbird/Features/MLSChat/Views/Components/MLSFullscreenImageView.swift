import SwiftUI

#if os(iOS)
import VisionKit
import UIKit

/// Fullscreen image viewer for MLS chat images.
/// Reuses ZoomableImageViewController from ViewImageGridView for consistent zoom behavior.
struct MLSFullscreenImageView: View {
  let image: UIImage
  let altText: String?

  @Environment(\.dismiss) private var dismiss
  @State private var showControls = true
  @State private var isAltTextExpanded = false
  @State private var liveTextEnabled = false
  @State private var liveTextSupported = ImageAnalyzer.isSupported

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      ZoomableUIImageWrapper(
        uiImage: image,
        altText: altText,
        liveTextEnabled: $liveTextEnabled,
        liveTextSupported: liveTextSupported
      )
      .ignoresSafeArea()
      .onTapGesture {
        withAnimation { showControls.toggle() }
      }

      if showControls {
        controlsOverlay
      }
    }
    .statusBarHidden(!showControls)
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
    guard let imageData = image.jpegData(compressionQuality: 0.9) else { return }

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
  }
}

#endif
