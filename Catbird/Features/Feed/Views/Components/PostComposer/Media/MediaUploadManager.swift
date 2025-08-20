//
//  MediaUploadManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/24/25.
//

import AVFoundation
import Foundation
import OSLog
import Petrel
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Manages media upload operations including image and video processing
@Observable
final class MediaUploadManager {
  // MARK: - Properties

  private let client: ATProtoClient
  private let videoBaseURL = "https://video.bsky.app/xrpc"
  private let logger = Logger(subsystem: "blue.catbird", category: "MediaUploadManager")

  // Video upload state
  var isVideoUploading = false
  var videoUploadProgress: Double = 0
  var processingProgress: Double = 0
  var videoJobId: String?
  var videoError: String?
  var uploadStatus: VideoUploadStatus = .notStarted
  var uploadedBlob: Blob?

  // Task tracking for cancellation
  private var currentUploadTask: Task<Void, Error>?
  private var currentProcessingTask: Task<Void, Error>?

  // Video upload status enum
  enum VideoUploadStatus {
    case notStarted
    case uploading(progress: Double)
    case processing(progress: Double)
    case complete
    case failed(error: String)
    case cancelled
  }

  init(client: ATProtoClient) {
    self.client = client
  }

  // MARK: - Image Upload Methods

  /// Process image for upload - compress and optimize
  func processImageForUpload(_ data: Data) async throws -> Data {
    // Start with original data
    var processedData = data

    // Check if we need to convert format
    if checkImageFormat(data) == "HEIC" {
      if let converted = convertHEICToJPEG(data) {
        processedData = converted
      }
    }

    // Compress if needed (AT Protocol limit is 1MB)
    if let image = PlatformImage(data: processedData),
      let compressed = compressImage(image, maxSizeInBytes: 900_000) {
      processedData = compressed
    }

    return processedData
  }

  /// Upload an image blob to the server
  func uploadImageBlob(_ imageData: Data) async throws -> Blob {
    let processedData = try await processImageForUpload(imageData)

    let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
      data: processedData,
      mimeType: "image/jpeg",
      stripMetadata: true
    )

    guard responseCode == 200, let blob = blobOutput?.blob else {
      throw VideoUploadError.uploadFailed
    }

