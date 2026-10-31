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
@MainActor
@Observable
final class MediaUploadManager {
  // MARK: - Properties

  private let client: ATProtoClient
  private let videoBaseURL = "https://video.bsky.app/xrpc"
  private let logger = Logger(subsystem: "blue.catbird", category: "MediaUploadManager")

  // Cache for service-auth tokens per LXM
  private struct ServiceAuthCacheEntry {
    let token: String
    let expiresAt: Date
  }
  private var serviceAuthCache: [String: ServiceAuthCacheEntry] = [:]

  // Throttle preflight checks
  private var lastPreflight:
    (timestamp: Date, result: (allowed: Bool, message: String?, code: String?))?
  private var isCheckingLimits = false

  // Video upload state
  var isVideoUploading = false
  var videoUploadProgress: Double = 0
  var processingProgress: Double = 0
  var videoJobId: String?
  var videoError: String?
  var uploadStatus: VideoUploadStatus = .notStarted
  var uploadedBlob: Blob?

  // Task tracking for cancellation
  @MainActor private var currentUploadTask: Task<Blob, Error>?
  @MainActor private var activeUploadID: UUID?

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

  /// Upload an image blob to the server
  func uploadImageBlob(_ imageData: Data) async throws -> Blob {
    let mimeType = ImageMetadataStripper.detectMIMEType(from: imageData)

    let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
      data: imageData,
      mimeType: mimeType,
      stripMetadata: true
    )

    guard responseCode == 200, let blob = blobOutput?.blob else {
      throw VideoUploadError.uploadFailed
    }

