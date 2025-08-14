//
//  HeightValidationManager.swift
//  Catbird
//
//  Runtime validation system for PostHeightCalculator accuracy
//

import UIKit
import Foundation
import Petrel
import os

/// Validation result for a single post height calculation
struct HeightValidationResult {
  let postId: String
  let estimatedHeight: CGFloat
  let actualHeight: CGFloat
  let difference: CGFloat
  let percentageError: CGFloat
  let timestamp: Date
  let feedType: String
  let hasImages: Bool
  let hasVideos: Bool
  let hasExternalEmbed: Bool
  let hasRecordEmbed: Bool
  let textLength: Int
  
  var isSignificantError: Bool {
    // Consider >10% error or >20pt absolute error as significant
    return abs(percentageError) > 10.0 || abs(difference) > 20.0
  }
}

/// Statistics for height validation across multiple posts
struct ValidationStatistics {
  let totalValidations: Int
  let averageError: CGFloat
  let averageAbsoluteError: CGFloat
  let maxError: CGFloat
  let minError: CGFloat
  let significantErrors: Int
  let averageEstimatedHeight: CGFloat
  let averageActualHeight: CGFloat
  
  var accuracyPercentage: CGFloat {
    let significantErrorRate = CGFloat(significantErrors) / CGFloat(max(totalValidations, 1))
    return max(0, (1.0 - significantErrorRate) * 100.0)
  }
}

/// Manager for validating PostHeightCalculator accuracy at runtime
@MainActor
class HeightValidationManager: ObservableObject {
  
  // MARK: - Properties
  
  private let logger = Logger(subsystem: "blue.catbird", category: "HeightValidation")
  private let heightCalculator = PostHeightCalculator.shared
  
  /// Storage for validation results
  private var validationResults: [HeightValidationResult] = []
  
  /// Maximum number of results to keep in memory
  private let maxResults = 1000
  
  /// Flag to enable/disable validation
  @Published var isValidationEnabled = false
  
  /// Current validation statistics
  @Published var currentStatistics: ValidationStatistics?
  
  // MARK: - Public API
  
  /// Validate height calculation for a post and its actual rendered cell
  func validateHeight(
    for post: AppBskyFeedDefs.PostView,
    actualHeight: CGFloat,
    feedType: String,
    mode: PostHeightCalculator.CalculationMode = .compact
  ) {
    guard isValidationEnabled else { return }
    
    // Get estimated height from calculator
    let estimatedHeight = heightCalculator.calculateHeight(for: post, mode: mode)
    
    // Calculate difference and percentage error
    let difference = actualHeight - estimatedHeight
    let percentageError = actualHeight > 0 ? (difference / actualHeight) * 100.0 : 0
    
    // Extract post content characteristics
    let hasImages = extractHasImages(from: post)
    let hasVideos = extractHasVideos(from: post)
    let hasExternalEmbed = extractHasExternalEmbed(from: post)
    let hasRecordEmbed = extractHasRecordEmbed(from: post)
    let textLength = extractTextLength(from: post)
    
    // Create validation result
    let result = HeightValidationResult(
      postId: post.uri.uriString(),
      estimatedHeight: estimatedHeight,
      actualHeight: actualHeight,
      difference: difference,
      percentageError: percentageError,
      timestamp: Date(),
      feedType: feedType,
      hasImages: hasImages,
      hasVideos: hasVideos,
      hasExternalEmbed: hasExternalEmbed,
      hasRecordEmbed: hasRecordEmbed,
      textLength: textLength
    )
    
    // Store result
    addValidationResult(result)
    
    // Log significant errors
    if result.isSignificantError {
      logger.warning("📏 Significant height error - Post: \(post.uri.uriString().suffix(12)), Estimated: \(estimatedHeight), Actual: \(actualHeight), Error: \(String(format: "%.1f", percentageError))%")
    } else {
      logger.debug("📏 Height validation - Post: \(post.uri.uriString().suffix(12)), Estimated: \(estimatedHeight), Actual: \(actualHeight), Error: \(String(format: "%.1f", percentageError))%")
    }
    
    // Update statistics
    updateStatistics()
  }
  
