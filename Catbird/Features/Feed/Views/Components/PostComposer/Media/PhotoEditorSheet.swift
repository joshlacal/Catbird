//
//  PhotoEditorSheet.swift
//  Catbird
//
//  Created by Claude Code
//

import SwiftUI

#if os(iOS)
import Mantis
import UIKit

/// A sheet that presents Mantis crop editor for editing images with custom toolbar
struct PhotoEditorSheet: View {
  let image: UIImage
  let onComplete: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var croppedImage: UIImage?

  var body: some View {
    ZStack {
      // Mantis crop view controller
      MantisWrapper(
        image: image,
        onCrop: { cropped in
          croppedImage = cropped
        },
        onCancel: {
          dismiss()
        }
      )
      .ignoresSafeArea()

      // Custom toolbar overlay with material styling
      VStack {
        Spacer()

        HStack(spacing: 16) {
          // Cancel button
          Button(action: {
            dismiss()
          }) {
            HStack(spacing: 8) {
              Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
              Text("Cancel")
                .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
          }
          .background(.ultraThinMaterial)
          .clipShape(Capsule())

          Spacer()

          // Done button with checkmark
          Button(action: {
            if let cropped = croppedImage {
              onComplete(cropped)
            }
            dismiss()
          }) {
            HStack(spacing: 8) {
              Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .semibold))
              Text("Done")
                .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
          }
          .background(.blue.gradient)
          .clipShape(Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
      }
    }
    .interactiveDismissDisabled(true) // Prevent swipe-to-dismiss
  }
}

/// Internal wrapper for Mantis crop controller
private struct MantisWrapper: UIViewControllerRepresentable {
  let image: UIImage
  let onCrop: (UIImage) -> Void
  let onCancel: () -> Void

  func makeUIViewController(context: Context) -> some UIViewController {
    var config = Mantis.Config()

    // Enable rotation
    config.showRotationDial = true

    // Set up preset ratios for Mantis 1.9.0
    config.presetFixedRatioType = .canUseMultiplePresetFixedRatio(defaultRatio: 0)

    let cropViewController = Mantis.cropViewController(image: image, config: config)
    cropViewController.delegate = context.coordinator

    // Hide Mantis default toolbar since we're using our own
      cropViewController.config.cropToolbarConfig.toolbarButtonOptions = ToolbarButtonOptions.all.subtracting([.all])

    return cropViewController
  }

  func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
    // No updates needed
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onCrop: onCrop, onCancel: onCancel)
  }

  class Coordinator: NSObject, CropViewControllerDelegate {
    let onCrop: (UIImage) -> Void
    let onCancel: () -> Void

    init(onCrop: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
      self.onCrop = onCrop
      self.onCancel = onCancel
    }

    func cropViewControllerDidCrop(
      _ cropViewController: CropViewController,
      cropped: UIImage,
      transformation: Transformation,
      cropInfo: CropInfo
    ) {
      onCrop(cropped)
    }

    func cropViewControllerDidCancel(
      _ cropViewController: CropViewController,
      original: UIImage
    ) {
      onCancel()
    }

    func cropViewControllerDidFailToCrop(
      _ cropViewController: CropViewController,
      original: UIImage
    ) {
      onCancel()
    }

    func cropViewControllerDidBeginResize(
      _ cropViewController: CropViewController
    ) {
      // Optional: track analytics
    }

    func cropViewControllerDidEndResize(
      _ cropViewController: CropViewController,
      original: UIImage,
      cropInfo: CropInfo
    ) {
      // Optional: track analytics
    }
  }
}

#elseif os(macOS)

/// Placeholder for macOS - photo editing not available on macOS yet
struct PhotoEditorSheet: View {
  let image: NSImage
  let onComplete: (NSImage) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 20) {
      Text("Photo Editing")
        .font(.title)

      Text("Photo editing is currently only available on iOS")
        .foregroundStyle(.secondary)

      Button("Close") {
        dismiss()
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(width: 400, height: 300)
  }
}

#endif
