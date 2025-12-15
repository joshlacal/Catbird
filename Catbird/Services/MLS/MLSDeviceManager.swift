import Foundation
import Petrel
import OSLog
import CryptoKit
import CatbirdMLSCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Manages device registration and identity for MLS multi-device support
@available(iOS 18.0, macOS 13.0, *)
actor MLSDeviceManager {

    // MARK: - Properties

    private static let deviceIdKey = "blue.catbird.mls.deviceId"
    private static let mlsDidKey = "blue.catbird.mls.mlsDid"
    private static let signatureKeyKey = "blue.catbird.mls.signatureKey"
    private static let deviceUUIDKey = "blue.catbird.mls.deviceUUID"
    private static let keychainLogger = Logger(subsystem: "blue.catbird", category: "MLSDeviceManager.Keychain")

    private let apiClient: ATProtoClient
    private let mlsAPIClient: MLSAPIClient
    private let mlsClient: MLSClient
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSDeviceManager")

    // MARK: - Per-User Device Info Storage

    /// Stores device info per user DID
    /// Key: normalized userDID, Value: device info for that user
    private var deviceInfoByUser: [String: UserDeviceInfo] = [:]

    /// Per-user device information
    struct UserDeviceInfo: Codable {
        let deviceId: String
        let mlsDid: String
        let deviceUUID: String?
    }

    private var signaturePrivateKey: Curve25519.Signing.PrivateKey?

    /// Tracks users currently undergoing device registration to prevent race conditions
    /// Actor isolation ensures thread-safe access to this set
    private var registrationInProgress: Set<String> = []
    
    /// Continuations waiting for registration to complete (keyed by normalized user DID)
    private var registrationWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]

    // MARK: - Initialization

    init(apiClient: ATProtoClient, mlsAPIClient: MLSAPIClient, mlsClient: MLSClient) {
        self.apiClient = apiClient
        self.mlsAPIClient = mlsAPIClient
        self.mlsClient = mlsClient

        // Load per-user device info from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "blue.catbird.mls.deviceInfoByUser"),
           let decoded = try? JSONDecoder().decode([String: UserDeviceInfo].self, from: data) {
            self.deviceInfoByUser = decoded
            logger.debug("Loaded device info for \(decoded.count) users")
        }

        // Load signature key from keychain (still global, shared across users on same device)
        if let keyData = try? Self.loadSignatureKey() {
            self.signaturePrivateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        }
    }

    /// Save per-user device info to UserDefaults
    private func saveDeviceInfoStorage() {
        if let data = try? JSONEncoder().encode(deviceInfoByUser) {
            UserDefaults.standard.set(data, forKey: "blue.catbird.mls.deviceInfoByUser")
        }
    }
    
    /// Notify all waiters that registration completed (or failed)
    private func notifyRegistrationWaiters(for userDid: String, error: Error? = nil) {
        guard let waiters = registrationWaiters.removeValue(forKey: userDid) else { return }
        
        for continuation in waiters {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    // MARK: - Device Registration

    /// Registers the device with the MLS service if not already registered
    /// - Parameter userDid: The user's DID for MLS context initialization
    /// - Returns: The MLS DID for this device
    func ensureDeviceRegistered(userDid: String) async throws -> String {
        // Normalize userDID for consistent storage lookup
        let normalizedUserDid = userDid.trimmingCharacters(in: .whitespacesAndNewlines)

        // CRITICAL FIX: Prevent concurrent registration race condition
        // If another call is already registering this user, wait for completion using async/await
        if registrationInProgress.contains(normalizedUserDid) {
            logger.info("⏸️ [RACE CONDITION PREVENTION] Registration already in progress for \(normalizedUserDid.prefix(20)) - waiting...")
            logger.debug("   This prevents multiple devices from being created for the same user")
            logger.debug("   Current registration locks: \(self.registrationInProgress.count)")

            // Use withCheckedThrowingContinuation for efficient async waiting
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Add ourselves to the waiters list
                if registrationWaiters[normalizedUserDid] == nil {
                    registrationWaiters[normalizedUserDid] = []
                }
                registrationWaiters[normalizedUserDid]?.append(continuation)
            }

            logger.info("✅ Concurrent registration completed - re-checking device info")
            // Fall through to re-check if registration succeeded
        }

        // Check if this user already has device registration
        if let existingInfo = deviceInfoByUser[normalizedUserDid] {
            logger.info("✅ [DEVICE ALREADY REGISTERED] Found local device info for user \(normalizedUserDid.prefix(20))")
            logger.debug("   Device ID: \(existingInfo.deviceId)")
            logger.debug("   MLS DID: \(existingInfo.mlsDid)")
            logger.debug("   UUID: \(existingInfo.deviceUUID ?? "N/A")")

            // ✅ CRITICAL FIX: Verify key packages exist on server (not just local device info)
            // This prevents the bug where device appears registered locally but has zero packages on server
            do {
                let stats = try await mlsAPIClient.getKeyPackageStats()
                if stats.available > 0 {
                    logger.info("✅ [KEY PACKAGE VERIFICATION] \(stats.available) key packages available on server - registration valid")
                    
                    // CRITICAL FIX: Perform opportunistic hash sync to clean up orphaned packages
                    // This catches the case where local storage lost bundles but server still has them
                    // Orphaned packages cause NoMatchingKeyPackage when others try to add us
                    do {
                        let localHashes = try await mlsClient.getLocalKeyPackageHashes(for: normalizedUserDid)
                        
                        // Only sync if there's a mismatch (local < server)
                        if localHashes.count < stats.available {
                            logger.info("🔍 [DEVICE CHECK] Potential desync: local=\(localHashes.count), server=\(stats.available) - syncing hashes...")
                            
                            let syncResult = try await mlsAPIClient.syncKeyPackages(
                                localHashes: localHashes,
                                deviceId: existingInfo.deviceUUID ?? ""
                            )
                            
                            if syncResult.orphanedCount > 0 {
                                logger.info("✅ [DEVICE CHECK] Cleaned \(syncResult.deletedCount) orphaned package(s) from server")
                            }
                        }
                    } catch {
                        // Don't fail registration on sync error - device is already registered
                        logger.warning("⚠️ [DEVICE CHECK] Hash sync check failed: \(error.localizedDescription)")
                    }
                    
                    logger.debug("   Skipping device registration - using existing device")
                    return existingInfo.mlsDid
                } else {
                    logger.error("⚠️ INCONSISTENT STATE: Device registered locally but ZERO key packages on server!")
                    logger.error("   This indicates Phase 2 failed previously - clearing local state for clean re-registration")

                    // Clear local device info to trigger full re-registration
                    deviceInfoByUser.removeValue(forKey: normalizedUserDid)
                    saveDeviceInfoStorage()

                    logger.info("🔄 Cleared local device info - proceeding with full re-registration")

                    // CRITICAL FIX: Invalidate stale key packages on server BEFORE uploading new ones.
                    // Without this, other users may fetch a stale package for which we no longer have
                    // the private key, causing NoMatchingKeyPackage on their side and External Commit fallback.
                    logger.info("🔄 [FRESH INSTALL] Syncing with server to invalidate stale key packages...")
                    do {
                        let syncResult = try await mlsAPIClient.syncKeyPackages(
                            localHashes: [],  // Empty = all server packages are orphaned
                            deviceId: existingInfo.deviceUUID ?? UUID().uuidString
                        )
                        logger.info("✅ [FRESH INSTALL] Invalidated \(syncResult.deletedCount) stale key packages")
                    } catch {
                        logger.warning("⚠️ [FRESH INSTALL] Failed to sync stale packages: \(error.localizedDescription)")
                    }

                    // Fall through to full registration (both Phase 1 and Phase 2)
                }
            } catch {
                logger.warning("⚠️ Failed to verify key packages on server: \(error.localizedDescription)")
                logger.warning("   Assuming registration is valid and continuing...")
                return existingInfo.mlsDid
            }
        }

        // Mark registration as in progress to block concurrent calls
        registrationInProgress.insert(normalizedUserDid)
        logger.info("🔐 Starting device registration for user: \(normalizedUserDid.prefix(20)) (marked as in-progress)")

        // Track whether we need to notify waiters on exit
        var registrationError: Error?

        // Ensure we clean up the lock and notify waiters on ALL exit paths
        defer {
            registrationInProgress.remove(normalizedUserDid)
            notifyRegistrationWaiters(for: normalizedUserDid, error: registrationError)
            logger.debug("🔓 Cleared registration lock for \(normalizedUserDid.prefix(20))")
        }

        // Get device UUID (persists across app reinstalls via OS identifier)
        let deviceUUID: String
        if let existingInfo = deviceInfoByUser[normalizedUserDid], let existingUUID = existingInfo.deviceUUID {
            // Reuse UUID from previous registration for this user
            deviceUUID = existingUUID
            logger.info("Using cached device UUID for user: \(deviceUUID)")
        } else {
            // Use identifierForVendor (iOS) or generate and store locally (macOS)
            #if os(iOS)
            if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                deviceUUID = idfv
                logger.info("Using IDFV as device UUID: \(deviceUUID) (persists across reinstalls)")
            } else {
                // Fallback if IDFV unavailable (rare - usually only in simulator during development)
                deviceUUID = try Self.loadDeviceUUID() ?? {
                    let newUUID = UUID().uuidString
                    try? Self.saveDeviceUUID(newUUID)
                    return newUUID
                }()
                logger.info("Generated fallback device UUID: \(deviceUUID) (stored locally)")
            }
            #elseif os(macOS)
            // macOS doesn't have IDFV, so generate and store locally
            deviceUUID = try Self.loadDeviceUUID() ?? {
                let newUUID = UUID().uuidString
                try? Self.saveDeviceUUID(newUUID)
                return newUUID
            }()
            logger.info("Using device UUID: \(deviceUUID) (stored locally)")
            #endif
        }

        // Get device name
        let deviceName = getDeviceName()

        // Generate Ed25519 signature keypair
        let signatureKey: Curve25519.Signing.PrivateKey
        if let existingKey = signaturePrivateKey {
            signatureKey = existingKey
            logger.info("Using existing signature keypair")
        } else {
            signatureKey = Curve25519.Signing.PrivateKey()
            self.signaturePrivateKey = signatureKey
            try Self.saveSignatureKey(signatureKey.rawRepresentation)
            logger.info("Generated new Ed25519 signature keypair")
        }

        // Get signature public key
        let signaturePublicKey = signatureKey.publicKey.rawRepresentation

        // ⭐ CRITICAL FIX: Create key packages with BARE DID BEFORE registration
        // Solution: Since we use bare DID as MLS credential identity (NOT mlsDid),
        // we can create packages before registration. mlsDid is server metadata only.
        logger.info("🔐 Creating key packages with bare DID as credential identity...")
        logger.info("   MLS identity: \(normalizedUserDid)")

        let keyPackageCount = 50
        var keyPackageItems: [BlueCatbirdMlsRegisterDevice.KeyPackageItem] = []

        for i in 1...keyPackageCount {
            // Create KeyPackage with BARE DID as credential identity
            // This allows multiple devices to share the same user-level identity
            // while each device maintains its own unique keypair
            let keyPackageData = try await mlsClient.createKeyPackage(for: userDid, identity: normalizedUserDid)

            // Set expiration to 90 days from now
            let expirationDate = Date().addingTimeInterval(90 * 24 * 60 * 60)

            let keyPackageItem = BlueCatbirdMlsRegisterDevice.KeyPackageItem(
                keyPackage: keyPackageData.base64EncodedString(),
                cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
                expires: ATProtocolDate(date: expirationDate)
            )
            keyPackageItems.append(keyPackageItem)

            if i % 10 == 0 {
                logger.debug("   Created \(i)/\(keyPackageCount) key packages")
            }
        }

        logger.info("✅ Created \(keyPackageItems.count) key packages")

        // MLS state is automatically persisted to SQLite with WAL checkpoint after each bundle
        // The Rust FFI layer now flushes after every create_key_package() call for durability
        logger.info("✅ MLS state auto-flushed to SQLite after each key package creation")

        // Register device with key packages included
        logger.info("📡 Registering device with server (including \(keyPackageItems.count) key packages)...")

        let input = BlueCatbirdMlsRegisterDevice.Input(
            deviceName: deviceName,
            deviceUUID: deviceUUID,  // Persistent UUID for re-registration detection
            keyPackages: keyPackageItems,  // Include all created key packages
            signaturePublicKey: Bytes(data: signaturePublicKey)
        )

        let maxRetries = 3
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                logger.info("📡 Attempting server registration (attempt \(attempt)/\(maxRetries))...")

                let (responseCode, output) = try await apiClient.blue.catbird.mls.registerDevice(input: input)

                guard responseCode == 200, let output = output else {
                    let errorMsg = "HTTP \(responseCode)"
                    logger.error("❌ Registration failed: \(errorMsg)")
                    if let output = output {
                        logger.error("   Response: \(String(describing: output))")
                    }

                    if attempt < maxRetries {
                        let delay = Double(attempt * 2)  // Exponential backoff: 2s, 4s, 6s
                        logger.info("⏳ Retrying in \(delay)s...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    } else {
                        throw MLSError.deviceRegistrationFailed
                    }
                }

                // ✅ Registration Success! Device registered with key packages
                let userDeviceInfo = UserDeviceInfo(
                    deviceId: output.deviceId,
                    mlsDid: output.mlsDid,
                    deviceUUID: deviceUUID
                )

                // Save device info now that registration succeeded
                deviceInfoByUser[normalizedUserDid] = userDeviceInfo
                saveDeviceInfoStorage()

                logger.info("✅ Device registration complete - Device registered for user \(normalizedUserDid.prefix(20)):")
                logger.info("   deviceId: \(output.deviceId)")
                logger.info("   mlsDid: \(output.mlsDid) (metadata only)")
                logger.info("   keyPackages: \(keyPackageItems.count) uploaded")
                logger.info("   autoJoinedConvos: \(output.autoJoinedConvos.count)")
                logger.info("   welcomeMessages: \(output.welcomeMessages?.count ?? 0)")

                // ✅ CRITICAL: Call optIn to record that user has opted into MLS chat
                // This is required for other users to see this user as "available" for group invites
                do {
                    let (optedIn, optedInAt) = try await mlsAPIClient.optIn(deviceId: output.deviceId)
                    logger.info("✅ Opt-in recorded: optedIn=\(optedIn), optedInAt=\(optedInAt)")
                } catch {
                    logger.error("❌ Failed to record opt-in status: \(error.localizedDescription)")
                    logger.error("   User may appear as 'unavailable' when others try to add them to groups")
                    // Don't fail registration - device is registered, just opt-in status is missing
                }

                // Successfully registered - process welcome messages and return
                if let welcomeMessages = output.welcomeMessages, !welcomeMessages.isEmpty {
                    logger.info("Processing \(welcomeMessages.count) welcome messages for auto-joined conversations...")
                    // Note: Welcome messages from device registration are auto-join invitations
                    // from existing conversations. These should be processed to join the groups,
                    // but MLSDeviceManager doesn't have access to MLSConversationManager.
                    // 
                    // Options for implementation:
                    // 1. Return welcome messages to caller (MLSConversationManager.ensureKeyPackagesAvailable)
                    // 2. Emit a notification that MLSConversationManager observes
                    // 3. Store pending welcomes in GRDB for later processing
                    //
                    // For now, MLSConversationManager.syncWithServer() handles fetching
                    // conversations and processing welcomes via separate API calls.
                }

                return output.mlsDid  // Exit function on success
            } catch {
                lastError = error
                logger.error("❌ Registration attempt \(attempt) failed: \(error.localizedDescription)")

                // ✅ CRITICAL FIX: Rollback MLS state on registration failure
                // Clean up key package bundles created before registration attempt
                // Device info was NOT saved (only saved on success), so retry is clean
                do {
                    logger.warning("🔄 Rolling back MLS state (clearing key package bundles)...")
                    try await mlsClient.clearStorage(for: userDid)
                    logger.info("✅ MLS state cleared - ready for clean retry")
                } catch {
                    logger.error("⚠️ Failed to clear MLS state during rollback: \(error.localizedDescription)")
                    // Continue anyway - retry might still succeed or final failure will clear state
                }

                if attempt < maxRetries {
                    let delay = Double(attempt * 2)
                    logger.info("⏳ Retrying in \(delay)s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All retries exhausted - clear signature key for fresh start next time
        logger.error("❌ CRITICAL: Device registration failed after \(maxRetries) attempts")
        logger.error("   Key packages were created but registration with server failed")
        logger.error("   This WILL cause NoMatchingKeyPackage errors when others try to invite this user")
        logger.error("   ACTION REQUIRED: Check server connectivity and re-register device")
        
        // Clear signature key to allow fresh registration attempt
        self.signaturePrivateKey = nil
        try? Self.deleteSignatureKey()
        logger.info("🔄 Cleared signature key for clean retry on next attempt")

        // Set the error so waiters are notified of failure
        registrationError = lastError ?? MLSError.deviceRegistrationFailed
        
        if let error = lastError {
            throw error
        } else {
            throw MLSError.deviceRegistrationFailed
        }
    }

    /// Delete device from server (removes all associated key packages)
    /// This is the CRITICAL first step for recovering from key package desync
    /// - Parameter userDid: The user's DID
    func deleteDevice(for userDid: String) async throws -> Int {
        let normalizedUserDid = userDid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let deviceInfo = deviceInfoByUser[normalizedUserDid] else {
            logger.warning("No deviceId to delete for user \(normalizedUserDid.prefix(20)) - device may not be registered")
            return 0
        }

        logger.info("🗑️ Deleting device \(deviceInfo.deviceId) for user \(normalizedUserDid.prefix(20))...")

        let input = BlueCatbirdMlsDeleteDevice.Input(deviceId: deviceInfo.deviceId)
        let (responseCode, output) = try await apiClient.blue.catbird.mls.deleteDevice(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("❌ Failed to delete device: HTTP \(responseCode)")
            throw MLSError.operationFailed
        }

        let deletedCount = output.keyPackagesDeleted
        logger.info("✅ Device deleted successfully")
        logger.info("   - Deleted: \(output.deleted)")
        logger.info("   - Key packages removed: \(deletedCount)")

        return deletedCount
    }

    /// Forces a re-registration of the device (useful for testing or recovery)
    /// ⚠️ WARNING: This clears server-side bundles FIRST to prevent desync!
    func reregisterDevice(userDid: String) async throws -> String {
        let normalizedUserDid = userDid.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("🔄 Starting full device re-registration for user \(normalizedUserDid.prefix(20))")

        // CRITICAL FIX: Delete device from server FIRST to clear corrupted key packages
        if deviceInfoByUser[normalizedUserDid] != nil {
            do {
                let deletedCount = try await deleteDevice(for: normalizedUserDid)
                logger.info("✅ Cleared \(deletedCount) key packages from server before re-registration")
            } catch {
                logger.error("⚠️ Failed to delete device from server: \(error.localizedDescription)")
                logger.error("   Continuing with re-registration anyway (may cause bundle count mismatch)")
            }
        }

        // Clear stored credentials for this user
        deviceInfoByUser.removeValue(forKey: normalizedUserDid)
        saveDeviceInfoStorage()

        // Invalidate key package cache
        await MLSKeyPackageCache.shared.invalidate()

        // Clear local MLS storage to force fresh start
        logger.info("🗑️ Clearing local MLS storage...")
        try await mlsClient.clearStorage(for: userDid)
        logger.info("✅ Local MLS storage cleared")

        // Re-register with fresh bundles
        logger.info("📝 Re-registering device with fresh key package bundles...")
        return try await ensureDeviceRegistered(userDid: userDid)
    }

    /// Recover from key package desync corruption
    /// This is the main recovery method to call when logs show STORAGE CORRUPTION
    ///
    /// Steps:
    /// 1. Delete device and all server-side key packages
    /// 2. Clear local MLS storage
    /// 3. Re-register with fresh bundles
    /// 4. Note: User must be re-invited to existing conversations
    func recoverFromKeyPackageDesync(userDid: String) async throws {
        logger.error("🚨 RECOVERING FROM KEY PACKAGE DESYNC")
        logger.error("   This will:")
        logger.error("   1. Delete all server-side key packages")
        logger.error("   2. Clear local MLS storage")
        logger.error("   3. Re-register with fresh bundles")
        logger.error("   4. INVALIDATE existing conversations - user must be re-invited")

        let mlsDid = try await reregisterDevice(userDid: userDid)

        logger.info("✅ Recovery complete!")
        logger.info("   New MLS DID: \(mlsDid)")
        logger.warning("⚠️ IMPORTANT: User must be re-invited to existing conversations")
        logger.warning("   Old Welcome messages cannot be decrypted with new key packages")
    }

    // MARK: - Device Info

    /// Gets a human-readable device name
    private func getDeviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Gets device info to include with key package uploads
    /// Get device info for a specific user
    /// - Parameter userDid: The user's DID
    /// - Returns: Device info tuple or nil if not registered
    func getDeviceInfo(for userDid: String) -> (deviceId: String, mlsDid: String, deviceUUID: String?)? {
        let normalizedUserDid = userDid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = deviceInfoByUser[normalizedUserDid] else {
            return nil
        }
        return (info.deviceId, info.mlsDid, info.deviceUUID)
    }

    // MARK: - Keychain Storage

    /// Save signature private key to keychain
    private static func saveSignatureKey(_ keyData: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: signatureKeyKey,
            kSecAttrService as String: "blue.catbird.mls",
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Delete existing key first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update stale item in-place; fall back to delete+add if needed
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: signatureKeyKey,
                kSecAttrService as String: "blue.catbird.mls"
            ]

            let updateAttributes: [String: Any] = [
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

            if updateStatus == errSecSuccess {
                keychainLogger.info("Handled duplicate MLS signature key by updating existing item")
                return
            }

            keychainLogger.error("Failed to update duplicate MLS signature key (status: \(updateStatus)) - retrying with delete/add")
            SecItemDelete(updateQuery as CFDictionary)
            let retryStatus = SecItemAdd(query as CFDictionary, nil)
            guard retryStatus == errSecSuccess else {
                keychainLogger.error("Failed to rewrite MLS signature key after duplicate (status: \(retryStatus))")
                throw MLSError.operationFailed
            }

            keychainLogger.info("Rewrote MLS signature key after clearing duplicate")
            return
        }

        guard status == errSecSuccess else {
            keychainLogger.error("Failed to store MLS signature key (status: \(status))")
            throw MLSError.operationFailed
        }
    }

    /// Load signature private key from keychain
    private static func loadSignatureKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: signatureKeyKey,
            kSecAttrService as String: "blue.catbird.mls",
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let keyData = result as? Data else {
            throw MLSError.operationFailed
        }

        return keyData
    }
    
    /// Delete signature private key from keychain
    private static func deleteSignatureKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: signatureKeyKey,
            kSecAttrService as String: "blue.catbird.mls"
        ]

        let status = SecItemDelete(query as CFDictionary)
        // Ignore errSecItemNotFound - key might not exist
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLSError.operationFailed
        }
    }

    /// Save device UUID to local Keychain (fallback for macOS or when IDFV unavailable)
    private static func saveDeviceUUID(_ uuid: String) throws {
        let data = uuid.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: deviceUUIDKey,
            kSecAttrService as String: "blue.catbird.mls",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            // NOT synchronized - device-local storage only
        ]

        // Delete existing UUID first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MLSError.operationFailed
        }
    }

    /// Load device UUID from local Keychain (fallback for macOS or when IDFV unavailable)
    private static func loadDeviceUUID() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: deviceUUIDKey,
            kSecAttrService as String: "blue.catbird.mls",
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data, let uuid = String(data: data, encoding: .utf8) else {
            return nil  // Return nil instead of throwing for missing UUID
        }

        return uuid
    }

    /// Delete device UUID from local Keychain
    private static func deleteDeviceUUID() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: deviceUUIDKey,
            kSecAttrService as String: "blue.catbird.mls"
        ]

        let status = SecItemDelete(query as CFDictionary)
        // Ignore errSecItemNotFound - UUID might not exist
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLSError.operationFailed
        }
    }
}

// MARK: - Error Extension

extension MLSError {
    static var deviceRegistrationFailed: MLSError {
        .operationFailed
    }
}
