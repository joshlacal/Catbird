import Testing
import Foundation
@testable import Catbird

@MainActor
struct AgeVerificationTests {
    
    // MARK: - Age Group Calculation Tests
    
    @Test("Age group calculation for adult (18+)")
    func testAdultAgeGroupCalculation() async {
        let ageVerificationManager = AgeVerificationManager()
        
        // Test 18 years old (exactly)
        let eighteenYearsAgo = Calendar.current.date(byAdding: .year, value: -18, to: Date())!
        let result = await ageVerificationManager.completeAgeVerification(birthDate: eighteenYearsAgo)
        
        #expect(result == true)
        #expect(ageVerificationManager.currentAgeGroup == .adult)
        #expect(ageVerificationManager.canAccessAdultContent() == true)
        #expect(ageVerificationManager.requiresParentalConsent() == false)
    }
    
    @Test("Age group calculation for teen (13-17)")
    func testTeenAgeGroupCalculation() async {
        let ageVerificationManager = AgeVerificationManager()
        
        // Test 16 years old
        let sixteenYearsAgo = Calendar.current.date(byAdding: .year, value: -16, to: Date())!
        let result = await ageVerificationManager.completeAgeVerification(birthDate: sixteenYearsAgo)
        
        #expect(result == true)
        #expect(ageVerificationManager.currentAgeGroup == .teen)
        #expect(ageVerificationManager.canAccessAdultContent() == false)
        #expect(ageVerificationManager.requiresParentalConsent() == false)
    }
    
    @Test("Age group calculation for under 13")
    func testUnder13AgeGroupCalculation() async {
        let ageVerificationManager = AgeVerificationManager()
        
        // Test 10 years old
        let tenYearsAgo = Calendar.current.date(byAdding: .year, value: -10, to: Date())!
        let result = await ageVerificationManager.completeAgeVerification(birthDate: tenYearsAgo)
        
        #expect(result == true)
        #expect(ageVerificationManager.currentAgeGroup == .under13)
        #expect(ageVerificationManager.canAccessAdultContent() == false)
        #expect(ageVerificationManager.requiresParentalConsent() == true)
    }
    
    // MARK: - Content Policy Tests
    
    @Test("Adult content policy for different age groups")
    func testAdultContentPolicyByAge() async {
        // Test adult (18+)
        let adultManager = AgeVerificationManager()
        let adultBirthDate = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
        await adultManager.completeAgeVerification(birthDate: adultBirthDate)
        
        let adultDefaults = adultManager.getAgeAppropriateContentDefaults()
        #expect(adultDefaults.adultContentEnabled == true)
        
        // Verify NSFW content label
        let adultNsfwPref = adultDefaults.contentLabelPrefs.first { $0.label == "nsfw" }
        #expect(adultNsfwPref?.visibility == ContentVisibility.show.rawValue)
        
        // Test teen (13-17)
        let teenManager = AgeVerificationManager()
        let teenBirthDate = Calendar.current.date(byAdding: .year, value: -16, to: Date())!
        await teenManager.completeAgeVerification(birthDate: teenBirthDate)
        
        let teenDefaults = teenManager.getAgeAppropriateContentDefaults()
        #expect(teenDefaults.adultContentEnabled == false)
        
        // Verify NSFW content is hidden for teens
        let teenNsfwPref = teenDefaults.contentLabelPrefs.first { $0.label == "nsfw" }
        #expect(teenNsfwPref?.visibility == ContentVisibility.hide.rawValue)
    }
    
    @Test("Suggestive content policy for different age groups")
    func testSuggestiveContentPolicyByAge() async {
        // Test adult - should allow suggestive content
        let adultManager = AgeVerificationManager()
        let adultBirthDate = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
        await adultManager.completeAgeVerification(birthDate: adultBirthDate)
        
        let adultDefaults = adultManager.getAgeAppropriateContentDefaults()
        let adultSuggestivePref = adultDefaults.contentLabelPrefs.first { $0.label == "suggestive" }
        #expect(adultSuggestivePref?.visibility == ContentVisibility.show.rawValue)
        
        // Test teen - should allow suggestive content with warnings
        let teenManager = AgeVerificationManager()
        let teenBirthDate = Calendar.current.date(byAdding: .year, value: -16, to: Date())!
        await teenManager.completeAgeVerification(birthDate: teenBirthDate)
        
        let teenDefaults = teenManager.getAgeAppropriateContentDefaults()
        let teenSuggestivePref = teenDefaults.contentLabelPrefs.first { $0.label == "suggestive" }
        #expect(teenSuggestivePref?.visibility == ContentVisibility.warn.rawValue)
        
        // Test under 13 - should hide suggestive content
        let childManager = AgeVerificationManager()
        let childBirthDate = Calendar.current.date(byAdding: .year, value: -10, to: Date())!
        await childManager.completeAgeVerification(birthDate: childBirthDate)
        
        let childDefaults = childManager.getAgeAppropriateContentDefaults()
        let childSuggestivePref = childDefaults.contentLabelPrefs.first { $0.label == "suggestive" }
        #expect(childSuggestivePref?.visibility == ContentVisibility.hide.rawValue)
    }
    
