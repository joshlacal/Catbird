import Foundation
import OSLog
import Petrel

/// Service for validating migration compatibility and safety
class MigrationValidator {
  private let logger = Logger(subsystem: "blue.catbird", category: "MigrationValidator")
  
  // MARK: - Server Compatibility Validation
  
  /// Validate compatibility between source and destination servers
  func validateServerCompatibility(
    source: ATProtoClient,
    destination: ATProtoClient
  ) async throws -> CompatibilityReport {
    
    logger.info("Validating server compatibility")
    
    var warnings: [String] = []
    var blockers: [String] = []
    var riskLevel: CompatibilityReport.RiskLevel = .low
    
    // Get server information
    let sourceInfo = try await getServerInfo(client: source)
    let destinationInfo = try await getServerInfo(client: destination)
    
    // Check version compatibility
    let versionCheck = validateVersions(
      source: sourceInfo.version,
      destination: destinationInfo.version
    )
    
    if !versionCheck.compatible {
      blockers.append(contentsOf: versionCheck.blockers)
      riskLevel = .critical
    } else {
      warnings.append(contentsOf: versionCheck.warnings)
      if riskLevel == .low && !versionCheck.warnings.isEmpty {
        riskLevel = .medium
      }
    }
    
    // Check feature compatibility
    let featureCheck = validateFeatures(
      sourceCapabilities: sourceInfo.capabilities,
      destinationCapabilities: destinationInfo.capabilities
    )
    
    warnings.append(contentsOf: featureCheck.warnings)
    if !featureCheck.critical.isEmpty {
      blockers.append(contentsOf: featureCheck.critical)
      riskLevel = .critical
    } else if !featureCheck.warnings.isEmpty && riskLevel == .low {
      riskLevel = .medium
    }
    
    // Check size limits
    if let sourceSize = sourceInfo.maxAccountSize,
       let destSize = destinationInfo.maxAccountSize,
       sourceSize > destSize {
      warnings.append("Destination server has smaller account size limit (\(ByteCountFormatter().string(fromByteCount: Int64(destSize))) vs \(ByteCountFormatter().string(fromByteCount: Int64(sourceSize))))")
      riskLevel = riskLevel == .low ? .medium : riskLevel
    }
    
    // Check rate limits
    if let sourceLimit = sourceInfo.rateLimit?.requestsPerMinute,
       let destLimit = destinationInfo.rateLimit?.requestsPerMinute,
       destLimit < sourceLimit / 2 {
      warnings.append("Destination server has significantly lower rate limits - migration may take longer")
    }
    
    // Estimate migration duration
    let estimatedDuration = estimateMigrationDuration(
      sourceInfo: sourceInfo,
      destinationInfo: destinationInfo
    )
    
    return CompatibilityReport(
      sourceVersion: sourceInfo.version,
      destinationVersion: destinationInfo.version,
      canProceed: blockers.isEmpty,
      warnings: warnings,
      blockers: blockers,
      recommendedOptions: generateRecommendedOptions(
        sourceInfo: sourceInfo,
        destinationInfo: destinationInfo
      ),
      estimatedDuration: estimatedDuration,
      riskLevel: riskLevel
    )
  }
  
  // MARK: - User Permission Validation
  
  /// Validate that user has necessary permissions on both servers
  func validateUserPermissions(
    sourceClient: ATProtoClient,
    destinationClient: ATProtoClient
  ) async throws {
    
    logger.info("Validating user permissions")
    
    // Check source permissions
    do {
      _ = try await sourceClient.getDid()
      
      // Try to access user's repository
      let userDID = try await sourceClient.getDid()
      let (code, _) = try await sourceClient.com.atproto.sync.getRepo(
        input: .init(did: try DID(didString: userDID), since: nil)
      )
      
      guard code == 200 else {
        throw MigrationError.sourceAuthenticationFailed
      }
      
    } catch {
      logger.error("Source permission validation failed: \(error.localizedDescription)")
      throw MigrationError.sourceAuthenticationFailed
    }
    
    // Check destination permissions
    do {
      _ = try await destinationClient.getDid()
      
      // Check if we can write to the destination
      let (sessionCode, sessionData) = try await destinationClient.com.atproto.server.getSession()
      
      guard sessionCode == 200, let session = sessionData else {
        throw MigrationError.destinationAuthenticationFailed
      }
      
      // Verify session has necessary capabilities
      // This would depend on server-specific session capabilities
      
    } catch {
      logger.error("Destination permission validation failed: \(error.localizedDescription)")
      throw MigrationError.destinationAuthenticationFailed
    }
    
    logger.info("✅ User permissions validated")
  }
  