    return blob
  }
  // MARK: - Caption Upload Methods

  /// Upload a video caption (.vtt) blob to the repository with metadata stripping disabled
  func uploadCaptionBlob(_ caption: VideoCaption) async throws -> AppBskyEmbedVideo.Caption {
    guard let data = caption.content.data(using: .utf8) else {
      logger.error("MediaUploadManager: Failed to encode caption text as UTF-8")
      throw VideoUploadError.uploadFailed
    }

    logger.info("MediaUploadManager: Uploading caption blob for language \(caption.lang.lang.minimalIdentifier) (\(data.count) bytes)")

    let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
      data: data,
      mimeType: "text/vtt",
      stripMetadata: false
    )

    guard responseCode == 200, let blob = blobOutput?.blob else {
      logger.error("MediaUploadManager: Caption upload failed with response code \(responseCode)")
      throw VideoUploadError.uploadFailed
    }

    logger.info("MediaUploadManager: Caption blob uploaded successfully, blob mimeType: \(blob.mimeType)")
    return AppBskyEmbedVideo.Caption(
      lang: caption.lang,
      file: blob
    )
  }


  // MARK: - Video Upload Methods
  /// Get authentication token for video operations
  private func getVideoAuthTokenForUploadLimits() async throws -> String {
    logger.debug("DEBUG: Requesting service auth token")
    let didValue = try await client.getDid()
    logger.debug("DEBUG: Using DID: \(didValue)")

    let serviceParams = ComAtprotoServerGetServiceAuth.Parameters(
      aud: "did:web:video.bsky.app",
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

  /// Get authentication token for a specific video service method
  private func getVideoServiceAuthToken(lxm: String) async throws -> String {
    // Return cached token if still valid with a small safety margin (30s)
    if let cached = serviceAuthCache[lxm], cached.expiresAt.timeIntervalSinceNow > 30 {
      return cached.token
    }

    logger.debug("DEBUG: Requesting service auth token for lxm=\(lxm)")
    _ = try await client.getDid()  // ensure session
    // Request a short-lived token to reduce risk; cache will avoid re-minting unnecessarily
    let now = Int(Date().timeIntervalSince1970)
    let expUnix = now + 5 * 60  // 5 minutes
    let serviceParams = ComAtprotoServerGetServiceAuth.Parameters(
      aud: "did:web:video.bsky.app",
      exp: expUnix,
      lxm: try NSID(nsidString: lxm)
    )
    let (authCode, authData) = try await client.com.atproto.server.getServiceAuth(
      input: serviceParams)
    logger.debug("DEBUG: Service auth response code: \(authCode)")
    guard authCode == 200, let serviceAuth = authData else {
      logger.error("ERROR: Service auth request failed for lxm=\(lxm) code=\(authCode)")
      throw VideoUploadError.authenticationFailed
    }
    let expiry = Date(timeIntervalSince1970: TimeInterval(expUnix))
    serviceAuthCache[lxm] = ServiceAuthCacheEntry(token: serviceAuth.token, expiresAt: expiry)
    return serviceAuth.token
  }

  /// Mint a service-auth token for repo upload operations against the user's PDS (aud = PDS DID).
  /// The video service expects an upload token scoped to `com.atproto.repo.uploadBlob` with audience set
  /// to the PDS DID (did:web:<pds-host>), not the video service DID.
  private func getPdsRepoUploadAuthToken() async throws -> String {
    // Cache key by LXM since audience is deterministic per client
    let lxm = "com.atproto.repo.uploadBlob"
    if let cached = serviceAuthCache[lxm], cached.expiresAt.timeIntervalSinceNow > 30 {
      return cached.token
    }

    logger.debug("DEBUG: Requesting PDS repo-upload service auth token (lxm=\(lxm))")
    let userDid = try await client.getDid()  // ensure session and get DID

    // Resolve real PDS URL to ensure we get the correct audience (bypassing any proxy/gateway configuration)
    // The video service requires the aud to be the user's actual PDS DID (e.g. did:web:inkcap...)
    let pdsURL = try await client.resolveDIDToPDSURL(did: userDid)
    guard let host = pdsURL.host else {
      logger.error("ERROR: Could not resolve PDS host for DID \(userDid) from URL \(pdsURL)")
      throw VideoUploadError.authenticationFailed
    }

    let aud = "did:web:\(host)"
    let now = Int(Date().timeIntervalSince1970)
    let expUnix = now + 5 * 60  // 5 minutes
    let serviceParams = ComAtprotoServerGetServiceAuth.Parameters(
      aud: aud,
      exp: expUnix,
      lxm: try NSID(nsidString: lxm)
    )
    let (authCode, authData) = try await client.com.atproto.server.getServiceAuth(
      input: serviceParams)
    logger.debug("DEBUG: PDS service auth response code: \(authCode)")
    guard authCode == 200, let serviceAuth = authData else {
      logger.error("ERROR: PDS service auth request failed for lxm=\(lxm) code=\(authCode)")
      throw VideoUploadError.authenticationFailed
    }
    let expiry = Date(timeIntervalSince1970: TimeInterval(expUnix))
    serviceAuthCache[lxm] = ServiceAuthCacheEntry(token: serviceAuth.token, expiresAt: expiry)
    return serviceAuth.token
  }

  /// Check upload limits from video server directly
  /// Always attempts to decode the response body to surface server-provided reasons,
  /// even on non-200 (e.g., 401 with { canUpload:false, error:"unconfirmed_email", message:"..." }).
  private func checkVideoUploadLimits(token: String) async throws -> (
    canUpload: Bool, message: String?, code: String?
  ) {
    logger.debug("DEBUG: Checking upload limits from server")

    let limitsURL = URL(string: "\(videoBaseURL)/app.bsky.video.getUploadLimits")!

    var request = URLRequest(url: limitsURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    logger.debug("Request: \(request.debugDescription)")

    request.timeoutInterval = 30
    let (data, response) = try await URLSessionVideoHTTPClient().perform(
      request, fileURL: nil, onProgress: nil
    )
    logger.debug("Received data: \(data), response: \(response)")
    guard let httpResponse = response as? HTTPURLResponse else {
      logger.error("ERROR: Invalid HTTP response type")
      throw VideoUploadError.processingFailed("Invalid response from server")
    }

    logger.debug("DEBUG: Upload limits response code: \(httpResponse.statusCode)")

    // Try to decode body regardless of status to extract message/error
    let decoder = JSONDecoder()
    if httpResponse.statusCode == 200 {
      do {
        let limits = try decoder.decode(UploadLimitsResponse.self, from: data)
        // Prefer message when available; fall back to error code
        let reason = limits.message ?? limits.error
        return (limits.canUpload, reason, limits.error)
      } catch {
        logger.error("ERROR: Failed to decode upload limits response: \(error)")
        throw VideoUploadError.processingFailed("Could not parse upload limits response")
      }
    } else {
      let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
      logger.error(
        "ERROR: Failed to get upload limits, HTTP \(httpResponse.statusCode) body=\(bodyText)")
      // Attempt to decode structured reason from non-200 body
      if let limits = try? decoder.decode(UploadLimitsResponse.self, from: data) {
        var combined: String?
        if let message = limits.message, let code = limits.error, !message.isEmpty {
          if message.contains(code) {
            combined = message
          } else {
            combined = "\(message) (\(code))"
          }
        } else {
          combined = limits.message ?? limits.error
        }
        return (false, combined, limits.error)
      }
      // Could not decode; return generic
      return (
        false, "Server error when checking upload limits (HTTP \(httpResponse.statusCode))", nil
      )
    }
  }

  // MARK: - Public preflight check
  /// Quickly check if the server currently allows video uploads for this account.
  func preflightUploadPermission(force: Bool = false) async -> (
    allowed: Bool, message: String?, code: String?
  ) {
    // If a recent result exists (<= 5 min) and not forced, return it to avoid spamming
    if !force, let last = lastPreflight, Date().timeIntervalSince(last.timestamp) <= 300 {
      return last.result
    }
    // If a check is already in flight, return the last known result (if any)
    if isCheckingLimits {
      return lastPreflight?.result ?? (false, "Checking upload eligibility…", nil)
    }
    isCheckingLimits = true
    defer { isCheckingLimits = false }
    do {
      let token = try await getVideoServiceAuthToken(lxm: "app.bsky.video.getUploadLimits")
      let result = try await checkVideoUploadLimits(token: token)
      let packaged = (result.canUpload, result.message, result.code)
      lastPreflight = (Date(), packaged)
      return packaged
    } catch {
      let packaged: (allowed: Bool, message: String?, code: String?) = (
        false, error.localizedDescription, nil
      )
      lastPreflight = (Date(), packaged)
      return packaged
    }
  }

  // MARK: - Email Confirmation
  /// Request the server to (re)send a verification email for the current account.
  func requestEmailConfirmation() async throws {
    _ = try await client.com.atproto.server.requestEmailConfirmation()
  }

  /// Structure for decoding upload limits response
  private struct UploadLimitsResponse: Decodable {
    let canUpload: Bool
    let remainingDailyVideos: Int?
    let remainingDailyBytes: Int?
    let message: String?
    let error: String?
  }

  private func generateUniqueVideoName() -> String {
    let randomString = UUID().uuidString.prefix(12)
    return "\(randomString).mp4"
  }

  /// Start video upload process with additional validation
  @MainActor
  func uploadVideo(
    url: URL, alt: String? = nil, owner: VideoUploadOwner,
    isOwnerCurrent: @escaping @MainActor @Sendable () -> Bool,
    isAccountCurrent: @escaping @MainActor @Sendable () -> Bool,
    transportMode: VideoUploadTransportMode = .multipart
  ) async throws -> Blob {
    guard isOwnerCurrent() else { throw CancellationError() }
    currentUploadTask?.cancel()
    let uploadID = UUID()
    activeUploadID = uploadID
    isVideoUploading = true
    videoUploadProgress = 0
    processingProgress = 0
    videoJobId = nil
    videoError = nil
    uploadedBlob = nil
    uploadStatus = .uploading(progress: 0)

    // Own the complete operation so explicit cancellation also reaches URLSession and polling.
    let task = Task { @MainActor in
      switch transportMode {
      case .multipart:
        return try await self.performMultipartVideoUpload(
          url: url, owner: owner, uploadID: uploadID,
          isOwnerCurrent: isOwnerCurrent, isAccountCurrent: isAccountCurrent
        )
      case .legacy:
        // Explicit rollback route only; never replay uncertain multipart work through it.
        guard try await self.client.getDid() == owner.accountDID, isOwnerCurrent() else {
          throw CancellationError()
        }
        return try await self.performLegacyVideoUpload(url: url, uploadID: uploadID)
      }
    }
    currentUploadTask = task
    defer {
      if activeUploadID == uploadID {
        currentUploadTask = nil
        activeUploadID = nil
        isVideoUploading = false
      }
    }

    do {
      let blob = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try Task.checkCancellation()
      guard activeUploadID == uploadID, isOwnerCurrent() else { throw CancellationError() }
      uploadedBlob = blob
      processingProgress = 1
      uploadStatus = .complete
      return blob
    } catch {
      // A cancelled/replaced attempt must never change the next attempt's state.
      guard activeUploadID == uploadID else { throw CancellationError() }
      if task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
        uploadStatus = .cancelled
        throw CancellationError()
      }
      let message = PostComposerErrorCopy.message(for: error, isThread: false)
        ?? "Couldn’t upload your video. Your attachment is still here."
      videoError = message
      uploadStatus = .failed(error: message)
      throw error
    }
  }

  @MainActor
  private func performMultipartVideoUpload(
    url: URL, owner: VideoUploadOwner, uploadID: UUID,
    isOwnerCurrent: @escaping @MainActor @Sendable () -> Bool,
    isAccountCurrent: @escaping @MainActor @Sendable () -> Bool
  ) async throws -> Blob {
    let isCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
      self?.activeUploadID == uploadID && isOwnerCurrent()
    }
    guard isCurrent(), url.isFileURL,
      let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
      size.int64Value > 0, let mimeType = VideoUploadPolicy.mimeType(for: url)
    else { throw VideoUploadError.unsupportedFormat }
    guard size.int64Value <= VideoUploadPolicy.maximumBytes else { throw VideoUploadError.tooLarge }

    let preparation = MediaPreviewLoadAttempt(timeout: .seconds(30))
    defer { preparation.cancel() }
    let asset = AVURLAsset(url: url)
    let playable = try await preparation.value { try await asset.load(.isPlayable) }
    let hasVideo = try await preparation.value {
      let tracks = try await asset.loadTracks(withMediaType: .video)
      return !tracks.isEmpty
    }
    let duration = try await preparation.value { CMTimeGetSeconds(try await asset.load(.duration)) }
    guard isCurrent() else { throw CancellationError() }
    guard playable, hasVideo, duration.isFinite, duration > 0 else { throw VideoUploadError.unsupportedFormat }
    guard duration <= VideoUploadPolicy.maximumDuration else { throw VideoUploadError.tooLong }

    // Both capabilities already exist in the legacy path. Permission errors never request wider grants.
    let tokens = VideoServiceTokenProvider(isOwner: isAccountCurrent) { [self] expiry in
      try await self.mintMultipartServiceToken(accountDID: owner.accountDID, expiry: expiry, forUpload: true)
    }
    let uploader = VideoMultipartUpload(
      transport: VideoMultipartTransport(tokens: tokens), store: try VideoUploadCheckpointStore.shared.get()
    )
    return try await uploader.run(
      sourceURL: url, owner: owner, mimeType: mimeType,
      durationMilliseconds: Int(duration * 1_000), allowNewSessionAfterTerminal: true,
      progress: { [weak self] progress in
        await MainActor.run {
          guard let self, isCurrent() else { return }
          switch progress.phase {
          case .processing, .finalizing, .complete:
            self.processingProgress = progress.fraction
            self.uploadStatus = .processing(progress: progress.fraction)
          case .preparing, .uploading:
            self.videoUploadProgress = progress.fraction
            self.uploadStatus = .uploading(progress: progress.fraction)
          }
        }
      },
      isOwnerCurrent: { await isCurrent() },
      canAuthorizeCleanup: { await isAccountCurrent() },
      authorizeNewSession: { [self] in
        let limitsTokens = VideoServiceTokenProvider(isOwner: isAccountCurrent) { [self] expiry in
          try await self.mintMultipartServiceToken(accountDID: owner.accountDID, expiry: expiry, forUpload: false)
        }
        let token = try await limitsTokens.token()
        guard await isCurrent() else { throw CancellationError() }
        let limits = try await self.checkVideoUploadLimits(token: token)
        guard await isCurrent() else { throw CancellationError() }
        guard limits.canUpload else { throw VideoUploadError.uploadLimitReached(limits.message) }
      }
    )
  }

  @MainActor
  private func mintMultipartServiceToken(accountDID: String, expiry: Int, forUpload: Bool) async throws -> String {
    guard try await client.getDid() == accountDID else { throw CancellationError() }
    let audience: String
    let method: String
    if forUpload {
      let pds = try await client.resolveDIDToPDSURL(did: accountDID)
      guard let host = pds.host else { throw VideoUploadError.authenticationFailed }
      audience = "did:web:\(host)"
      method = "com.atproto.repo.uploadBlob"
    } else {
      audience = "did:web:video.bsky.app"
      method = "app.bsky.video.getUploadLimits"
    }
    try Task.checkCancellation()
    guard try await client.getDid() == accountDID else { throw CancellationError() }
    let (code, output) = try await client.com.atproto.server.getServiceAuth(input: .init(
      aud: audience, exp: expiry, lxm: try NSID(nsidString: method)
    ))
    try Task.checkCancellation()
    guard try await client.getDid() == accountDID else { throw CancellationError() }
    guard code == 200, let output else {
      throw VideoMultipartTransportError(
        statusCode: code, code: "ServiceAuthDenied",
        message: "Your account could not authorize this video upload. Your draft has been kept."
      )
    }
    return output.token
  }

  @MainActor
  private func performLegacyVideoUpload(url: URL, uploadID: UUID) async throws -> Blob {
    try Task.checkCancellation()
    logger.debug("DEBUG: Starting video upload for URL: \(url)")

    // Validate file exists
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      logger.error("ERROR: Video file does not exist at path: \(url.path)")
      throw VideoUploadError.processingFailed("Video file not found at specified location.")
    }

    // Check file size
    guard let fileAttributes = try? fileManager.attributesOfItem(atPath: url.path),
      let fileSize = fileAttributes[.size] as? NSNumber
    else {
      logger.error("ERROR: Could not determine video file size for path: \(url.path)")
      throw VideoUploadError.processingFailed("Could not determine video file size")
    }

    logger.debug("DEBUG: Video file size: \(fileSize.intValue) bytes")
    let maxVideoSize = 100 * 1024 * 1024  // 100MB
    if fileSize.intValue > maxVideoSize {
      logger.error(
        "ERROR: Video exceeds maximum size of 100MB (actual: \(fileSize.intValue / 1024 / 1024)MB)")
      throw VideoUploadError.legacyTooLarge
    }

    // Validate video format
    do {
      let asset = AVURLAsset(url: url)
      logger.debug("DEBUG: Checking if asset is playable")
      let isPlayable = try await asset.load(.isPlayable)
      if !isPlayable {
        logger.error("ERROR: Video asset is not playable")
        throw VideoUploadError.unsupportedFormat
      }

      // Verify it has a video track
      logger.debug("DEBUG: Checking for video tracks")
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      if videoTracks.isEmpty {
        logger.error("ERROR: No video tracks found in asset")
        throw VideoUploadError.unsupportedFormat
      }

      // Get duration
      let duration = try await asset.load(.duration)
      let durationInSeconds = CMTimeGetSeconds(duration)
      logger.debug("DEBUG: Video duration: \(durationInSeconds) seconds")

      // Check duration limits if needed
      if durationInSeconds > 180 {  // 3 minutes max (updated March 2025)
        logger.error(
          "ERROR: Video duration exceeds maximum allowed (\(durationInSeconds) > 180 seconds)")
        throw VideoUploadError.legacyTooLong
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let assetError where !(assetError is VideoUploadError) {
      try Task.checkCancellation()
      logger.error("ERROR: Failed to validate video asset: \(assetError)")
      throw VideoUploadError.processingFailed(
        "Could not validate video: \(assetError.localizedDescription)")
    }

    try Task.checkCancellation()

    // Get authentication token
    let authToken = try await getVideoServiceAuthToken(lxm: "app.bsky.video.getUploadLimits")

    // Check upload limits from server using direct URLSession
    try Task.checkCancellation()
    let (canUpload, limitMessage, _) = try await checkVideoUploadLimits(token: authToken)
    try Task.checkCancellation()

    guard canUpload else {
      logger.error("ERROR: Server does not allow video uploads: \(limitMessage ?? "no message")")
      throw VideoUploadError.uploadLimitReached(limitMessage)
    }

    logger.debug("DEBUG: Video uploads are allowed, proceeding with upload")

    // Get DID for the upload URL
    let didValue = try await client.getDid()
    logger.debug("DEBUG: Using DID: \(didValue)")

    try Task.checkCancellation()
    logger.debug("DEBUG: Beginning video upload process")

    var uploadURL = URL(string: "\(videoBaseURL)/app.bsky.video.uploadVideo")!
    var urlComponents = URLComponents(url: uploadURL, resolvingAgainstBaseURL: true)!
    urlComponents.queryItems = [
      URLQueryItem(name: "did", value: didValue),
      URLQueryItem(name: "name", value: generateUniqueVideoName()),
    ]
    uploadURL = urlComponents.url!
    logger.debug("DEBUG: Upload URL: \(uploadURL)")

    // IMPORTANT: Upload requires a token scoped to repo upload with aud set to the PDS DID
    // (see Bluesky reference app). Using video service DID will be rejected with 401.
    let token = try await getPdsRepoUploadAuthToken()
    try Task.checkCancellation()

    // Set up HTTP request
    logger.debug("DEBUG: Setting up HTTP request for video upload")
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    // Derive MIME type from file extension when possible
    let ext = url.pathExtension.lowercased()
    let mime: String
    switch ext {
    case "mp4": mime = "video/mp4"
    case "mov": mime = "video/quicktime"
    case "webm": mime = "video/webm"
    case "mpeg", "mpg": mime = "video/mpeg"
    case "gif": mime = "image/gif"
    default: mime = "video/mp4"
    }
    request.setValue(mime, forHTTPHeaderField: "Content-Type")
    request.setValue(fileSize.stringValue, forHTTPHeaderField: "Content-Length")

    let progressDelegate = UploadProgressDelegate { [weak self] progress in
      Task { @MainActor in
        guard let self, self.activeUploadID == uploadID, self.isVideoUploading,
          case .uploading = self.uploadStatus
        else { return }
        self.videoUploadProgress = progress
        self.uploadStatus = .uploading(progress: progress)
        self.logger.debug("DEBUG: Upload progress: \(Int(progress * 100))%")
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
      logger.debug(
        "DEBUG: Upload request completed with response status: \((response as? HTTPURLResponse)?.statusCode ?? 0)"
      )
      if let bodyString = String(data: responseData, encoding: .utf8) {
        logger.debug("DEBUG: Server response body: \(bodyString)")
      }
    } catch {
      try Task.checkCancellation()
      if (error as? URLError)?.code == .cancelled { throw CancellationError() }
      logger.error("ERROR: Video upload network request failed: \(error)")
      throw VideoUploadError.uploadFailed
    }

    try Task.checkCancellation()

    // Process response
    guard let httpResponse = response as? HTTPURLResponse else {
      logger.error("ERROR: Invalid HTTP response type")
      throw VideoUploadError.uploadFailed
    }

    // Decode and log response body for debugging
    logger.debug(
      "DEBUG: Server response body: \(String(data: responseData, encoding: .utf8) ?? "<binary data>")"
    )

    if httpResponse.statusCode == 200 {
      let jobStatus: AppBskyVideoDefs.JobStatus
      do {
        jobStatus = try JSONDecoder().decode(
          VideoUploadResponse<AppBskyVideoDefs.JobStatus>.self, from: responseData
        ).jobStatus
      } catch {
        logger.error("ERROR: Failed to decode upload response: \(error)")
        throw VideoUploadError.processingFailed("Could not decode server response")
      }
      if let blob = try consumeVideoJobStatus(jobStatus) { return blob }
      return try await pollVideoJobStatus(jobId: jobStatus.jobId)
    } else if httpResponse.statusCode == 409 {
      // Reused uploads may return a complete status (including a blob), or just a job ID.
      if let jobStatus = try? JSONDecoder().decode(
        VideoUploadResponse<AppBskyVideoDefs.JobStatus>.self, from: responseData
      ).jobStatus {
        if let blob = try consumeVideoJobStatus(jobStatus) { return blob }
        return try await pollVideoJobStatus(jobId: jobStatus.jobId)
      }
      if let errorJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
        let jobId = errorJson["jobId"] as? String, !jobId.isEmpty
      {
        videoJobId = jobId
        uploadStatus = .processing(progress: 0)
        return try await pollVideoJobStatus(jobId: jobId)
      }
    }

    let errorJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    let errorMessage = errorJson?["message"] as? String ?? "HTTP \(httpResponse.statusCode)"
    logger.error("ERROR: Video upload failed: \(errorMessage)")
    throw VideoUploadError.uploadFailed
  }

  /// Return a blob before inspecting state: already-existing videos can carry both a failure and a blob.
  @MainActor
  private func consumeVideoJobStatus(_ status: AppBskyVideoDefs.JobStatus) throws -> Blob? {
    try Task.checkCancellation()
    videoJobId = status.jobId
    switch VideoProcessingOutcome.resolve(
      state: status.state,
      progress: status.progress,
      blob: status.blob,
      error: status.error,
      message: status.message
    ) {
    case .complete(let blob):
      return blob
    case .failed(let message):
      logger.error("ERROR: Video processing failed: \(message)")
      throw VideoUploadError.processingFailed(message)
    case .pending(let progress):
      processingProgress = progress
      uploadStatus = .processing(progress: progress)
      return nil
    }
  }

  /// Poll the public status endpoint with bounded retries. Terminal processing errors are not retried.
  @MainActor
  private func pollVideoJobStatus(jobId: String) async throws -> Blob {
    let maxAttempts = 30
    let maxConsecutiveErrors = 3
    var consecutiveErrorCount = 0

    var components = URLComponents(string: "\(videoBaseURL)/app.bsky.video.getJobStatus")!
    components.queryItems = [URLQueryItem(name: "jobId", value: jobId)]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    request.timeoutInterval = 30

    for _ in 0..<maxAttempts {
      try Task.checkCancellation()
      let status: AppBskyVideoDefs.JobStatus
      do {
        let (responseData, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
          throw URLError(.badServerResponse)
        }
        status = try JSONDecoder().decode(
          VideoUploadResponse<AppBskyVideoDefs.JobStatus>.self, from: responseData
        ).jobStatus
      } catch {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        consecutiveErrorCount += 1
        logger.error("ERROR: Failed to poll job status: \(error)")
        if consecutiveErrorCount >= maxConsecutiveErrors {
          throw VideoUploadError.processingFailed("Failed to get job status after multiple attempts")
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        continue
      }

      consecutiveErrorCount = 0
      if let blob = try consumeVideoJobStatus(status) { return blob }
      try await Task.sleep(nanoseconds: 5_000_000_000)
    }

    throw VideoUploadError.processingTimeout
  }

  /// Cancel this operation. Multipart cleanup can abort an open session; processing jobs cannot be canceled.
  @MainActor
  func cancelUpload() {
    currentUploadTask?.cancel()
    currentUploadTask = nil
    activeUploadID = nil
    uploadStatus = .cancelled
    videoUploadProgress = 0
    processingProgress = 0
    videoJobId = nil
    videoError = nil
    uploadedBlob = nil
    isVideoUploading = false
  }

  /// Creates a video embed from the uploaded blob
  func createVideoEmbed(
    aspectRatio: CGSize?,
    alt: String,
    presentation: String? = nil,
    captions: [AppBskyEmbedVideo.Caption]? = nil
  ) -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
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
      captions: captions,
      alt: alt.isEmpty ? nil : alt,
      aspectRatio: ratio,
      presentation: presentation
    )

    return .appBskyEmbedVideo(videoEmbed)
  }

  // MARK: - Media Helpers

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
    guard totalBytesExpectedToSend > 0 else { return }
    let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
    guard progress.isFinite else { return }
    onProgress(min(1, max(0, progress)))
  }
}

