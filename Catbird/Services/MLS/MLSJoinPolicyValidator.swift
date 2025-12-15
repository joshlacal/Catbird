//
//  MLSJoinPolicyValidator.swift
//  Catbird
//
//  Client-side MLS credential and policy validation for E2EE guarantees.
//  This actor validates credentials before accepting group state changes,
//  enforcing MLSPolicyModel rules and DID namespace restrictions.
//

import CatbirdMLSCore
import Foundation
import GRDB
import OSLog

// MARK: - Validation Types

/// Operation types for credential validation context
public enum MLSOperationType: String, Sendable {
    case join
    case add
    case update
    case remove
    case decrypt
}

/// Context for credential validation decisions
public struct MLSValidationContext: Sendable {
    public let conversationID: String
    public let operationType: MLSOperationType
    public let currentEpoch: UInt64
    
    public init(conversationID: String, operationType: MLSOperationType, currentEpoch: UInt64) {
        self.conversationID = conversationID
        self.operationType = operationType
        self.currentEpoch = currentEpoch
    }
}

/// Result of credential validation
public enum MLSValidationResult: Sendable {
    case allowed
    case denied(reason: String)
    case requiresApproval(reason: String)
}

/// Credential data extracted from MLS proposals
public struct MLSCredentialInfo: Sendable {
    public let credentialType: String
    public let identity: Data
    
    /// Parse identity as DID string
    public var identityAsDID: String? {
        String(data: identity, encoding: .utf8)
    }
    
    /// Check if the credential is a DID:PLC credential
    public var isDIDPLC: Bool {
        identityAsDID?.hasPrefix("did:plc:") ?? false
    }
    
    /// Check if the credential is a DID:WEB credential
    public var isDIDWeb: Bool {
        identityAsDID?.hasPrefix("did:web:") ?? false
    }
    
    /// Check if the credential uses a known/trusted DID namespace
    public var isTrustedNamespace: Bool {
        isDIDPLC || isDIDWeb
    }
    
    public init(credentialType: String, identity: Data) {
        self.credentialType = credentialType
        self.identity = identity
    }
}

// MARK: - Join Policy Validator