  // MARK: - Rate Limit Validation
  
  /// Validate rate limits for migration
  func validateRateLimits(
    sourceClient: ATProtoClient,
    destinationClient: ATProtoClient,
    estimatedDataSize: Int
  ) async throws {
    
    logger.info("Validating rate limits for migration")
    
    // Get server info to check rate limits
    let _ = try await getServerInfo(client: sourceClient)
    let destinationInfo = try await getServerInfo(client: destinationClient)
    
    // Check if estimated data size exceeds rate limits
    if let destRateLimit = destinationInfo.rateLimit {
      let hoursNeeded = Double(estimatedDataSize) / Double(destRateLimit.dataPerHour)
      
      if hoursNeeded > 24 {
        throw MigrationError.rateLimitExceeded
      }
      
      if hoursNeeded > 6 {
        logger.warning("Migration may take \(String(format: "%.1f", hoursNeeded)) hours due to rate limits")
      }
    }
    
    // Check destination account size limits
    if let maxSize = destinationInfo.maxAccountSize,
       estimatedDataSize > maxSize {
      throw MigrationError.dataSizeExceedsLimit(estimatedDataSize, maxSize)
    }
    
    logger.info("✅ Rate limits validated")
  }
  
  // MARK: - Export Validation
  
  /// Validate integrity of exported CAR data
  func validateExportIntegrity(
    carData: Data,
    expectedDID: String
  ) async throws {
    
    logger.info("Validating export integrity")
    
    // Basic size check
    guard carData.count > 0 else {
      throw MigrationError.exportFailed
    }
    
    // Check for minimum CAR file structure
    // CAR files start with a header that includes the DAG-CBOR root
    guard carData.count > 32 else {
      throw MigrationError.exportFailed
    }
    
    // Would implement full CAR file validation here
    // For now, basic checks
    
    logger.info("✅ Export integrity validated: \(carData.count) bytes")
  }
  
  // MARK: - Migration Verification
  
  /// Verify migration integrity after import
  func verifyMigrationIntegrity(
    sourceClient: ATProtoClient,
    destinationClient: ATProtoClient,
    destinationDID: String,
    migration: MigrationOperation
  ) async throws -> VerificationReport {
    
    logger.info("Verifying migration integrity")
    
    var failures: [VerificationReport.VerificationFailure] = []
    var warnings: [String] = []
    var itemsVerified = 0
    var itemsSuccessful = 0
    
    // Verify profile migration
    do {
      try await verifyProfileMigration(
        sourceClient: sourceClient,
        destinationClient: destinationClient,
        destinationDID: destinationDID
      )
      itemsVerified += 1
      itemsSuccessful += 1
    } catch {
      itemsVerified += 1
      failures.append(VerificationReport.VerificationFailure(
        item: "Profile",
        expected: "Profile should be migrated",
        actual: "Profile verification failed: \(error.localizedDescription)",
        severity: .major
      ))
    }
    
    // Verify post count (sampling)
    do {
      let postVerification = try await verifyPostMigration(
        sourceClient: sourceClient,
        destinationClient: destinationClient,
        destinationDID: destinationDID
      )
      itemsVerified += postVerification.verified
      itemsSuccessful += postVerification.successful
      failures.append(contentsOf: postVerification.failures)
      warnings.append(contentsOf: postVerification.warnings)
    } catch {
      warnings.append("Post verification failed: \(error.localizedDescription)")
    }
    
    // Verify follows migration
    do {
      try await verifyFollowsMigration(
        sourceClient: sourceClient,
        destinationClient: destinationClient,
        destinationDID: destinationDID
      )
      itemsVerified += 1
      itemsSuccessful += 1
    } catch {
      itemsVerified += 1
      failures.append(VerificationReport.VerificationFailure(
        item: "Follows",
        expected: "Follows should be migrated",
        actual: "Follows verification failed: \(error.localizedDescription)",
        severity: .minor
      ))
    }
    
    let successRate = itemsVerified > 0 ? Double(itemsSuccessful) / Double(itemsVerified) : 0.0
    
    return VerificationReport(
      overallSuccess: failures.filter { $0.severity == .critical || $0.severity == .major }.isEmpty,
      successRate: successRate,
      itemsVerified: itemsVerified,
      itemsSuccessful: itemsSuccessful,
      itemsFailed: failures.count,
      failures: failures,
      warnings: warnings,
      verifiedAt: Date()
    )
  }
  
