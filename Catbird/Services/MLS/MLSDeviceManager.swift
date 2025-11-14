import Foundation
import Petrel
import OSLog
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
    private static let credentialDidKey = "blue.catbird.mls.credentialDid"

    private let apiClient: ATProtoClient
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSDeviceManager")

    // MARK: - Stored Device Info

    private(set) var deviceId: String?
    private(set) var credentialDid: String?

    // MARK: - Initialization

    init(apiClient: ATProtoClient) {
        self.apiClient = apiClient

        // Load stored device info
        self.deviceId = UserDefaults.standard.string(forKey: Self.deviceIdKey)
        self.credentialDid = UserDefaults.standard.string(forKey: Self.credentialDidKey)
    }

    // MARK: - Device Registration

    /// Registers the device with the MLS service if not already registered
    /// - Returns: The credential DID for this device
    func ensureDeviceRegistered() async throws -> String {
        // If we already have a credential DID, return it
        if let credentialDid = credentialDid {
            logger.info("Device already registered with credentialDid: \(credentialDid)")
            return credentialDid
        }

        // Generate or retrieve device ID
        let deviceId = try getOrCreateDeviceId()

        // Get device info
        let deviceName = getDeviceName()
        let platform = getPlatform()
        let appVersion = getAppVersion()

        logger.info("Registering device: \(deviceId), name: \(deviceName), platform: \(platform)")

        // Register with server
        let input = BlueCatbirdMlsRegisterDevice.Input(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            appVersion: appVersion
        )

        let (responseCode, output) = try await apiClient.blue.catbird.mls.registerDevice(input: input)

        guard responseCode == 200, let output = output else {
            logger.error("Failed to register device: HTTP \(responseCode)")
            throw MLSError.deviceRegistrationFailed
        }

        // Store the credential DID
        let credentialDid = output.credentialDid
        self.credentialDid = credentialDid
        UserDefaults.standard.set(credentialDid, forKey: Self.credentialDidKey)

        logger.info("Device registered successfully: \(credentialDid), isNewDevice: \(output.isNewDevice ?? false)")

        return credentialDid
    }

    /// Forces a re-registration of the device (useful for testing or recovery)
    func reregisterDevice() async throws -> String {
        // Clear stored credential
        self.credentialDid = nil
        UserDefaults.standard.removeObject(forKey: Self.credentialDidKey)

        // Re-register
        return try await ensureDeviceRegistered()
    }

    // MARK: - Device Info

    /// Gets or creates a persistent device ID
    private func getOrCreateDeviceId() throws -> String {
        if let deviceId = deviceId {
            return deviceId
        }

        // Generate new device ID
        let newDeviceId = UUID().uuidString
        self.deviceId = newDeviceId
        UserDefaults.standard.set(newDeviceId, forKey: Self.deviceIdKey)

        logger.info("Generated new device ID: \(newDeviceId)")
        return newDeviceId
    }

    /// Gets a human-readable device name
    private func getDeviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Gets the platform identifier
    private func getPlatform() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #endif
    }

    /// Gets the app version
    private func getAppVersion() -> String? {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - Device Info for Key Packages

    /// Gets device info to include with key package uploads
    func getDeviceInfo() -> (deviceId: String, credentialDid: String)? {
        guard let deviceId = deviceId, let credentialDid = credentialDid else {
            return nil
        }
        return (deviceId, credentialDid)
    }
}

// MARK: - Error Extension

extension MLSError {
    static var deviceRegistrationFailed: MLSError {
        .operationFailed
    }
}
