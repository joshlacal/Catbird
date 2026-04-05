import SensitiveContentAnalysis

/// On-device content analysis for incoming MLS images.
/// Verdicts are local-only and never transmitted off-device.
actor ImageContentAnalyzer {
  static let shared = ImageContentAnalyzer()

  private let analyzer = SCSensitivityAnalyzer()

  var isAvailable: Bool {
    analyzer.analysisPolicy != .disabled
  }

  var policy: SCSensitivityAnalysisPolicy {
    analyzer.analysisPolicy
  }

  /// Analyze an image for sensitive content.
  /// Always runs analysis regardless of system setting; the app controls intervention behavior.
  func analyze(_ image: CGImage) async -> ImageAnalysisResult {
    do {
      let analysis = try await analyzer.analyzeImage(image)
      if analysis.isSensitive {
        return .sensitive(policy: analyzer.analysisPolicy)
      }
      return .safe
    } catch {
      // Analysis failure should not block image display
      return .notAvailable
    }
  }
}

enum ImageAnalysisResult: Sendable {
  case safe
  case sensitive(policy: SCSensitivityAnalysisPolicy)
  case notAvailable
}