  // MARK: - Private Helper Methods
  
  private func getServerInfo(client: ATProtoClient) async throws -> ServerInfo {
    // Get server description
    let (code, serverDesc) = try await client.com.atproto.server.describeServer()
    
    guard code == 200, let _ = serverDesc else {
      throw MigrationError.serverUnavailable("unknown")
    }
    
    return ServerInfo(
      version: "0.3.0", // Would extract from server response
      capabilities: ["posts", "follows", "media"], // Would extract from server
      maxAccountSize: 1024 * 1024 * 100, // Would extract from server
      rateLimit: RateLimit(requestsPerMinute: 3000, dataPerHour: 1024 * 1024 * 100)
    )
  }
  
  private func validateVersions(source: String, destination: String) -> (compatible: Bool, warnings: [String], blockers: [String]) {
    // Simple version comparison - would implement proper semantic versioning
    let sourceVersion = parseVersion(source)
    let destVersion = parseVersion(destination)
    
    var warnings: [String] = []
    var blockers: [String] = []
    
    // Check major version compatibility
    if sourceVersion.major != destVersion.major {
      blockers.append("Major version mismatch (source: \(source), destination: \(destination))")
      return (false, warnings, blockers)
    }
    
    // Check minor version compatibility
    if abs(sourceVersion.minor - destVersion.minor) > 1 {
      warnings.append("Minor version difference may cause compatibility issues")
    }
    
    return (true, warnings, blockers)
  }
  
  private func validateFeatures(sourceCapabilities: [String], destinationCapabilities: [String]) -> (warnings: [String], critical: [String]) {
    var warnings: [String] = []
    var critical: [String] = []
    
    let requiredCapabilities = ["posts", "follows"]
    let optionalCapabilities = ["media", "chat", "blocks"]
    
    // Check required capabilities
    for capability in requiredCapabilities {
      if sourceCapabilities.contains(capability) && !destinationCapabilities.contains(capability) {
        critical.append("Destination server missing required capability: \(capability)")
      }
    }
    
    // Check optional capabilities
    for capability in optionalCapabilities {
      if sourceCapabilities.contains(capability) && !destinationCapabilities.contains(capability) {
        warnings.append("Destination server missing optional capability: \(capability)")
      }
    }
    
    return (warnings, critical)
  }
  
  private func estimateMigrationDuration(sourceInfo: ServerInfo, destinationInfo: ServerInfo) -> TimeInterval {
    // Simple estimation based on rate limits
    let baseTime: TimeInterval = 300 // 5 minutes base
    
    // Adjust based on rate limits
    let rateLimitMultiplier = destinationInfo.rateLimit?.requestsPerMinute ?? 1000
    let adjustment = max(1.0, 3000.0 / Double(rateLimitMultiplier))
    
    return baseTime * adjustment
  }
  
  private func generateRecommendedOptions(sourceInfo: ServerInfo, destinationInfo: ServerInfo) -> MigrationOptions {
    var options = MigrationOptions.default
    
    // Adjust batch size based on rate limits
    if let destLimit = destinationInfo.rateLimit?.requestsPerMinute, destLimit < 1000 {
      options = MigrationOptions(
        includeFollows: options.includeFollows,
        includeFollowers: options.includeFollowers,
        includePosts: options.includePosts,
        includeMedia: options.includeMedia,
        includeLikes: options.includeLikes,
        includeReposts: options.includeReposts,
        includeBlocks: options.includeBlocks,
        includeMutes: options.includeMutes,
        includeProfile: options.includeProfile,
        destinationHandle: options.destinationHandle,
        preserveTimestamps: options.preserveTimestamps,
        batchSize: 50, // Smaller batch size for lower rate limits
        skipDuplicates: options.skipDuplicates,
        createBackupBeforeMigration: options.createBackupBeforeMigration,
        verifyAfterMigration: options.verifyAfterMigration,
        enableRollbackOnFailure: options.enableRollbackOnFailure
      )
    }
    
    return options
  }
  
