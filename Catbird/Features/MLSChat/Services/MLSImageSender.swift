import CatbirdMLSCore
import CryptoKit
import Foundation
import OSLog
import Petrel
import PhotosUI
import SwiftUI
import UIKit

#if os(iOS)

  private let mlsImageSenderLogger = Logger(subsystem: "blue.catbird", category: "MLSImageSender")
  private let maxBlobBytes = 10 * 1024 * 1024

  @Observable
  final class MLSImageSender {
    var isUploading = false
    var uploadError: String?

    private let client: ATProtoClient

    init(client: ATProtoClient) {
      self.client = client
    }

    // MARK: - Public

    /// Process a selected photo into an encrypted blob and return the embed.
    /// Preserves the original image format when possible. If the image exceeds
    /// the 10 MB server limit, it is progressively resized (PNG stays PNG,
    /// lossy formats are re-encoded as JPEG).
    func processImage(from item: PhotosPickerItem, convoId: String) async -> MLSImageEmbed? {
      isUploading = true
      uploadError = nil
      defer { isUploading = false }

      do {
        guard let imageData = try await item.loadTransferable(type: Data.self) else {
          uploadError = "Could not load image"
          return nil
        }

        guard let uiImage = UIImage(data: imageData) else {
          uploadError = "Invalid image format"
          return nil
        }

        let originalWidth = Int(uiImage.size.width * uiImage.scale)
        let originalHeight = Int(uiImage.size.height * uiImage.scale)
        let detectedType = Self.detectMimeType(from: imageData)

        let finalData: Data
        let contentType: String
        var finalWidth = originalWidth
        var finalHeight = originalHeight

        if imageData.count <= maxBlobBytes {
          // Original fits — ship as-is (preserves HEIC, GIF, exact PNG, etc.)
          finalData = imageData
          contentType = detectedType
        } else if detectedType == "image/png" {
          guard let result = Self.fitPNG(uiImage, maxBytes: maxBlobBytes) else {
            uploadError = "Image too large (max 10 MB)"
            return nil
          }
          finalData = result.data
          finalWidth = result.width
          finalHeight = result.height
          contentType = "image/png"
        } else {
          // JPEG / HEIC / other — quality reduction then dimension reduction → JPEG
          guard let result = Self.fitJPEG(uiImage, maxBytes: maxBlobBytes) else {
            uploadError = "Image too large (max 10 MB)"
            return nil
          }
          finalData = result.data
          finalWidth = result.width
          finalHeight = result.height
          contentType = "image/jpeg"
        }

        mlsImageSenderLogger.info(
          "Image ready: \(finalWidth)x\(finalHeight), \(finalData.count) bytes, \(contentType)")

        let encrypted = try BlobCrypto.encrypt(plaintext: finalData)

        let (responseCode, output) = try await client.blue.catbird.mlschat.uploadBlob(
          data: encrypted.ciphertext,
          mimeType: "application/octet-stream",
          convoId: convoId,
          stripMetadata: false
        )

        guard (200...299).contains(responseCode), let output else {
          if responseCode == 413 {
            uploadError = "Storage quota exceeded. Delete old images or wait for them to expire."
          } else {
            uploadError = "Image upload failed (HTTP \(responseCode))"
          }
          return nil
        }

        mlsImageSenderLogger.info("Uploaded image blob \(output.blobId)")

        return MLSImageEmbed(
          blobId: output.blobId,
          key: encrypted.key,
          iv: encrypted.iv,
          sha256: encrypted.sha256,
          contentType: contentType,
          size: finalData.count,
          width: finalWidth,
          height: finalHeight,
          altText: nil,
          blurhash: nil
        )
      } catch {
        mlsImageSenderLogger.error("Image processing error: \(error.localizedDescription)")
        uploadError = "Failed to send image: \(error.localizedDescription)"
        return nil
      }
    }

    // MARK: - Format detection

    private static func detectMimeType(from data: Data) -> String {
      guard data.count >= 12 else { return "image/jpeg" }
      let h = [UInt8](data.prefix(12))
      if h[0] == 0x89, h[1] == 0x50, h[2] == 0x4E, h[3] == 0x47 { return "image/png" }
      if h[0] == 0xFF, h[1] == 0xD8 { return "image/jpeg" }
      if h[0] == 0x47, h[1] == 0x49, h[2] == 0x46 { return "image/gif" }
      // HEIC / HEIF: ftyp box at byte 4
      if h[4] == 0x66, h[5] == 0x74, h[6] == 0x79, h[7] == 0x70 { return "image/heic" }
      return "image/jpeg"
    }

    // MARK: - Fit helpers

    private struct FitResult {
      let data: Data
      let width: Int
      let height: Int
    }

    /// Progressively shrink a PNG until it fits.
    private static func fitPNG(_ image: UIImage, maxBytes: Int) -> FitResult? {
      let pw = image.size.width * image.scale
      let ph = image.size.height * image.scale
      var scale: CGFloat = 0.75
      for _ in 0..<8 {
        let w = pw * scale
        let h = ph * scale
        if let resized = resizeImage(image, to: CGSize(width: w, height: h)),
          let data = resized.pngData(), data.count <= maxBytes
        {
          return FitResult(data: data, width: Int(w), height: Int(h))
        }
        scale *= 0.75
      }
      return nil
    }

    /// Try quality reduction at full res, then progressive dimension + quality reduction → JPEG.
    private static func fitJPEG(_ image: UIImage, maxBytes: Int) -> FitResult? {
      let pw = image.size.width * image.scale
      let ph = image.size.height * image.scale

      // Quality reduction at original resolution
      for q: CGFloat in [0.8, 0.6, 0.4] {
        if let data = image.jpegData(compressionQuality: q), data.count <= maxBytes {
          return FitResult(data: data, width: Int(pw), height: Int(ph))
        }
      }

      // Dimension + quality reduction
      var scale: CGFloat = 0.75
      for _ in 0..<6 {
        let w = pw * scale
        let h = ph * scale
        if let resized = resizeImage(image, to: CGSize(width: w, height: h)) {
          for q: CGFloat in [0.8, 0.5] {
            if let data = resized.jpegData(compressionQuality: q), data.count <= maxBytes {
              return FitResult(data: data, width: Int(w), height: Int(h))
            }
          }
        }
        scale *= 0.75
      }
      return nil
    }

    private static func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage? {
      let renderer = UIGraphicsImageRenderer(size: size)
      return renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
    }
  }

#endif
