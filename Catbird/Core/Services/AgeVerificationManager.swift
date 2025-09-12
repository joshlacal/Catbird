import Foundation
import OSLog
import Petrel
import SwiftUI

/// Manages age verification, content policies, and compliance requirements
@Observable
final class AgeVerificationManager {
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AgeVerificationManager")
    
    /// Current age verification state - must be accessed on MainActor
    @MainActor
    private(set) var verificationState: AgeVerificationState = .unknown
    
    /// Whether the current user needs age verification - must be accessed on MainActor
    @MainActor
    private(set) var needsAgeVerification: Bool = false
    
    /// Current user's age group based on birth date - must be accessed on MainActor
    @MainActor
    private(set) var currentAgeGroup: AgeGroup = .unknown
    
    /// Age-based content policy currently in effect - must be accessed on MainActor
    @MainActor
    private(set) var contentPolicy: AgeBasedContentPolicy = .restrictive
    
    // Dependencies
    private let preferencesManagerLock = NSLock()
    private weak var _preferencesManager: PreferencesManager?
    
    private var preferencesManager: PreferencesManager? {
        preferencesManagerLock.lock()
        defer { preferencesManagerLock.unlock() }
        return _preferencesManager
    }
    
    // MARK: - Types
    
    enum AgeVerificationState: Equatable {
        case unknown
        case required
        case inProgress
        case completed
        case failed(String)
    }
    
    enum AgeGroup: CaseIterable {
        case unknown
        case under13    // COPPA protected
        case teen       // 13-17
        case adult      // 18+
        
        var displayName: String {
            switch self {
            case .unknown: return "Unknown"
            case .under13: return "Under 13"
            case .teen: return "13-17"
            case .adult: return "18+"
            }
        }
        
        var requiresParentalConsent: Bool {
            switch self {
            case .under13: return true
            default: return false
            }
        }
        
        var canAccessAdultContent: Bool {
            switch self {
            case .adult: return true
            default: return false
            }
        }
    }
    
    struct AgeBasedContentPolicy {
        let adultContentAllowed: Bool
        let suggestiveContentAllowed: Bool
        let violentContentAllowed: Bool
        let defaultContentVisibility: ContentVisibility
        let canModifySettings: Bool
        let requiresParentalConsent: Bool
        
        static let restrictive = AgeBasedContentPolicy(
            adultContentAllowed: false,
            suggestiveContentAllowed: false,
            violentContentAllowed: false,
            defaultContentVisibility: .hide,
            canModifySettings: false,
            requiresParentalConsent: true
        )
        
        static let moderate = AgeBasedContentPolicy(
            adultContentAllowed: false,
            suggestiveContentAllowed: true,
            violentContentAllowed: false,
            defaultContentVisibility: .warn,
            canModifySettings: true,
            requiresParentalConsent: false
        )
        
        static let permissive = AgeBasedContentPolicy(
            adultContentAllowed: true,
            suggestiveContentAllowed: true,
            violentContentAllowed: true,
            defaultContentVisibility: .show,
            canModifySettings: true,
            requiresParentalConsent: false
        )
    }
    
    // MARK: - Initialization
    
    init(preferencesManager: PreferencesManager? = nil) {
        preferencesManagerLock.lock()
        _preferencesManager = preferencesManager
        preferencesManagerLock.unlock()
        logger.debug("AgeVerificationManager initialized")
    }
    
    func updatePreferencesManager(_ preferencesManager: PreferencesManager?) {
        preferencesManagerLock.lock()
        _preferencesManager = preferencesManager
        preferencesManagerLock.unlock()
    }
    
    // MARK: - Public Interface
    
    /// Check if age verification is needed for the current user
    @MainActor
    func checkAgeVerificationStatus() async {
        logger.debug("Checking age verification status")
        
        guard let preferencesManager = preferencesManager else {
            logger.warning("PreferencesManager not available")
            verificationState = .failed("Preferences manager not available")
            return
        }
        
        do {
            let preferences = try await preferencesManager.getPreferences()
            
            if let birthDate = preferences.birthDate {
                // Validate birth date before trusting it
                guard isValidBirthDate(birthDate) else {
                    logger.warning("Stored birth date is invalid: \(birthDate), requiring fresh verification")
                    verificationState = .required
                    needsAgeVerification = true
                    currentAgeGroup = .unknown
                    contentPolicy = .restrictive // Safe default for invalid data
                    return
                }
                
                // User has valid birth date - calculate age and set policies
                let ageGroup = calculateAgeGroup(from: birthDate)
                await updateAgeGroup(ageGroup)
                verificationState = .completed
                needsAgeVerification = false
                logger.info("Age verification completed - Age group: \(ageGroup.displayName)")
            } else {
                // No birth date - verification required
                verificationState = .required
                needsAgeVerification = true
                currentAgeGroup = .unknown
                contentPolicy = .restrictive // Safe default
                logger.info("Age verification required - no birth date found")
            }
        } catch {
            logger.error("Failed to check age verification status: \(error.localizedDescription)")
            verificationState = .failed(error.localizedDescription)
            needsAgeVerification = true
            contentPolicy = .restrictive // Safe default on error
        }
    }
    
