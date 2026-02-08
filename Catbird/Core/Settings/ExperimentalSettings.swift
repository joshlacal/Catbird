//
//  ExperimentalSettings.swift
//  Catbird
//
//  Settings for experimental features that are not yet ready for general use.
//  Features gated here may have bugs, missing functionality, or data loss risks.
//

import SwiftUI
import OSLog

/// Global settings manager for experimental features
/// Features here are considered "highly experimental" and require explicit opt-in
@Observable
final class ExperimentalSettings {
    static let shared = ExperimentalSettings()
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ExperimentalSettings")
    
    // MARK: - Per-Account MLS Chat Settings
    
    /// Storage key prefix for per-account MLS opt-in
    private static let mlsOptInKeyPrefix = "blue.catbird.mls.optedIn."
    
    /// Storage key prefix for per-account MLS warning acknowledgment
    private static let mlsWarningAcknowledgedKeyPrefix = "blue.catbird.mls.warningAcknowledged."
    
    private init() {}
    
    // MARK: - Per-Account MLS Methods
    
    /// Check if MLS chat is enabled for a specific account
    /// - Parameter accountDID: The DID of the account to check
    /// - Returns: True if MLS chat is enabled for this account
    func isMLSChatEnabled(for accountDID: String) -> Bool {
        let key = Self.mlsOptInKeyPrefix + accountDID
        return UserDefaults.standard.bool(forKey: key)
    }
    
    /// Check if the user has acknowledged the MLS warning for a specific account
    /// - Parameter accountDID: The DID of the account to check
    /// - Returns: True if the warning has been acknowledged
    func hasAcknowledgedMLSWarning(for accountDID: String) -> Bool {
        let key = Self.mlsWarningAcknowledgedKeyPrefix + accountDID
        return UserDefaults.standard.bool(forKey: key)
    }
    
    /// Enable MLS chat for a specific account after user acknowledges the warning
    /// - Parameter accountDID: The DID of the account to enable MLS for
    func enableMLSChat(for accountDID: String) {
        let optInKey = Self.mlsOptInKeyPrefix + accountDID
        let warningKey = Self.mlsWarningAcknowledgedKeyPrefix + accountDID
        
        UserDefaults.standard.set(true, forKey: warningKey)
        UserDefaults.standard.set(true, forKey: optInKey)
        
        logger.info("MLS chat enabled for account: \(accountDID.prefix(20))...")
    }
    
    /// Disable MLS chat for a specific account (keeps acknowledgment for future)
    /// - Parameter accountDID: The DID of the account to disable MLS for
    func disableMLSChat(for accountDID: String) {
        let optInKey = Self.mlsOptInKeyPrefix + accountDID
        UserDefaults.standard.set(false, forKey: optInKey)
        
        logger.info("MLS chat disabled for account: \(accountDID.prefix(20))...")
    }
    
    /// Reset MLS settings for a specific account (e.g., on logout)
    /// - Parameter accountDID: The DID of the account to reset
    func resetMLSSettings(for accountDID: String) {
        let optInKey = Self.mlsOptInKeyPrefix + accountDID
        let warningKey = Self.mlsWarningAcknowledgedKeyPrefix + accountDID
        
        UserDefaults.standard.removeObject(forKey: optInKey)
        UserDefaults.standard.removeObject(forKey: warningKey)
        
        logger.info("MLS settings reset for account: \(accountDID.prefix(20))...")
    }
    
    /// Get all account DIDs that have MLS enabled
    /// - Returns: Array of DIDs with MLS enabled
    func accountsWithMLSEnabled() -> [String] {
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        let prefix = Self.mlsOptInKeyPrefix
        
        return allKeys
            .filter { $0.hasPrefix(prefix) }
            .compactMap { key -> String? in
                let did = String(key.dropFirst(prefix.count))
                return UserDefaults.standard.bool(forKey: key) ? did : nil
            }
    }
    
    // MARK: - Legacy Compatibility (deprecated, use per-account methods)
    
    /// Whether MLS end-to-end encrypted chat is enabled (DEPRECATED: use isMLSChatEnabled(for:))
    /// This now returns true if ANY account has MLS enabled, for backward compatibility
    @available(*, deprecated, message: "Use isMLSChatEnabled(for:) instead")
    var mlsChatEnabled: Bool {
        get { !accountsWithMLSEnabled().isEmpty }
        set { /* No-op for legacy compatibility */ }
    }
    
    /// Whether the user has acknowledged the experimental warning (DEPRECATED)
    @available(*, deprecated, message: "Use hasAcknowledgedMLSWarning(for:) instead")
    var hasAcknowledgedMLSWarning: Bool {
        get { true } // Assume acknowledged if using legacy API
        set { /* No-op for legacy compatibility */ }
    }
    
    /// Enable MLS chat (DEPRECATED: use enableMLSChat(for:))
    @available(*, deprecated, message: "Use enableMLSChat(for:) instead")
    func enableMLSChat() {
        logger.warning("Called deprecated enableMLSChat() - use enableMLSChat(for:) instead")
    }
    
    /// Disable MLS chat (DEPRECATED: use disableMLSChat(for:))
    @available(*, deprecated, message: "Use disableMLSChat(for:) instead")
    func disableMLSChat() {
        logger.warning("Called deprecated disableMLSChat() - use disableMLSChat(for:) instead")
    }
    
    /// Reset all experimental settings (DEPRECATED)
    @available(*, deprecated, message: "Use resetMLSSettings(for:) instead")
    func resetAll() {
        logger.warning("Called deprecated resetAll() - use resetMLSSettings(for:) instead")
    }
}