/// Video upload errors
enum VideoUploadError: LocalizedError {
  case noClientAvailable
  case authenticationFailed
  case uploadFailed
  case processingFailed(String)
  case processingTimeout
  case tooLarge
  case tooLong
  case legacyTooLarge
  case legacyTooLong
  case unsupportedFormat
  case uploadLimitReached(String?)

  /// User-facing copy. Technical details stay in the logs.
  var errorDescription: String? {
    switch self {
    case .noClientAvailable, .authenticationFailed:
      return "Couldn’t upload your video. Sign in again and try again."
    case .uploadFailed, .processingFailed:
      return "Couldn’t upload your video. Try again."
    case .processingTimeout:
      return "Your video is taking too long to process. Try again later."
    case .tooLarge:
      return VideoUploadPolicy.sizeMessage
    case .tooLong:
      return VideoUploadPolicy.durationMessage
    case .legacyTooLarge:
      return "The legacy uploader supports videos up to 100 MB."
    case .legacyTooLong:
      return "The legacy uploader supports videos up to 3 minutes."
    case .unsupportedFormat:
      return "This video’s format isn’t supported."
    case .uploadLimitReached(let message):
      if let message, !message.isEmpty {
        return message
      }
      return "You can’t upload more videos right now. Try again later."
    }
  }
}