    /// Start the age verification process
    @MainActor
    func startAgeVerification() {
        logger.info("Starting age verification process")
        verificationState = .inProgress
    }
    
    /// Complete age verification with provided birth date
    @MainActor
    func completeAgeVerification(birthDate: Date) async -> Bool {
        logger.info("Completing age verification")
        
        guard let preferencesManager = preferencesManager else {
            logger.error("PreferencesManager not available during verification")
            verificationState = .failed("Preferences manager not available")
            return false
        }
        
        // Validate birth date before attempting to save
        guard isValidBirthDate(birthDate) else {
            logger.error("Invalid birth date provided: \(birthDate)")
            verificationState = .failed("Invalid birth date")
            return false
        }
        
        do {
            // Track verification attempt
            logAgeVerificationEvent("verification_started", ageGroup: calculateAgeGroup(from: birthDate))
            
            // Update local state first (optimistic update)
            let ageGroup = calculateAgeGroup(from: birthDate)
            await updateAgeGroup(ageGroup)
            
            // Save birth date to server with retry mechanism
            try await saveWithRetry {
                try await preferencesManager.setBirthDate(birthDate)
            }
            
            // Apply age-based content policies
            try await applyAgeBasedContentPolicies(for: ageGroup)
            
            verificationState = .completed
            needsAgeVerification = false
            
            // Track successful completion
            logAgeVerificationEvent("verification_completed", ageGroup: ageGroup)
            
            logger.info("Age verification completed successfully - Age group: \(ageGroup.displayName)")
            return true
            
        } catch {
            logger.error("Failed to complete age verification: \(error.localizedDescription)")
            
            // Track failure
            logAgeVerificationEvent("verification_failed", error: error)
            
            // Revert optimistic update on failure
            currentAgeGroup = .unknown
            contentPolicy = .restrictive
            
            verificationState = .failed(error.localizedDescription)
            return false
        }
    }
    
    /// Validate birth date is reasonable
    private func isValidBirthDate(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        
        // Must be in the past
        guard date <= now else { return false }
        
        // Must be within reasonable human lifespan (120 years)
        guard let minimumDate = calendar.date(byAdding: .year, value: -120, to: now),
              date >= minimumDate else { return false }
        
        return true
    }
    
    /// Retry mechanism for critical network operations
    private func saveWithRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                logger.warning("Save attempt \(attempt) failed: \(error.localizedDescription)")
                
                if attempt < maxAttempts {
                    // Exponential backoff: 1s, 2s, 4s
                    let delay = TimeInterval(1 << (attempt - 1))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? AgeVerificationError.serverSyncFailed
    }
    
