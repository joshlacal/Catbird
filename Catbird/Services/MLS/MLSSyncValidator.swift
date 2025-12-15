import Foundation
import OSLog
import Petrel

/// Actor responsible for periodic validation of MLS device state and sync status
/// Runs validation checks every 6 hours and triggers recovery actions when safe
@available(iOS 18.0, macOS 13.0, *)
final class MLSSyncValidator {
    private let logger = Logger(subsystem: "blue.catbird", category: "SyncValidator")
    private let client: ATProtoClient

    /// Validation interval (6 hours)
    private let validationInterval: TimeInterval = 6 * 60 * 60

    /// Last validation timestamp
    private var lastValidation: Date?

    /// Timer for periodic validation
    private var validationTimer: Timer?

    /// Whether automatic recovery is enabled
    var autoRecoveryEnabled: Bool = true

    init(client: ATProtoClient) {
        self.client = client
    }

    /// Start periodic sync validation
    func startPeriodicValidation() {
        logger.info("Starting periodic sync validation (interval: 6 hours)")

        // Perform initial validation after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            await performValidation()
        }

        // Schedule periodic validation
        validationTimer = Timer.scheduledTimer(
            withTimeInterval: validationInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.performValidation()
            }
        }
    }

    /// Stop periodic sync validation
    func stopPeriodicValidation() {
        logger.info("Stopping periodic sync validation")
        validationTimer?.invalidate()
        validationTimer = nil
    }

    /// Perform a sync validation check
    func performValidation() async {
        logger.info("Starting sync validation check")
        lastValidation = Date()

        do {
            // Call validateDeviceState endpoint
            let input = BlueCatbirdMlsValidateDeviceState.Parameters(deviceId: nil)
            let (responseCode, output) = try await client.blue.catbird.mls.validateDeviceState(input: input)

            guard responseCode == 200, let output = output else {
                logger.error("Validation failed with HTTP \(responseCode)")
                return
            }

            // Log validation results
            if output.isValid {
                logger.info("✅ Device state is valid")
            } else {
                logger.warning("⚠️ Device state validation failed")
                logger.warning("Issues: \(output.issues.joined(separator: ", "))")
                logger.warning("Recommendations: \(output.recommendations.joined(separator: ", "))")
            }

            // Log detailed stats
            logger.info("Conversation stats: expected=\(output.expectedConvos ?? 0), actual=\(output.actualConvos ?? 0)")
            if let inventory = output.keyPackageInventory {
                logger.info("Key package inventory: available=\(inventory.available), target=\(inventory.target)")
            }

            // Trigger automatic recovery if enabled and safe
            if !output.isValid && autoRecoveryEnabled {
                await performRecoveryActions(validation: output)
            }

        } catch {
            logger.error("Sync validation failed: \(error.localizedDescription)")
        }
    }

    /// Perform automatic recovery actions based on validation results
    private func performRecoveryActions(validation: BlueCatbirdMlsValidateDeviceState.Output) async {
        logger.info("Performing automatic recovery actions")

        // 1. Replenish key packages if below threshold
        if let inventory = validation.keyPackageInventory, inventory.available < inventory.target {
            logger.info("🔑 Key package inventory low - need replenishment")
            logger.info("   Available: \(inventory.available), Target: \(inventory.target)")
            // Note: Key package replenishment is handled by MLSKeyPackageMonitor
            // We just log the recommendation here
        }

        // 2. Log conversation mismatches (manual review needed for safety)
        let expected = validation.expectedConvos ?? 0
        let actual = validation.actualConvos ?? 0
        if expected > 0 && expected != actual {
            logger.warning("⚠️ Conversation mismatch detected")
            logger.warning("   Expected: \(expected), Actual: \(actual)")
            logger.warning("   This may require manual rejoin via getExpectedConversations endpoint")
        }

        // 3. Log recommendations
        for recommendation in validation.recommendations {
            logger.info("💡 Recommendation: \(recommendation)")
        }
    }

    /// Get time until next validation
    var timeUntilNextValidation: TimeInterval? {
        guard let lastValidation = lastValidation else {
            return nil
        }
        let nextValidation = lastValidation.addingTimeInterval(validationInterval)
        return nextValidation.timeIntervalSinceNow
    }

    /// Get time since last validation
    var timeSinceLastValidation: TimeInterval? {
        guard let lastValidation = lastValidation else {
            return nil
        }
        return Date().timeIntervalSince(lastValidation)
    }
}
