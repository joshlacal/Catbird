#if os(iOS)
import SwiftUI
import UIKit
import os

private let cameraCaptureLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "Catbird",
  category: "CameraCapture"
)

struct CameraCaptureView: UIViewControllerRepresentable {
  let mode: CameraCaptureMode
  let onCapture: (CapturedMedia) -> Void
  let onCancel: () -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    switch mode {
    case .photo:
      picker.cameraCaptureMode = .photo
      picker.mediaTypes = ["public.image"]
    case .video:
      picker.cameraCaptureMode = .video
      picker.mediaTypes = ["public.movie"]
      picker.videoQuality = .typeHigh
    }
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let parent: CameraCaptureView

    init(parent: CameraCaptureView) {
      self.parent = parent
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage,
         let data = image.jpegData(compressionQuality: 0.9) {
        cameraCaptureLogger.info("Captured photo with \(data.count) bytes")
        parent.onCapture(.photo(data))
        return
      }

      guard let sourceURL = info[.mediaURL] as? URL else {
        cameraCaptureLogger.error("Capture completed without usable media")
        parent.onCancel()
        return
      }

      let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
      let destinationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(fileExtension)
      do {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        cameraCaptureLogger.info("Captured video into app-owned temporary storage")
        parent.onCapture(.video(destinationURL))
      } catch {
        cameraCaptureLogger.error("Failed to preserve captured video: \(error.localizedDescription)")
        parent.onCancel()
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      cameraCaptureLogger.info("Camera capture cancelled")
      parent.onCancel()
    }
  }
}
#endif