    // MARK: - Content Filter Manager Integration Tests
    
    @Test("Age-appropriate visibility overrides user preferences")
    func testAgeAppropriateVisibilityOverride() {
        let teenManager = AgeVerificationManager()
        
        // Simulate teen trying to set adult content to "show"
        let teenBirthDate = Calendar.current.date(byAdding: .year, value: -16, to: Date())!
        Task {
            await teenManager.completeAgeVerification(birthDate: teenBirthDate)
        }
        
        // Create preference that would normally allow adult content
        let userPreferences = [
            ContentLabelPreference(labelerDid: nil, label: "nsfw", visibility: "show")
        ]
        
        // Age verification should override this for teens
        let effectiveVisibility = ContentFilterManager.getAgeAppropriateVisibility(
            label: "nsfw",
            preferences: userPreferences,
            ageVerificationManager: teenManager
        )
        
        #expect(effectiveVisibility == .hide)
    }
    
    @Test("Adult users can set their own preferences")
    func testAdultUserPreferencesRespected() {
        let adultManager = AgeVerificationManager()
        
        // Simulate adult setting adult content to "warn"
        let adultBirthDate = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
        Task {
            await adultManager.completeAgeVerification(birthDate: adultBirthDate)
        }
        
        let userPreferences = [
            ContentLabelPreference(labelerDid: nil, label: "nsfw", visibility: "warn")
        ]
        
        // Adult preferences should be respected
        let effectiveVisibility = ContentFilterManager.getAgeAppropriateVisibility(
            label: "nsfw",
            preferences: userPreferences,
            ageVerificationManager: adultManager
        )
        
        #expect(effectiveVisibility == .warn)
    }
    
    // MARK: - Verification State Tests
    
    @Test("Initial verification state is unknown")
    func testInitialVerificationState() {
        let ageVerificationManager = AgeVerificationManager()
        
        #expect(ageVerificationManager.verificationState == .unknown)
        #expect(ageVerificationManager.needsAgeVerification == false)
        #expect(ageVerificationManager.currentAgeGroup == .unknown)
    }
    
    @Test("Verification state changes correctly during process")
    func testVerificationStateFlow() async {
        let ageVerificationManager = AgeVerificationManager()
        
        // Start verification
        await ageVerificationManager.startAgeVerification()
        #expect(ageVerificationManager.verificationState == .inProgress)
        
        // Complete verification
        let birthDate = Calendar.current.date(byAdding: .year, value: -20, to: Date())!
        let result = await ageVerificationManager.completeAgeVerification(birthDate: birthDate)
        
        #expect(result == true)
        #expect(ageVerificationManager.verificationState == .completed)
        #expect(ageVerificationManager.needsAgeVerification == false)
    }
    
    // MARK: - Edge Case Tests
    
    @Test("Handle edge cases for birth dates")
    func testBirthDateEdgeCases() async {
        let ageVerificationManager = AgeVerificationManager()
        
        // Test exactly 18 years old (birthday today)
        let exactlyEighteen = Calendar.current.date(byAdding: .year, value: -18, to: Date())!
        await ageVerificationManager.completeAgeVerification(birthDate: exactlyEighteen)
        
        #expect(ageVerificationManager.currentAgeGroup == .adult)
        #expect(ageVerificationManager.canAccessAdultContent() == true)
        
        // Test one day before 18th birthday
        let dayBeforeEighteen = Calendar.current.date(byAdding: .day, value: 1, to: exactlyEighteen)!
        let teenManager = AgeVerificationManager()
        await teenManager.completeAgeVerification(birthDate: dayBeforeEighteen)
        
        #expect(teenManager.currentAgeGroup == .teen)
        #expect(teenManager.canAccessAdultContent() == false)
    }
    
    @Test("Content visibility enum cases work correctly")
    func testContentVisibilityEnum() {
        #expect(ContentVisibility.show.rawValue == "show")
        #expect(ContentVisibility.warn.rawValue == "warn")
        #expect(ContentVisibility.hide.rawValue == "hide")
        
        #expect(ContentVisibility(rawValue: "show") == .show)
        #expect(ContentVisibility(rawValue: "warn") == .warn)
        #expect(ContentVisibility(rawValue: "hide") == .hide)
        #expect(ContentVisibility(rawValue: "invalid") == nil)
    }
    