    return blob
  }

  // MARK: - Video Upload Methods
    /// Get authentication token for video operations
    private func getVideoAuthTokenForUploadLimits() async throws -> String {
      logger.debug("DEBUG: Requesting service auth token")
      let didValue = try await client.getDid()
      logger.debug("DEBUG: Using DID: \(didValue)")
      
      let serviceParams = ComAtprotoServerGetServiceAuth.Parameters(
        aud: try DID(didString: "did:web:video.bsky.app"),
        exp: Int(Date().timeIntervalSince1970) + 30 * 60,  // 30 minutes
        lxm: try NSID(nsidString: "app.bsky.video.getUploadLimits")
      )
      
      let (authCode, authData) = try await client.com.atproto.server.getServiceAuth(
        input: serviceParams)
      logger.debug("DEBUG: Service auth response code: \(authCode)")
      
      if authCode != 200 {
        logger.error("ERROR: Service auth request failed with code \(authCode)")
        throw VideoUploadError.authenticationFailed
      }
      
      guard let serviceAuth = authData else {
        logger.error("ERROR: Missing service auth data")
        throw VideoUploadError.authenticationFailed
      }
      
      logger.debug("DEBUG: Authentication successful, token obtained")
      return serviceAuth.token
    }

  /// Get authentication token for video operations
  private func getVideoAuthToken() async throws -> String {
    logger.debug("DEBUG: Requesting service auth token")
    let didValue = try await client.getDid()
    logger.debug("DEBUG: Using DID: \(didValue)")
    
    let serviceParams = ComAtprotoServerGetServiceAuth.Parameters(
        aud: try DID(didString: "did:web:\(await client.baseURL.host ?? "bsky.social")"),
      exp: Int(Date().timeIntervalSince1970) + 30 * 60,  // 30 minutes
        lxm: try NSID(nsidString: "com.atproto.repo.uploadBlob")
    )
    
    let (authCode, authData) = try await client.com.atproto.server.getServiceAuth(
      input: serviceParams)
    logger.debug("DEBUG: Service auth response code: \(authCode)")
    
    if authCode != 200 {
      logger.error("ERROR: Service auth request failed with code \(authCode)")
      throw VideoUploadError.authenticationFailed
    }
    
    guard let serviceAuth = authData else {
      logger.error("ERROR: Missing service auth data")
      throw VideoUploadError.authenticationFailed
    }
    
    logger.debug("DEBUG: Authentication successful, token obtained")
    return serviceAuth.token
  }
  
  /// Check upload limits from video server directly
  private func checkVideoUploadLimits(token: String) async throws -> (canUpload: Bool, error: String?) {
    logger.debug("DEBUG: Checking upload limits from server")
    
    let limitsURL = URL(string: "\(videoBaseURL)/app.bsky.video.getUploadLimits")!
    
    var request = URLRequest(url: limitsURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      logger.debug("Request: \(request.debugDescription)")
    
    let (data, response) = try await URLSession.shared.data(for: request)
      logger.debug("Received data: \(data), response: \(response)")
    guard let httpResponse = response as? HTTPURLResponse else {
      logger.error("ERROR: Invalid HTTP response type")
      throw VideoUploadError.processingFailed("Invalid response from server")
    }
    
    logger.debug("DEBUG: Upload limits response code: \(httpResponse.statusCode)")
    
    if httpResponse.statusCode != 200 {
      logger.error("ERROR: Failed to get upload limits, server responded with code \(httpResponse.statusCode)")
      throw VideoUploadError.processingFailed("Server error when checking upload limits (HTTP \(httpResponse.statusCode))")
    }
    
    let decoder = JSONDecoder()
    do {
      let limits = try decoder.decode(UploadLimitsResponse.self, from: data)
      return (limits.canUpload, limits.error)
    } catch {
      logger.error("ERROR: Failed to decode upload limits response: \(error)")
      throw VideoUploadError.processingFailed("Could not parse upload limits response")
    }
  }
  
  /// Structure for decoding upload limits response
  private struct UploadLimitsResponse: Decodable {
    let canUpload: Bool
    let error: String?
  }
    
    private func generateUniqueVideoName() -> String {
        let randomString = UUID().uuidString.prefix(12)
        return "\(randomString).mp4"
    }

  /// Start video upload process with additional validation
  @MainActor
  func uploadVideo(url: URL, alt: String? = nil) async throws -> Blob {
    logger.debug("DEBUG: Starting video upload for URL: \(url)")
    
    // Validate file exists
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      logger.error("ERROR: Video file does not exist at path: \(url.path)")
      throw VideoUploadError.processingFailed("Video file not found at specified location.")
    }
    
    // Check file size
    guard let fileAttributes = try? fileManager.attributesOfItem(atPath: url.path),
          let fileSize = fileAttributes[.size] as? NSNumber else {
      logger.error("ERROR: Could not determine video file size for path: \(url.path)")
      throw VideoUploadError.processingFailed("Could not determine video file size")
    }

    logger.debug("DEBUG: Video file size: \(fileSize.intValue) bytes")
    let maxVideoSize = 100 * 1024 * 1024  // 100MB
    if fileSize.intValue > maxVideoSize {
      logger.error("ERROR: Video exceeds maximum size of 100MB (actual: \(fileSize.intValue / 1024 / 1024)MB)")
      throw VideoUploadError.processingFailed("Video exceeds maximum size of 100MB")
    }
    
    // Validate video format
    do {
      let asset = AVURLAsset(url: url)
      logger.debug("DEBUG: Checking if asset is playable")
      let isPlayable = try await asset.load(.isPlayable)
      if !isPlayable {
        logger.error("ERROR: Video asset is not playable")
        throw VideoUploadError.processingFailed("Video format is not supported or file is corrupted")
      }
      
      // Verify it has a video track
      logger.debug("DEBUG: Checking for video tracks")
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      if videoTracks.isEmpty {
        logger.error("ERROR: No video tracks found in asset")
        throw VideoUploadError.processingFailed("No video content found in file")
      }
      
      // Get duration
      let duration = try await asset.load(.duration)
      let durationInSeconds = CMTimeGetSeconds(duration)
      logger.debug("DEBUG: Video duration: \(durationInSeconds) seconds")
      
      // Check duration limits if needed
      if durationInSeconds > 180 { // 3 minutes max (updated March 2025)
        logger.error("ERROR: Video duration exceeds maximum allowed (\(durationInSeconds) > 180 seconds)")
        throw VideoUploadError.processingFailed("Video exceeds maximum duration of 3 minutes")
      }
    } catch let assetError where !(assetError is VideoUploadError) {
      logger.error("ERROR: Failed to validate video asset: \(assetError)")
      throw VideoUploadError.processingFailed("Could not validate video: \(assetError.localizedDescription)")
    }

    // Get authentication token
    let authToken = try await getVideoAuthTokenForUploadLimits()
    
//     Check upload limits from server using direct URLSession
    let (canUpload, limitError) = try await checkVideoUploadLimits(token: authToken)
    
    guard canUpload else {
      let errorMessage = limitError ?? "Cannot upload videos at this time"
      logger.error("ERROR: Server does not allow video uploads: \(errorMessage)")
      throw VideoUploadError.processingFailed(errorMessage)
    }
    
    logger.debug("DEBUG: Video uploads are allowed, proceeding with upload")

    // Get DID for the upload URL
    let didValue = try await client.getDid()
    logger.debug("DEBUG: Using DID: \(didValue)")

    // Prepare upload
    logger.debug("DEBUG: Beginning video upload process")
    isVideoUploading = true
    videoUploadProgress = 0
    uploadStatus = .uploading(progress: 0)

    var uploadURL = URL(string: "\(videoBaseURL)/app.bsky.video.uploadVideo")!
    var urlComponents = URLComponents(url: uploadURL, resolvingAgainstBaseURL: true)!
    urlComponents.queryItems = [
      URLQueryItem(name: "did", value: didValue),
      URLQueryItem(name: "name", value: generateUniqueVideoName())
    ]
    uploadURL = urlComponents.url!
    logger.debug("DEBUG: Upload URL: \(uploadURL)")

    // Load video data
    logger.debug("DEBUG: Loading video data from URL: \(url)")
    let videoData: Data
    do {
      videoData = try Data(contentsOf: url)
      logger.debug("DEBUG: Successfully loaded video data, size: \(videoData.count) bytes")
    } catch {
      logger.error("ERROR: Failed to load video data: \(error)")
      isVideoUploading = false
      uploadStatus = .failed(error: "Could not load video data: \(error.localizedDescription)")
      throw VideoUploadError.processingFailed("Could not load video data: \(error.localizedDescription)")
    }
    
      let token = try await getVideoAuthToken()
      
    // Set up HTTP request
    logger.debug("DEBUG: Setting up HTTP request for video upload")
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
    request.setValue("\(videoData.count)", forHTTPHeaderField: "Content-Length")

    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil

    let progressDelegate = UploadProgressDelegate { [weak self] progress in
      Task { @MainActor in
        self?.videoUploadProgress = progress
        self?.uploadStatus = .uploading(progress: progress)
          self?.logger.debug("DEBUG: Upload progress: \(Int(progress * 100))%")
      }
    }

    // Perform upload
    logger.debug("DEBUG: Starting video data upload")
    let (responseData, response): (Data, URLResponse)
    do {
      (responseData, response) = try await URLSession.shared.upload(
        for: request,
        fromFile: url,
        delegate: progressDelegate
      )
      logger.debug("DEBUG: Upload request completed with response status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    } catch {
      logger.error("ERROR: Video upload network request failed: \(error)")
      isVideoUploading = false
      uploadStatus = .failed(error: "Network error during upload: \(error.localizedDescription)")
      throw VideoUploadError.uploadFailed
    }

    // Process response
    guard let httpResponse = response as? HTTPURLResponse else {
      logger.error("ERROR: Invalid HTTP response type")
      isVideoUploading = false
      uploadStatus = .failed(error: "Invalid response from server")
      throw VideoUploadError.uploadFailed
    }
    
    // Decode and log response body for debugging
    logger.debug("DEBUG: Server response body: \(String(data: responseData, encoding: .utf8) ?? "<binary data>")")
    
      if httpResponse.statusCode == 200 {
          logger.debug("DEBUG: Video upload successful, processing response")
          let decoder = JSONDecoder()
          do {
              let jobStatus = try decoder.decode(AppBskyVideoDefs.JobStatus.self, from: responseData)
              logger.debug("DEBUG: Job ID: \(jobStatus.jobId)")
              videoJobId = jobStatus.jobId
              return try await pollVideoJobStatus(jobId: jobStatus.jobId, token: authToken)
          } catch {
              logger.error("ERROR: Failed to decode job status from response: \(error)")
              isVideoUploading = false
              uploadStatus = .failed(error: "Invalid response format from server")
              throw VideoUploadError.processingFailed("Could not decode server response: \(error.localizedDescription)")
          }
      } else if httpResponse.statusCode == 409,
            let errorJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let jobId = errorJson["jobId"] as? String {
             logger.debug("DEBUG: Video was already processed, reusing job ID: \(jobId)")
             videoJobId = jobId
             return try await pollVideoJobStatus(jobId: jobId, token: token)
    } else {
      // Try to extract error message from response body
      let errorMessage: String
      if let errorJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
         let message = errorJson["message"] as? String {
        errorMessage = message
      } else {
        errorMessage = "HTTP \(httpResponse.statusCode)"
      }
      
      logger.error("ERROR: Video upload failed with HTTP status code \(httpResponse.statusCode): \(errorMessage)")
      isVideoUploading = false
      uploadStatus = .failed(error: "Upload failed: \(errorMessage)")
      throw VideoUploadError.uploadFailed
    }
  }

  /// Poll for video job status until complete using direct URLSession
  private func pollVideoJobStatus(jobId: String, token: String) async throws -> Blob {
    logger.debug("DEBUG: Polling video job status for jobId: \(jobId)")
    var attempts = 0
    let maxAttempts = 30  // Timeout after 5 minutes (30 * 10 seconds)
    var consecutiveErrorCount = 0
    let maxConsecutiveErrors = 3
    
    while attempts < maxAttempts {
      attempts += 1
      logger.debug("DEBUG: Polling attempt \(attempts) of \(maxAttempts)")

      do {
        // Prepare request
          var statusURL = URL(string: "\(videoBaseURL)/app.bsky.video.getJobStatus")!
          var urlComponents = URLComponents(url: statusURL, resolvingAgainstBaseURL: true)!
          urlComponents.queryItems = [URLQueryItem(name: "jobId", value: jobId)]
          statusURL = urlComponents.url!

          var request = URLRequest(url: statusURL)
          request.httpMethod = "GET"
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          
        // Perform request
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
          logger.error("ERROR: Invalid HTTP response type")
          throw VideoUploadError.processingFailed("Invalid response from server")
        }
        
        logger.debug("DEBUG: Job status response code: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
          logger.error("ERROR: Job status request returned HTTP \(httpResponse.statusCode)")
          consecutiveErrorCount += 1
          
          if consecutiveErrorCount >= maxConsecutiveErrors {
            logger.error("ERROR: Too many consecutive errors (\(consecutiveErrorCount))")
            throw VideoUploadError.processingFailed("Failed to get job status after multiple attempts")
          }
          
          // Continue to next attempt after a delay
          try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
          continue
        }
        
        // Reset consecutive error count on success
        consecutiveErrorCount = 0
        
        // Decode the response
        let decoder = JSONDecoder()
        let status = try decoder.decode(JobStatusResponse.self, from: responseData)
        
        // Log the complete job status for debugging
          logger.debug("DEBUG: Job status: state=\(status.jobStatus.state), progress=\(status.jobStatus.progress ?? -1), error=\(status.jobStatus.error ?? "nil")")
        
        // Handle different job states
        switch status.jobStatus.state {
        case "queued":
          logger.debug("DEBUG: Job is queued for processing")
          
        case "processing":
          if let progress = status.jobStatus.progress {
            await MainActor.run {
              self.processingProgress = Double(progress) / 100.0
              self.uploadStatus = .processing(progress: Double(progress) / 100.0)
              logger.debug("DEBUG: Processing progress: \(progress)%")
            }
          } else {
            logger.debug("DEBUG: Processing (no progress percentage reported)")
          }
          
        case "JOB_STATE_COMPLETED":
          logger.debug("DEBUG: Job completed successfully")
          if let processedBlob = status.jobStatus.blob {
            logger.debug("DEBUG: Blob received: type=\(processedBlob.mimeType), size=\(processedBlob.size) bytes")
            await MainActor.run {
              self.uploadStatus = .complete
              self.uploadedBlob = processedBlob
              self.isVideoUploading = false
            }
            return processedBlob
          } else {
            logger.error("ERROR: Job succeeded but no blob was returned")
            throw VideoUploadError.processingFailed("Server reported success but provided no video data")
          }
        case "JOB_STATE_FAILED":
          let errorMessage = status.jobStatus.error ?? "Unknown error"
          logger.error("ERROR: Video processing failed with message: \(errorMessage)")
          await MainActor.run {
            self.uploadStatus = .failed(error: errorMessage)
            self.videoError = errorMessage
          }
          throw VideoUploadError.processingFailed(errorMessage)
          
        default:
          logger.debug("DEBUG: Unknown job state: \(status.jobStatus.state)")
        }
      } catch let error as VideoUploadError {
        // Propagate VideoUploadError
        throw error
      } catch {
        logger.error("ERROR: Failed to poll job status: \(error)")
        consecutiveErrorCount += 1
        
        if consecutiveErrorCount >= maxConsecutiveErrors {
          logger.error("ERROR: Too many consecutive errors (\(consecutiveErrorCount))")
          throw VideoUploadError.processingFailed("Failed to poll job status: \(error.localizedDescription)")
        }
      }

      // Wait before next polling attempt
      try await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
    }

    let videoAttempts = attempts
    // If we reach here, we've timed out
    await MainActor.run {
      self.isVideoUploading = false
      self.uploadStatus = .failed(error: "Video processing timed out after \(videoAttempts) attempts")
    }
    logger.error("ERROR: Video processing timed out after \(attempts) attempts")
    throw VideoUploadError.processingTimeout
  }
  
  /// Structure for decoding job status response
  private struct JobStatusResponse: Decodable {
    let jobStatus: AppBskyVideoDefs.JobStatus
  }

  /// Cancel an ongoing upload
  func cancelUpload() {
    logger.info("Cancelling video upload")
    
    // Cancel any ongoing upload tasks
    if let currentUploadTask = currentUploadTask {
      currentUploadTask.cancel()
      self.currentUploadTask = nil
      logger.debug("Cancelled ongoing upload task")
    }
    
    // Cancel any ongoing processing tasks
    if let currentProcessingTask = currentProcessingTask {
      currentProcessingTask.cancel()
      self.currentProcessingTask = nil
      logger.debug("Cancelled ongoing processing task")
    }
    
    // If we have a job ID, attempt to cancel the server-side job
    if let jobId = videoJobId {
      Task {
        await cancelServerSideJob(jobId: jobId)
      }
    }
    
    // Reset all upload state
    uploadStatus = .cancelled
    videoUploadProgress = 0.0
    processingProgress = 0.0
    videoJobId = nil
    uploadedBlob = nil
    isVideoUploading = false
    
    logger.info("Video upload cancelled and state reset")
  }
  
  /// Cancels a server-side video processing job
  private func cancelServerSideJob(jobId: String) async {
    logger.info("Attempting to cancel server-side job: \(jobId)")
    
    // There's no explicit cancel endpoint in the current AT Protocol spec,
    // but we can mark it as cancelled in our tracking
    logger.debug("Server-side job cancellation requested for: \(jobId)")
    
    // In a full implementation, you might want to:
    // 1. Store cancelled job IDs to avoid polling them
    // 2. Implement a retry mechanism for network failures
    // 3. Clean up any temporary resources on the server
  }

  /// Creates a video embed from the uploaded blob
  func createVideoEmbed(aspectRatio: CGSize?, alt: String) -> AppBskyFeedPost
    .AppBskyFeedPostEmbedUnion? {
    guard let blob = uploadedBlob else {
      return nil
    }

    // Create aspect ratio if available
    let ratio = aspectRatio.map { size in
      AppBskyEmbedDefs.AspectRatio(
        width: Int(size.width),
        height: Int(size.height)
      )
    }

    // Create video embed
    let videoEmbed = AppBskyEmbedVideo(
      video: blob,
      captions: nil,
      alt: alt.isEmpty ? nil : alt,
      aspectRatio: ratio
    )

    return .appBskyEmbedVideo(videoEmbed)
  }

  // MARK: - Media Helpers

  func checkImageFormat(_ data: Data) -> String {
    let bytes = [UInt8](data.prefix(4))
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
      return "JPEG"
    } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
      return "PNG"
    } else if bytes.starts(with: [0x00, 0x00, 0x01]) {
      return "HEIC"
    } else {
      return "Unknown"
    }
  }

  func convertHEICToJPEG(_ heicData: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(heicData as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return nil
    }

    #if os(iOS)
    let image = UIImage(cgImage: cgImage)
    return image.jpegData(compressionQuality: 0.9)
    #elseif os(macOS)
    let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    guard let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData) else {
      return nil
    }
    return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    #endif
  }

  func compressImage(_ image: PlatformImage, maxSizeInBytes: Int = 900_000) -> Data? {
    var compression: CGFloat = 1.0
    #if os(iOS)
    var imageData = image.jpegData(compressionQuality: compression)
    #elseif os(macOS)
    var imageData: Data?
    if let tiffData = image.tiffRepresentation,
       let bitmapRep = NSBitmapImageRep(data: tiffData) {
      imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
    #endif

    // Gradually lower quality until we get under target size
    while let data = imageData, data.count > maxSizeInBytes && compression > 0.1 {
      compression -= 0.1
      #if os(iOS)
      imageData = image.jpegData(compressionQuality: compression)
      #elseif os(macOS)
      if let tiffData = image.tiffRepresentation,
         let bitmapRep = NSBitmapImageRep(data: tiffData) {
        imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compression])
      }
      #endif
    }

    // If we still exceed the size limit, resize the image
    if let bestData = imageData, bestData.count > maxSizeInBytes {
      let scale = sqrt(CGFloat(maxSizeInBytes) / CGFloat(bestData.count))
      let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

      #if os(iOS)
      UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
      image.draw(in: CGRect(origin: .zero, size: newSize))
      let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
      UIGraphicsEndImageContext()
      return resizedImage?.jpegData(compressionQuality: 0.7)
      #elseif os(macOS)
      let resizedImage = NSImage(size: newSize, flipped: false) { rect in
        image.draw(in: rect)
        return true
      }
      if let tiffData = resizedImage.tiffRepresentation,
         let bitmapRep = NSBitmapImageRep(data: tiffData) {
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
      }
      return nil
      #endif
    }

    return imageData
  }

  /// Extract aspect ratio from video file
  func getVideoAspectRatio(url: URL) async -> AppBskyEmbedDefs.AspectRatio? {
    let asset = AVURLAsset(url: url)
    let tracks = try? await asset.loadTracks(withMediaType: .video)

    guard let track = tracks?.first else { return nil }

    do {
      let naturalSize = try await track.load(.naturalSize)
      return AppBskyEmbedDefs.AspectRatio(
        width: Int(naturalSize.width),
        height: Int(naturalSize.height)
      )
    } catch {
      logger.debug("Error getting video dimensions: \(error)")
      return nil
    }
  }
}

/// Custom URLSession delegate to track upload progress
class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
  var onProgress: (Double) -> Void

  init(onProgress: @escaping (Double) -> Void) {
    self.onProgress = onProgress
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
    onProgress(progress)
  }
}

/// Video upload errors
enum VideoUploadError: LocalizedError {
  case noClientAvailable
  case authenticationFailed
  case uploadFailed
  case processingFailed(String)
  case processingTimeout

  var errorDescription: String? {
    switch self {
    case .noClientAvailable:
      return "No ATProto client available"
    case .authenticationFailed:
      return "Failed to authenticate with video service"
    case .uploadFailed:
      return "Failed to upload video"
    case .processingFailed(let reason):
      return "Video processing failed: \(reason)"
    case .processingTimeout:
      return "Video processing timed out"
    }
  }
}