  /// Generate and return a comprehensive validation report
  func generateReport() -> String {
    guard !validationResults.isEmpty else {
      return "No validation data available"
    }
    
    let stats = calculateStatistics()
    let recentResults = validationResults.suffix(50) // Last 50 results
    let significantErrors = validationResults.filter { $0.isSignificantError }.suffix(10) // Last 10 significant errors
    
    var report = """
    
    # PostHeightCalculator Validation Report
    
    ## Overall Statistics
    - Total validations: \(stats.totalValidations)
    - Accuracy: \(String(format: "%.1f", stats.accuracyPercentage))%
    - Average error: \(String(format: "%.1f", stats.averageError))pt (\(String(format: "%.1f", abs(stats.averageError)))%)
    - Average absolute error: \(String(format: "%.1f", stats.averageAbsoluteError))pt
    - Significant errors: \(stats.significantErrors)/\(stats.totalValidations) (\(String(format: "%.1f", CGFloat(stats.significantErrors)/CGFloat(stats.totalValidations)*100))%)
    - Average estimated height: \(String(format: "%.1f", stats.averageEstimatedHeight))pt
    - Average actual height: \(String(format: "%.1f", stats.averageActualHeight))pt
    
    ## Error Analysis by Content Type
    """
    
    // Analysis by content type
    let imageResults = validationResults.filter { $0.hasImages }
    let videoResults = validationResults.filter { $0.hasVideos }
    let embedResults = validationResults.filter { $0.hasExternalEmbed || $0.hasRecordEmbed }
    let textOnlyResults = validationResults.filter { !$0.hasImages && !$0.hasVideos && !$0.hasExternalEmbed && !$0.hasRecordEmbed }
    
    if !imageResults.isEmpty {
      let imageError = imageResults.map { abs($0.percentageError) }.reduce(0, +) / CGFloat(imageResults.count)
      report += "\n- Posts with images: \(imageResults.count) posts, avg error: \(String(format: "%.1f", imageError))%"
    }
    
    if !videoResults.isEmpty {
      let videoError = videoResults.map { abs($0.percentageError) }.reduce(0, +) / CGFloat(videoResults.count)
      report += "\n- Posts with videos: \(videoResults.count) posts, avg error: \(String(format: "%.1f", videoError))%"
    }
    
    if !embedResults.isEmpty {
      let embedError = embedResults.map { abs($0.percentageError) }.reduce(0, +) / CGFloat(embedResults.count)
      report += "\n- Posts with embeds: \(embedResults.count) posts, avg error: \(String(format: "%.1f", embedError))%"
    }
    
    if !textOnlyResults.isEmpty {
      let textError = textOnlyResults.map { abs($0.percentageError) }.reduce(0, +) / CGFloat(textOnlyResults.count)
      report += "\n- Text-only posts: \(textOnlyResults.count) posts, avg error: \(String(format: "%.1f", textError))%"
    }
    
    // Recent significant errors
    if !significantErrors.isEmpty {
      report += "\n\n## Recent Significant Errors\n"
      for error in significantErrors {
        let contentType = getContentTypeDescription(for: error)
        report += "\n- \(error.postId.suffix(12)): \(String(format: "%.1f", error.estimatedHeight))pt → \(String(format: "%.1f", error.actualHeight))pt (\(String(format: "%.1f", error.percentageError))%) [\(contentType)]"
      }
    }
    
    // Performance recommendations
    report += "\n\n## Recommendations\n"
    
    if stats.accuracyPercentage < 85 {
      report += "\n⚠️ Low accuracy detected. Consider reviewing PostHeightCalculator constants."
    }
    
    if imageResults.count > 0 && (imageResults.map { abs($0.percentageError) }.reduce(0, +) / CGFloat(imageResults.count)) > 15 {
      report += "\n📸 Image height calculations may need adjustment."
    }
    
    if embedResults.count > 0 && (embedResults.map { abs($0.percentageError) }.reduce(0, +) / CGFloat(embedResults.count)) > 20 {
      report += "\n🔗 Embed height calculations may need adjustment."
    }
    
    if abs(stats.averageError) > 10 {
      report += "\n📏 Systematic bias detected. Check base height calculations."
    }
    
    report += "\n\n---\nGenerated: \(Date())\n"
    
    return report
  }
  
  /// Clear all validation results
  func clearResults() {
    validationResults.removeAll()
    currentStatistics = nil
    logger.info("📏 Cleared all validation results")
  }
  