    // MARK: - Age Calculation Tests
    
    @Test("Current age calculation works correctly")
    func testCurrentAgeCalculation() async {
        let ageVerificationManager = AgeVerificationManager()
        
        // Create a birth date for someone who should be exactly 20 years old
        let twentyYearsAgo = Calendar.current.date(byAdding: .year, value: -20, to: Date())!
        await ageVerificationManager.completeAgeVerification(birthDate: twentyYearsAgo)
        
        let currentAge = await ageVerificationManager.getCurrentAge()
        #expect(currentAge == 20)
    }
    
    // MARK: - Integration with Content Categories Tests
    
    @Test("All content categories have appropriate age restrictions")
    func testContentCategoryAgeRestrictions() {
        let categories = ContentCategory.allCategories
        #expect(categories.count == 4) // adult, suggestive, violent, nudity
        
        // Verify all categories have proper keys
        let expectedKeys = ["nsfw", "suggestive", "graphic", "nudity"]
        let actualKeys = categories.map { $0.visibilityKey }
        
        for expectedKey in expectedKeys {
            #expect(actualKeys.contains(expectedKey))
        }
    }
}

// MARK: - Mock Preferences Manager for Testing

class MockPreferencesManager: PreferencesManager {
    private var mockBirthDate: Date?
    private var shouldFailOperations = false
    
    func setMockBirthDate(_ date: Date?) {
        mockBirthDate = date
    }
    
    func setShouldFailOperations(_ shouldFail: Bool) {
        shouldFailOperations = shouldFail
    }
    
    override func getPreferences() async throws -> Preferences {
        if shouldFailOperations {
            throw NSError(domain: "MockError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock error"])
        }
        
        return Preferences(birthDate: mockBirthDate)
    }
    
    override func setBirthDate(_ date: Date?) async throws {
        if shouldFailOperations {
            throw NSError(domain: "MockError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock error"])
        }
        
        mockBirthDate = date
    }
}

// MARK: - Additional Integration Tests

@MainActor
struct AgeVerificationIntegrationTests {
    
    @Test("Age verification manager integrates with mock preferences")
    func testAgeVerificationWithMockPreferences() async {
        let mockPreferencesManager = MockPreferencesManager()
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        // Initially no birth date
        await ageVerificationManager.checkAgeVerificationStatus()
        #expect(ageVerificationManager.needsAgeVerification == true)
        #expect(ageVerificationManager.verificationState == .required)
        
        // Set birth date for adult
        let adultBirthDate = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
        mockPreferencesManager.setMockBirthDate(adultBirthDate)
        
        await ageVerificationManager.checkAgeVerificationStatus()
        #expect(ageVerificationManager.needsAgeVerification == false)
        #expect(ageVerificationManager.verificationState == .completed)
        #expect(ageVerificationManager.currentAgeGroup == .adult)
    }
    
    @Test("Error handling works correctly")
    func testErrorHandling() async {
        let mockPreferencesManager = MockPreferencesManager()
        mockPreferencesManager.setShouldFailOperations(true)
        
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        await ageVerificationManager.checkAgeVerificationStatus()
        
        #expect(ageVerificationManager.verificationState == .failed("Mock error"))
        #expect(ageVerificationManager.needsAgeVerification == true)
        #expect(ageVerificationManager.contentPolicy.adultContentAllowed == false) // Safe default
    }
}

// MARK: - Migration Scenario Tests

@MainActor
struct AgeVerificationMigrationTests {
    
    @Test("Existing user without birth date is prompted for verification")
    func testExistingUserMigrationFlow() async {
        let mockPreferencesManager = MockPreferencesManager()
        
        // Simulate existing user with no birth date set
        mockPreferencesManager.setMockBirthDate(nil)
        
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        await ageVerificationManager.checkAgeVerificationStatus()
        
        // Should require verification for existing users without birth date
        #expect(ageVerificationManager.needsAgeVerification == true)
        #expect(ageVerificationManager.verificationState == .required)
        #expect(ageVerificationManager.currentAgeGroup == .unknown)
        #expect(ageVerificationManager.contentPolicy.adultContentAllowed == false) // Safe default
    }
    
    @Test("Existing user with birth date continues normally")
    func testExistingUserWithBirthDate() async {
        let mockPreferencesManager = MockPreferencesManager()
        
        // Simulate existing user with birth date already set (adult)
        let adultBirthDate = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
        mockPreferencesManager.setMockBirthDate(adultBirthDate)
        
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        await ageVerificationManager.checkAgeVerificationStatus()
        
        // Should not require verification for existing users with birth date
        #expect(ageVerificationManager.needsAgeVerification == false)
        #expect(ageVerificationManager.verificationState == .completed)
        #expect(ageVerificationManager.currentAgeGroup == .adult)
        #expect(ageVerificationManager.contentPolicy.adultContentAllowed == true)
    }
    