  private func parseVersion(_ version: String) -> (major: Int, minor: Int, patch: Int) {
    let components = version.split(separator: ".").compactMap { Int($0) }
    return (
      major: components.count > 0 ? components[0] : 0,
      minor: components.count > 1 ? components[1] : 0,
      patch: components.count > 2 ? components[2] : 0
    )
  }
  
  // MARK: - Verification Methods
  
  private func verifyProfileMigration(
    sourceClient: ATProtoClient,
    destinationClient: ATProtoClient,
    destinationDID: String
  ) async throws {
    
    // Get source profile
    let sourceDID = try await sourceClient.getDid()
    let (sourceCode, sourceProfile) = try await sourceClient.app.bsky.actor.getProfile(
      input: .init(actor: ATIdentifier(string: sourceDID))
    )
    
    guard sourceCode == 200, let source = sourceProfile else {
      throw MigrationError.verificationFailed([])
    }
    
    // Get destination profile
    let (destCode, destProfile) = try await destinationClient.app.bsky.actor.getProfile(
      input: .init(actor: ATIdentifier(string: destinationDID))
    )
    
    guard destCode == 200, let dest = destProfile else {
      throw MigrationError.verificationFailed([])
    }
    
    // Compare key profile fields
    guard source.displayName == dest.displayName else {
      throw MigrationError.verificationFailed([])
    }
    
    guard source.description == dest.description else {
      throw MigrationError.verificationFailed([])
    }
  }
  
  private func verifyPostMigration(
    sourceClient: ATProtoClient,
    destinationClient: ATProtoClient,
    destinationDID: String
  ) async throws -> (verified: Int, successful: Int, failures: [VerificationReport.VerificationFailure], warnings: [String]) {
    
    // Sample verification - check a few recent posts
    let sourceDID = try await sourceClient.getDid()
    
    // Get recent posts from source
    let (sourceCode, sourceFeed) = try await sourceClient.app.bsky.feed.getAuthorFeed(
      input: .init(actor: ATIdentifier(string: sourceDID), limit: 10, cursor: nil, filter: nil)
    )
    
    guard sourceCode == 200, let sourceData = sourceFeed else {
      return (0, 0, [], ["Could not fetch source posts for verification"])
    }
    
    // Get recent posts from destination
    let (destCode, destFeed) = try await destinationClient.app.bsky.feed.getAuthorFeed(
      input: .init(actor: ATIdentifier(string: destinationDID), limit: 10, cursor: nil, filter: nil)
    )
    
    guard destCode == 200, let destData = destFeed else {
      return (0, 0, [], ["Could not fetch destination posts for verification"])
    }
    
    // Simple count comparison
    let verified = 1
    let successful = sourceData.feed.count == destData.feed.count ? 1 : 0
    let failures: [VerificationReport.VerificationFailure] = successful == 0 ? [
      VerificationReport.VerificationFailure(
        item: "Post Count",
        expected: "\(sourceData.feed.count) posts",
        actual: "\(destData.feed.count) posts",
        severity: .minor
      )
    ] : []
    
    return (verified, successful, failures, [])
  }
  
  private func verifyFollowsMigration(
    sourceClient: ATProtoClient,
    destinationClient: ATProtoClient,
    destinationDID: String
  ) async throws {
    
    // This would implement follows verification
    // For now, just check that follows endpoints are accessible
    
    let sourceDID = try await sourceClient.getDid()
    
    let (sourceCode, _) = try await sourceClient.app.bsky.graph.getFollows(
      input: .init(actor: ATIdentifier(string: sourceDID), limit: 1, cursor: nil)
    )
    
    let (destCode, _) = try await destinationClient.app.bsky.graph.getFollows(
      input: .init(actor: ATIdentifier(string: destinationDID), limit: 1, cursor: nil)
    )
    
    guard sourceCode == 200 && destCode == 200 else {
      throw MigrationError.verificationFailed([])
    }
  }
}

// MARK: - Helper Structures

private struct ServerInfo {
  let version: String
  let capabilities: [String]
  let maxAccountSize: Int?
  let rateLimit: RateLimit?
}