//
//  OCRTextDetector.swift
//  Catbird
//
//  Created by Claude Code
//

import Foundation
import Vision
import CoreImage

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Represents a detected text region with its bounding box and content
struct DetectedTextRegion: Identifiable {
  let id = UUID()
  let text: String
  let boundingBox: CGRect
  let confidence: Float
}

/// Actor for thread-safe OCR text detection using Vision framework
actor OCRTextDetector {

  /// Detects text in an image using Vision framework
  /// - Parameter imageData: Raw image data to process
  /// - Returns: Array of detected text regions with bounding boxes
  /// - Throws: OCRError if processing fails
  func detectText(in imageData: Data) async throws -> [DetectedTextRegion] {
    #if canImport(UIKit)
    guard let image = UIImage(data: imageData),
          let cgImage = image.cgImage else {
      throw OCRError.invalidImageData
    }
    #elseif canImport(AppKit)
    guard let image = NSImage(data: imageData),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw OCRError.invalidImageData
    }
    #endif

    return try await withCheckedThrowingContinuation { continuation in
      let request = VNRecognizeTextRequest { request, error in
        if let error = error {
          continuation.resume(throwing: OCRError.visionProcessingFailed(error))
          return
        }

        guard let observations = request.results as? [VNRecognizedTextObservation] else {
          continuation.resume(throwing: OCRError.noTextDetected)
          return
        }

        let regions = observations.compactMap { observation -> DetectedTextRegion? in
          guard let candidate = observation.topCandidates(1).first else {
            return nil
          }

          return DetectedTextRegion(
            text: candidate.string,
            boundingBox: observation.boundingBox,
            confidence: candidate.confidence
          )
        }

        continuation.resume(returning: regions)
      }

      // Configure for accurate text recognition
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true

      #if os(iOS)
      // Use automatic language detection on iOS
      request.automaticallyDetectsLanguage = true
      #endif

      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

      do {
        try handler.perform([request])
      } catch {
        continuation.resume(throwing: OCRError.visionProcessingFailed(error))
      }
    }
  }
}

/// Errors that can occur during OCR processing
enum OCRError: LocalizedError {
  case invalidImageData
  case visionProcessingFailed(Error)
  case noTextDetected

  var errorDescription: String? {
    switch self {
    case .invalidImageData:
      return "Unable to process image data"
    case .visionProcessingFailed(let error):
      return "Text detection failed: \(error.localizedDescription)"
    case .noTextDetected:
      return "No text detected in image"
    }
  }
}