    @Test("Migration preserves user's existing content preferences where appropriate")
    func testMigrationPreservesUserPreferences() async {
        // Simulate existing adult user with custom content preferences
        let mockPreferencesManager = MockPreferencesManager()
        let adultBirthDate = Calendar.current.date(byAdding: .year, value: -25, to: Date())!
        mockPreferencesManager.setMockBirthDate(adultBirthDate)
        
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        // Simulate user who had custom preferences before age verification
        let existingUserPreferences = [
            ContentLabelPreference(labelerDid: nil, label: "nsfw", visibility: "warn"),
            ContentLabelPreference(labelerDid: nil, label: "suggestive", visibility: "show")
        ]
        
        await ageVerificationManager.checkAgeVerificationStatus()
        
        // Adult users should retain their preferences
        #expect(ageVerificationManager.currentAgeGroup == .adult)
        #expect(ageVerificationManager.canAccessAdultContent() == true)
        
        // Their existing preferences should be respected
        let effectiveNsfwVisibility = ContentFilterManager.getAgeAppropriateVisibility(
            label: "nsfw",
            preferences: existingUserPreferences,
            ageVerificationManager: ageVerificationManager
        )
        
        #expect(effectiveNsfwVisibility == .warn) // Respects user's choice
    }
    
    @Test("Migration applies age restrictions for minor accounts retroactively")
    func testMigrationAppliesMinorRestrictions() async {
        // Simulate existing teen user with permissive preferences (that shouldn't have been allowed)
        let mockPreferencesManager = MockPreferencesManager()
        let teenBirthDate = Calendar.current.date(byAdding: .year, value: -16, to: Date())!
        mockPreferencesManager.setMockBirthDate(teenBirthDate)
        
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        // Simulate dangerous preferences that might have existed before age verification
        let dangerousPreferences = [
            ContentLabelPreference(labelerDid: nil, label: "nsfw", visibility: "show") // Should be overridden
        ]
        
        await ageVerificationManager.checkAgeVerificationStatus()
        
        // Teen should be identified correctly
        #expect(ageVerificationManager.currentAgeGroup == .teen)
        #expect(ageVerificationManager.canAccessAdultContent() == false)
        
        // Age restrictions should override previous unsafe preferences
        let effectiveVisibility = ContentFilterManager.getAgeAppropriateVisibility(
            label: "nsfw",
            preferences: dangerousPreferences,
            ageVerificationManager: ageVerificationManager
        )
        
        #expect(effectiveVisibility == .hide) // Override for safety
    }
    
    @Test("Migration handles corrupt or invalid birth date data")
    func testMigrationHandlesCorruptData() async {
        let mockPreferencesManager = MockPreferencesManager()
        
        // Simulate corrupted birth date (far in the future)
        let corruptBirthDate = Calendar.current.date(byAdding: .year, value: 10, to: Date())!
        mockPreferencesManager.setMockBirthDate(corruptBirthDate)
        
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        await ageVerificationManager.checkAgeVerificationStatus()
        
        // Should treat corrupt data as requiring fresh verification
        #expect(ageVerificationManager.needsAgeVerification == true)
        #expect(ageVerificationManager.verificationState == .required)
        #expect(ageVerificationManager.contentPolicy.adultContentAllowed == false) // Safe default
    }
    
    @Test("App startup flow integrates age verification check correctly")
    func testAppStartupIntegration() async {
        let mockPreferencesManager = MockPreferencesManager()
        let ageVerificationManager = AgeVerificationManager(preferencesManager: mockPreferencesManager)
        
        // Simulate app startup with no birth date
        mockPreferencesManager.setMockBirthDate(nil)
        
        await ageVerificationManager.checkAgeVerificationStatus()
        
        // Should be in required state after startup check
        #expect(ageVerificationManager.verificationState == .required)
        #expect(ageVerificationManager.needsAgeVerification == true)
        
        // Complete verification during app use
        let adultBirthDate = Calendar.current.date(byAdding: .year, value: -20, to: Date())!
        let success = await ageVerificationManager.completeAgeVerification(birthDate: adultBirthDate)
        
        #expect(success == true)
        #expect(ageVerificationManager.verificationState == .completed)
        #expect(ageVerificationManager.needsAgeVerification == false)
        
        // Subsequent app startups should not require verification
        await ageVerificationManager.checkAgeVerificationStatus()
        #expect(ageVerificationManager.verificationState == .completed)
        #expect(ageVerificationManager.needsAgeVerification == false)
    }
}