    /// Get the current user's age in years (if birth date is available)
    func getCurrentAge() async -> Int? {
        guard let preferencesManager = preferencesManager else { return nil }
        
        do {
            let preferences = try await preferencesManager.getPreferences()
            guard let birthDate = preferences.birthDate else { return nil }
            
            let calendar = Calendar.current
            let ageComponents = calendar.dateComponents([.year], from: birthDate, to: Date())
            return ageComponents.year
        } catch {
            logger.error("Failed to get current age: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Check if user can access adult content based on age
    @MainActor
    func canAccessAdultContent() -> Bool {
        return currentAgeGroup.canAccessAdultContent && contentPolicy.adultContentAllowed
    }
    
    /// Check if user needs parental consent
    @MainActor
    func requiresParentalConsent() -> Bool {
        return currentAgeGroup.requiresParentalConsent || contentPolicy.requiresParentalConsent
    }
    
    /// Get age-appropriate content filter defaults
    @MainActor
    func getAgeAppropriateContentDefaults() -> (adultContentEnabled: Bool, contentLabelPrefs: [ContentLabelPreference]) {
        var contentLabelPrefs: [ContentLabelPreference] = []
        
        // Adult content
        contentLabelPrefs.append(ContentLabelPreference(
            labelerDid: nil,
            label: "nsfw",
            visibility: contentPolicy.adultContentAllowed ? contentPolicy.defaultContentVisibility.rawValue : ContentVisibility.hide.rawValue
        ))
        
        // Suggestive content
        contentLabelPrefs.append(ContentLabelPreference(
            labelerDid: nil,
            label: "suggestive",
            visibility: contentPolicy.suggestiveContentAllowed ? contentPolicy.defaultContentVisibility.rawValue : ContentVisibility.hide.rawValue
        ))
        
        // Violent content
        contentLabelPrefs.append(ContentLabelPreference(
            labelerDid: nil,
            label: "graphic",
            visibility: contentPolicy.violentContentAllowed ? contentPolicy.defaultContentVisibility.rawValue : ContentVisibility.hide.rawValue
        ))
        
        // Non-sexual nudity
        contentLabelPrefs.append(ContentLabelPreference(
            labelerDid: nil,
            label: "nudity",
            visibility: contentPolicy.suggestiveContentAllowed ? contentPolicy.defaultContentVisibility.rawValue : ContentVisibility.warn.rawValue
        ))
        
        return (
            adultContentEnabled: contentPolicy.adultContentAllowed,
            contentLabelPrefs: contentLabelPrefs
        )
    }
    
    // MARK: - Private Methods
    
    private func calculateAgeGroup(from birthDate: Date) -> AgeGroup {
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthDate, to: Date())
        
        guard let age = ageComponents.year else {
            logger.warning("Could not calculate age from birth date")
            return .unknown
        }
        
        switch age {
        case 0..<13:
            return .under13
        case 13..<18:
            return .teen
        case 18...:
            return .adult
        default:
            return .unknown
        }
    }
    
    @MainActor
    private func updateAgeGroup(_ ageGroup: AgeGroup) {
        currentAgeGroup = ageGroup
        
        // Update content policy based on age group
        switch ageGroup {
        case .unknown:
            contentPolicy = .restrictive
        case .under13:
            contentPolicy = .restrictive
        case .teen:
            contentPolicy = .moderate
        case .adult:
            contentPolicy = .permissive
        }
        
        logger.debug("Updated age group to \(ageGroup.displayName) with policy: \(self.contentPolicy.adultContentAllowed ? "permissive" : "restrictive")")
    }
    
    private func applyAgeBasedContentPolicies(for ageGroup: AgeGroup) async throws {
        guard let preferencesManager = preferencesManager else {
            throw AgeVerificationError.preferencesManagerUnavailable
        }
        
        logger.info("Applying age-based content policies for age group: \(ageGroup.displayName)")
        
        // Get current preferences to preserve user choices where appropriate
        let currentPreferences = try await preferencesManager.getPreferences()
        let defaults = await getAgeAppropriateContentDefaults()
        
        // Only apply restrictions for minors or unsafe settings
        switch ageGroup {
        case .adult:
            // For adults, preserve their existing preferences - no need to override
            logger.info("Adult user - preserving existing content preferences")
            
            // Only ensure adult content is enabled if they want it
            if !currentPreferences.adultContentEnabled && defaults.adultContentEnabled {
                try await preferencesManager.updateAdultContentEnabled(true)
                logger.info("Enabled adult content for verified adult user")
            }
            
        case .teen, .under13:
            // For minors, apply restrictive policies regardless of current settings
            logger.info("Minor user - applying age-appropriate restrictions")
            
            // Disable adult content for minors
            if currentPreferences.adultContentEnabled {
                try await preferencesManager.updateAdultContentEnabled(false)
            }
            
            // Apply age-appropriate content label restrictions
            try await preferencesManager.updateContentLabelPreferences(defaults.contentLabelPrefs)
            
        case .unknown:
            // Unknown age - apply restrictive defaults
            logger.info("Unknown age - applying restrictive defaults")
            try await preferencesManager.updateAdultContentEnabled(false)
            try await preferencesManager.updateContentLabelPreferences(defaults.contentLabelPrefs)
        }
        
        logger.info("Age-based content policies applied successfully")
    }
    
    /// Log age verification events for analytics and monitoring
    private func logAgeVerificationEvent(_ event: String, ageGroup: AgeGroup? = nil, error: Error? = nil) {
        var eventData: [String: Any] = [
            "event": event,
            "timestamp": Date().timeIntervalSince1970,
            "session_id": UUID().uuidString // In production, use actual session ID
        ]
        
        if let ageGroup = ageGroup {
            eventData["age_group"] = ageGroup.displayName
            eventData["requires_parental_consent"] = ageGroup.requiresParentalConsent
            eventData["can_access_adult_content"] = ageGroup.canAccessAdultContent
        }
        
        if let error = error {
            eventData["error"] = error.localizedDescription
            eventData["error_domain"] = (error as NSError).domain
            eventData["error_code"] = (error as NSError).code
        }
        
        // Log structured data for analytics
        logger.info("Age verification event: \(event), data: \(eventData)")
        
        // In production, also send to analytics service
        // AnalyticsManager.shared.track(event: "age_verification", properties: eventData)
        
        // Track compliance metrics
        switch event {
        case "verification_started":
            logger.debug("Age verification process initiated")
        case "verification_completed":
            logger.info("Age verification completed successfully for \(ageGroup?.displayName ?? "unknown") age group")
        case "verification_failed":
            logger.error("Age verification failed: \(error?.localizedDescription ?? "unknown error")")
        default:
            logger.debug("Age verification event: \(event)")
        }
    }
}

// MARK: - Error Types

enum AgeVerificationError: LocalizedError {
    case preferencesManagerUnavailable
    case invalidBirthDate
    case serverSyncFailed
    
    var errorDescription: String? {
        switch self {
        case .preferencesManagerUnavailable:
            return "Preferences manager is not available"
        case .invalidBirthDate:
            return "Invalid birth date provided"
        case .serverSyncFailed:
            return "Failed to sync age verification with server"
        }
    }
}
