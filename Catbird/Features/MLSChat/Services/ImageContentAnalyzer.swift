import Foundation
import SensitiveContentAnalysis

/// On-device content analysis for incoming MLS images.
/// Verdicts are local-only and never transmitted off-device.
actor ImageContentAnalyzer {
  static let shared = ImageContentAnalyzer()

  private let analyzer = SCSensitivityAnalyzer()
  private let classificationCache: NSCache<NSString, NSNumber> = {
    let cache = NSCache<NSString, NSNumber>()
    cache.countLimit = 1000
    return cache
  }()

  var isAvailable: Bool {
    analyzer.analysisPolicy != .disabled
  }

  var policy: SCSensitivityAnalysisPolicy {
    analyzer.analysisPolicy
  }

  private func makeCacheKey(accountDID: String?, blobId: String?) -> String? {
    guard let accountDID = accountDID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !accountDID.isEmpty,
          let blobId = blobId?.trimmingCharacters(in: .whitespacesAndNewlines),
          !blobId.isEmpty else {
      return nil
    }
    return "\(accountDID)/\(blobId)"
  }

  /// Analyze an image for sensitive content.
  /// Caches only successful safe/sensitive classification (never notAvailable or policy/intervention).
  /// Derives current intervention on each lookup based on current policy.
  func analyze(
    _ image: CGImage,
    accountDID: String? = nil,
    blobId: String? = nil
  ) async -> ImageAnalysisResult {
    let cacheKey = makeCacheKey(accountDID: accountDID, blobId: blobId)
    if let cacheKey, let cached = classificationCache.object(forKey: cacheKey as NSString) {
      let isSensitive = cached.boolValue
      return isSensitive ? .sensitive(policy: analyzer.analysisPolicy) : .safe
    }

    guard let analysis = try? await analyzer.analyzeImage(image) else {
      return .notAvailable
    }
    if let cacheKey {
      classificationCache.setObject(NSNumber(value: analysis.isSensitive), forKey: cacheKey as NSString)
    }
    if analysis.isSensitive {
      return .sensitive(policy: analyzer.analysisPolicy)
    }
    return .safe
  }

  /// Purge classification cache
  func purgeAll() {
    classificationCache.removeAllObjects()
  }
}

enum ImageAnalysisResult: Sendable, Equatable {
  case safe
  case sensitive(policy: SCSensitivityAnalysisPolicy)
  case notAvailable
}