  /// Export results as JSON for external analysis
  func exportResults() -> Data? {
    do {
      return try JSONEncoder().encode(validationResults)
    } catch {
      logger.error("📏 Failed to export validation results: \(error)")
      return nil
    }
  }
  
  // MARK: - Private Methods
  
  private func addValidationResult(_ result: HeightValidationResult) {
    validationResults.append(result)
    
    // Trim results if needed
    if validationResults.count > maxResults {
      validationResults.removeFirst(validationResults.count - maxResults)
    }
  }
  
  private func updateStatistics() {
    currentStatistics = calculateStatistics()
  }
  
  private func calculateStatistics() -> ValidationStatistics {
    guard !validationResults.isEmpty else {
      return ValidationStatistics(
        totalValidations: 0,
        averageError: 0,
        averageAbsoluteError: 0,
        maxError: 0,
        minError: 0,
        significantErrors: 0,
        averageEstimatedHeight: 0,
        averageActualHeight: 0
      )
    }
    
    let totalValidations = validationResults.count
    let errors = validationResults.map { $0.difference }
    let absoluteErrors = validationResults.map { abs($0.difference) }
    let significantErrors = validationResults.filter { $0.isSignificantError }.count
    
    let averageError = errors.reduce(0, +) / CGFloat(totalValidations)
    let averageAbsoluteError = absoluteErrors.reduce(0, +) / CGFloat(totalValidations)
    let maxError = errors.max() ?? 0
    let minError = errors.min() ?? 0
    
    let averageEstimatedHeight = validationResults.map { $0.estimatedHeight }.reduce(0, +) / CGFloat(totalValidations)
    let averageActualHeight = validationResults.map { $0.actualHeight }.reduce(0, +) / CGFloat(totalValidations)
    
    return ValidationStatistics(
      totalValidations: totalValidations,
      averageError: averageError,
      averageAbsoluteError: averageAbsoluteError,
      maxError: maxError,
      minError: minError,
      significantErrors: significantErrors,
      averageEstimatedHeight: averageEstimatedHeight,
      averageActualHeight: averageActualHeight
    )
  }
  
  // MARK: - Content Analysis Helpers
  
  private func extractHasImages(from post: AppBskyFeedDefs.PostView) -> Bool {
    guard let embed = post.embed else { return false }
    
    switch embed {
    case .appBskyEmbedImagesView:
      return true
    case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
      if case .appBskyEmbedImagesView = recordWithMedia.media {
        return true
      }
      return false
    default:
      return false
    }
  }
  
  private func extractHasVideos(from post: AppBskyFeedDefs.PostView) -> Bool {
    guard let embed = post.embed else { return false }
    
    switch embed {
    case .appBskyEmbedVideoView:
      return true
    case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
      if case .appBskyEmbedVideoView = recordWithMedia.media {
        return true
      }
      return false
    default:
      return false
    }
  }
  
  private func extractHasExternalEmbed(from post: AppBskyFeedDefs.PostView) -> Bool {
    guard let embed = post.embed else { return false }
    
    switch embed {
    case .appBskyEmbedExternalView:
      return true
    case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
      if case .appBskyEmbedExternalView = recordWithMedia.media {
        return true
      }
      return false
    default:
      return false
    }
  }
  
  private func extractHasRecordEmbed(from post: AppBskyFeedDefs.PostView) -> Bool {
    guard let embed = post.embed else { return false }
    
    switch embed {
    case .appBskyEmbedRecordView, .appBskyEmbedRecordWithMediaView:
      return true
    default:
      return false
    }
  }
  
  private func extractTextLength(from post: AppBskyFeedDefs.PostView) -> Int {
    guard case .knownType(let postObj) = post.record,
          let feedPost = postObj as? AppBskyFeedPost else {
      return 0
    }
    return feedPost.text.count
  }
  
  private func getContentTypeDescription(for result: HeightValidationResult) -> String {
    var types: [String] = []
    
    if result.hasImages { types.append("images") }
    if result.hasVideos { types.append("videos") }
    if result.hasExternalEmbed { types.append("external") }
    if result.hasRecordEmbed { types.append("record") }
    if types.isEmpty && result.textLength > 0 { types.append("text") }
    if types.isEmpty { types.append("unknown") }
    
    return types.joined(separator: ", ")
  }
}

// MARK: - HeightValidationResult Codable

extension HeightValidationResult: Codable {
  // Automatically conforms to Codable since all properties are Codable
}