/// Client-side MLS policy validator for credential and membership change validation
///
/// This actor enforces:
/// 1. DID namespace restrictions (only did:plc: and did:web: are trusted)
/// 2. MLSPolicyModel rules (external commits, rejoin windows, invite requirements)
/// 3. Identity continuity for rejoin scenarios
/// 4. Logging of all validation decisions for audit trail
///
/// The validator is called before accepting any group state changes to ensure
/// E2EE guarantees are maintained even if the server is compromised.
public actor MLSJoinPolicyValidator {
    
    // MARK: - Properties
    
    private let database: MLSDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "blue.catbird", category: "MLSJoinPolicyValidator")
    
    /// Allowed DID namespaces - credentials must use one of these prefixes
    private let allowedDIDNamespaces: Set<String> = ["did:plc:", "did:web:"]
    
    /// Cache of recently validated credentials to avoid repeated database lookups
    private var validationCache: [String: (result: MLSValidationResult, timestamp: Date)] = [:]
    private let cacheExpirationSeconds: TimeInterval = 60
    
    // MARK: - Initialization
    
    public init(database: MLSDatabase) {
        self.database = database
        logger.info("🔐 MLSJoinPolicyValidator initialized")
    }
    
    // MARK: - Public Validation API
    
    /// Validate a credential for a specific operation
    /// - Parameters:
    ///   - credential: The credential to validate
    ///   - context: The validation context (conversation, operation type, epoch)
    /// - Returns: Validation result (allowed, denied, or requires approval)
    public func validateCredential(
        _ credential: MLSCredentialInfo,
        context: MLSValidationContext
    ) async -> MLSValidationResult {
        logger.debug("🔍 Validating credential for \(context.operationType.rawValue) in conversation \(context.conversationID.prefix(8))...")
        
        // 1. Check DID namespace allowlist
        let namespaceResult = validateDIDNamespace(credential)
        if case .denied = namespaceResult {
            await logValidationDecision(credential: credential, context: context, result: namespaceResult)
            return namespaceResult
        }
        
        // 2. Fetch policy for this conversation
        let policy = await fetchPolicy(for: context.conversationID)
        
        // 3. Apply policy-specific validation
        let policyResult: MLSValidationResult
        switch context.operationType {
        case .join:
            policyResult = await validateJoin(credential: credential, context: context, policy: policy)
        case .add:
            policyResult = await validateAdd(credential: credential, context: context, policy: policy)
        case .update:
            policyResult = .allowed // Updates from existing members are always allowed
        case .remove:
            policyResult = await validateRemove(credential: credential, context: context, policy: policy)
        case .decrypt:
            policyResult = .allowed // Decryption doesn't require policy check
        }
        
        await logValidationDecision(credential: credential, context: context, result: policyResult)
        return policyResult
    }
    
    /// Check if an external commit is allowed for a conversation
    /// - Parameters:
    ///   - credential: The credential attempting the external commit
    ///   - context: The validation context
    /// - Returns: True if external commit is allowed
    public func isExternalCommitAllowed(
        credential: MLSCredentialInfo,
        context: MLSValidationContext
    ) async -> Bool {
        let policy = await fetchPolicy(for: context.conversationID)
        
        // External commits must be explicitly enabled
        guard policy.allowExternalCommits else {
            logger.warning("⛔️ External commit rejected: disabled by policy for conversation \(context.conversationID.prefix(8))...")
            return false
        }
        
        // Check DID namespace
        guard credential.isTrustedNamespace else {
            logger.warning("⛔️ External commit rejected: untrusted DID namespace for \(credential.identityAsDID ?? "unknown")")
            return false
        }
        
        // Check if this is a rejoin (identity previously in group)
        let isRejoin = await isKnownIdentity(credential, in: context.conversationID)
        if isRejoin {
            return await isRejoinAllowed(credential: credential, context: context, policy: policy)
        }
        
        // New identity via external commit - check invite requirement
        if policy.requireInviteForJoin {
            logger.warning("⛔️ External commit rejected: new identity requires invite")
            return false
        }
        
        logger.info("✅ External commit allowed for \(credential.identityAsDID ?? "unknown")")
        return true
    }
    
    /// Check if a rejoin is allowed for a previously removed member
    /// - Parameters:
    ///   - credential: The credential attempting to rejoin
    ///   - context: The validation context
    ///   - policy: The conversation policy
    /// - Returns: True if rejoin is allowed
    ///
    /// SECURITY: Members who were explicitly removed or kicked by another member
    /// are NOT allowed to rejoin via external commit. They must be explicitly
    /// re-added by an existing member. This prevents removed members from
    /// unilaterally rejoining a conversation they were expelled from.
    public func isRejoinAllowed(
        credential: MLSCredentialInfo,
        context: MLSValidationContext,
        policy: MLSPolicyModel
    ) async -> Bool {
        guard policy.allowRejoin else {
            logger.warning("⛔️ Rejoin rejected: disabled by policy")
            return false
        }
        
        // SECURITY CHECK: Was the member forcibly removed (kicked/removed) or did they leave voluntarily?
        // Only voluntary departures can rejoin via external commit
        let removalInfo = await getRemovalInfo(for: credential, in: context.conversationID)
        
        if let info = removalInfo {
            // Check if this was a forced removal (kicked or removed by another member)
            if info.wasForced {
                logger.warning("⛔️ Rejoin rejected: member was forcibly removed/kicked - must be explicitly re-added")
                logger.warning("   Member: \(credential.identityAsDID ?? "unknown")")
                logger.warning("   Removed by: \(info.actorDID ?? "unknown") at \(info.removalDate)")
                logger.warning("   Event type: \(info.eventType)")
                return false
            }
            
            // Voluntary departure - check rejoin window
            let allowed = policy.canRejoin(removedAt: info.removalDate)
            if !allowed {
                logger.warning("⛔️ Rejoin rejected: outside rejoin window")
            }
            return allowed
        }
        
        // No removal record found - allow if rejoin is enabled
        logger.info("✅ Rejoin allowed for \(credential.identityAsDID ?? "unknown")")
        return true
    }
    
    /// Information about how a member was removed from a conversation
    private struct RemovalInfo {
        let removalDate: Date
        let eventType: String
        let actorDID: String?
        
        /// Whether this was a forced removal (kicked/removed) vs voluntary departure
        var wasForced: Bool {
            eventType == "removed" || eventType == "kicked"
        }
    }
    
    /// Get detailed removal information for a member
    private func getRemovalInfo(for credential: MLSCredentialInfo, in conversationID: String) async -> RemovalInfo? {
        guard let did = credential.identityAsDID else { return nil }
        
        do {
            // Find the most recent removal event with details
            return try await database.read { db in
                if let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT timestamp, eventType, actorDID
                        FROM MLSMembershipEventModel
                        WHERE conversationID = ? AND memberDID = ?
                        AND (eventType = 'removed' OR eventType = 'left' OR eventType = 'kicked')
                        ORDER BY timestamp DESC
                        LIMIT 1
                        """,
                    arguments: [conversationID, did]
                ) {
                    return RemovalInfo(
                        removalDate: row["timestamp"],
                        eventType: row["eventType"],
                        actorDID: row["actorDID"]
                    )
                }
                return nil
            }
        } catch {
            logger.error("❌ Failed to fetch removal info: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Clear the validation cache
    public func clearCache() {
        validationCache.removeAll()
        logger.debug("🗑️ Validation cache cleared")
    }
    
    // MARK: - Private Validation Methods
    
    private func validateDIDNamespace(_ credential: MLSCredentialInfo) -> MLSValidationResult {
        guard let did = credential.identityAsDID else {
            return .denied(reason: "Invalid credential: cannot parse identity as DID")
        }
        
        let hasValidNamespace = allowedDIDNamespaces.contains { did.hasPrefix($0) }
        if hasValidNamespace {
            return .allowed
        } else {
            return .denied(reason: "Untrusted DID namespace: \(did.prefix(20))...")
        }
    }
    
    private func validateJoin(
        credential: MLSCredentialInfo,
        context: MLSValidationContext,
        policy: MLSPolicyModel
    ) async -> MLSValidationResult {
        // Check if this is a known identity (rejoin scenario)
        let isRejoin = await isKnownIdentity(credential, in: context.conversationID)
        
        if isRejoin {
            let allowed = await isRejoinAllowed(credential: credential, context: context, policy: policy)
            return allowed ? .allowed : .denied(reason: "Rejoin not allowed by policy")
        }
        
        // New identity joining
        if policy.requireInviteForJoin {
            let hasInvite = await hasValidInvite(for: credential, in: context.conversationID)
            if !hasInvite {
                return .denied(reason: "New member requires invite")
            }
        }
        
        return .allowed
    }
    
    private func validateAdd(
        credential: MLSCredentialInfo,
        context: MLSValidationContext,
        policy: MLSPolicyModel
    ) async -> MLSValidationResult {
        // Adds are generally allowed if DID namespace is trusted
        // Future: Could implement K-of-N approval for new identities
        return .allowed
    }
    
    private func validateRemove(
        credential: MLSCredentialInfo,
        context: MLSValidationContext,
        policy: MLSPolicyModel
    ) async -> MLSValidationResult {
        // Check last admin protection
        if policy.preventRemovingLastAdmin {
            let isLastAdmin = await isLastAdmin(credential, in: context.conversationID)
            if isLastAdmin {
                return .denied(reason: "Cannot remove last admin")
            }
        }
        
        return .allowed
    }
    
    // MARK: - Database Helpers
    
    private func fetchPolicy(for conversationID: String) async -> MLSPolicyModel {
        do {
            if let policy = try await database.read({ db in
                try MLSPolicyModel
                    .filter(Column("conversationID") == conversationID)
                    .fetchOne(db)
            }) {
                return policy
            }
        } catch {
            logger.error("❌ Failed to fetch policy for \(conversationID.prefix(8))...: \(error.localizedDescription)")
        }
        
        // Return default policy if none exists
        return MLSPolicyModel.defaultPolicy(conversationID: conversationID)
    }
    
    private func isKnownIdentity(_ credential: MLSCredentialInfo, in conversationID: String) async -> Bool {
        guard let did = credential.identityAsDID else { return false }
        
        do {
            // Check membership history
            let hasHistory = try await database.read({ db in
                try MLSMembershipEventModel
                    .filter(Column("conversationID") == conversationID)
                    .filter(Column("memberDID") == did)
                    .fetchCount(db) > 0
            })
            return hasHistory
        } catch {
            logger.error("❌ Failed to check identity history: \(error.localizedDescription)")
            return false
        }
    }
    
    private func getRemovalDate(for credential: MLSCredentialInfo, in conversationID: String) async -> Date? {
        guard let did = credential.identityAsDID else { return nil }
        
        do {
            // Find the most recent removal event - check for "removed" or "left" event types
            return try await database.read({ db in
                try MLSMembershipEventModel
                    .filter(Column("conversationID") == conversationID)
                    .filter(Column("memberDID") == did)
                    .filter(Column("eventType") == "removed" || Column("eventType") == "left")
                    .order(Column("timestamp").desc)
                    .fetchOne(db)?
                    .timestamp
            })
        } catch {
            logger.error("❌ Failed to fetch removal date: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func hasValidInvite(for credential: MLSCredentialInfo, in conversationID: String) async -> Bool {
        guard let did = credential.identityAsDID else { return false }
        
        do {
            // Check for non-revoked invite targeting this DID
            return try await database.read({ db in
                try MLSInviteModel
                    .filter(Column("conversationID") == conversationID)
                    .filter(Column("targetDID") == did)
                    .filter(Column("revoked") == false)
                    .fetchCount(db) > 0
            })
        } catch {
            logger.error("❌ Failed to check invite: \(error.localizedDescription)")
            return false
        }
    }
    
    private func isLastAdmin(_ credential: MLSCredentialInfo, in conversationID: String) async -> Bool {
        guard let did = credential.identityAsDID else { return false }
        
        do {
            return try await database.read { db in
                // Count active admins in this conversation
                let adminCount = try MLSMemberModel
                    .filter(Column("conversationID") == conversationID)
                    .filter(Column("isActive") == true)
                    .filter(Column("role") == "admin")
                    .fetchCount(db)
                
                // Check if this member is one of the admins
                let isAdmin = try MLSMemberModel
                    .filter(Column("conversationID") == conversationID)
                    .filter(Column("did") == did)
                    .filter(Column("isActive") == true)
                    .filter(Column("role") == "admin")
                    .fetchCount(db) > 0
                
                return adminCount == 1 && isAdmin
            }
        } catch {
            logger.error("❌ Failed to check admin status: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Audit Logging
    
    private func logValidationDecision(
        credential: MLSCredentialInfo,
        context: MLSValidationContext,
        result: MLSValidationResult
    ) async {
        let resultString: String
        switch result {
        case .allowed:
            resultString = "ALLOWED"
        case .denied(let reason):
            resultString = "DENIED: \(reason)"
        case .requiresApproval(let reason):
            resultString = "REQUIRES_APPROVAL: \(reason)"
        }
        
        logger.info("""
            📋 Validation Decision:
               - Conversation: \(context.conversationID.prefix(8))...
               - Operation: \(context.operationType.rawValue)
               - Epoch: \(context.currentEpoch)
               - Identity: \(credential.identityAsDID ?? "unknown")
               - Result: \(resultString)
            """)
        
        // Note: persistence of validation decisions to an audit trail is not implemented here.
    }
}

// MARK: - CredentialValidator Protocol Conformance

/// Bridge class that wraps MLSJoinPolicyValidator for the FFI callback interface
/// This is needed because actors cannot directly conform to the callback interface
public final class MLSCredentialValidatorBridge: CredentialValidator {
    private let validator: MLSJoinPolicyValidator
    
    public init(validator: MLSJoinPolicyValidator) {
        self.validator = validator
    }
    
    public func validateCredential(
        credential: CredentialData,
        context: ValidationContext
    ) async -> Bool {
        let credentialInfo = MLSCredentialInfo(
            credentialType: credential.credentialType,
            identity: Data(credential.identity)
        )
        
        let validationContext = MLSValidationContext(
            conversationID: context.conversationId,
            operationType: mapOperationType(context.operationType),
            currentEpoch: context.currentEpoch
        )
        
        let result = await validator.validateCredential(credentialInfo, context: validationContext)
        
        switch result {
        case .allowed:
            return true
        case .denied, .requiresApproval:
            return false
        }
    }
    
    private func mapOperationType(_ type: OperationType) -> MLSOperationType {
        switch type {
        case .join: return .join
        case .add: return .add
        case .update: return .update
        case .remove: return .remove
        case .decrypt: return .decrypt
        }
    }
}
