import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct ContactMatchingTests {
    
    // MARK: - G64: Normalization, Correlation, Self-Exclusion & 1000 Cap
    
    @Test("Normalizes domestic and international phones, deduplicates, excludes self, and caps at 1000")
    func normalizesCorrelatesExcludesOwnAndCapsAt1000() async {
        // 1. Phone number normalization checks
        // US domestic formats
        #expect(ContactMatchingService.normalizePhoneNumber("(555) 234-5678", defaultCountryCallingCode: "1") == "+15552345678")
        #expect(ContactMatchingService.normalizePhoneNumber("555-234-5678", defaultCountryCallingCode: "1") == "+15552345678")
        #expect(ContactMatchingService.normalizePhoneNumber("1-555-234-5678", defaultCountryCallingCode: "1") == "+15552345678")
        #expect(ContactMatchingService.normalizePhoneNumber("5552345678", defaultCountryCallingCode: "1") == "+15552345678")
        
        // International formats with leading +
        #expect(ContactMatchingService.normalizePhoneNumber("+44 7911 123456", defaultCountryCallingCode: "1") == "+447911123456")
        #expect(ContactMatchingService.normalizePhoneNumber("+33 1 42 68 55 55", defaultCountryCallingCode: "1") == "+33142685555")
        #expect(ContactMatchingService.normalizePhoneNumber("+81 3 1234 5678", defaultCountryCallingCode: "1") == "+81312345678")
        
        // International formats with leading 00 exit code
        #expect(ContactMatchingService.normalizePhoneNumber("0015552345678", defaultCountryCallingCode: "1") == "+15552345678")
        #expect(ContactMatchingService.normalizePhoneNumber("00447911123456", defaultCountryCallingCode: "1") == "+447911123456")
        
        // Domestic format with trunk 0 (e.g., UK 07911...)
        #expect(ContactMatchingService.normalizePhoneNumber("07911 123456", defaultCountryCallingCode: "44") == "+447911123456")
        
        // Invalid input
        #expect(ContactMatchingService.normalizePhoneNumber("", defaultCountryCallingCode: "1") == nil)
        #expect(ContactMatchingService.normalizePhoneNumber("   ", defaultCountryCallingCode: "1") == nil)
        #expect(ContactMatchingService.normalizePhoneNumber("abc", defaultCountryCallingCode: "1") == nil)
        #expect(ContactMatchingService.normalizePhoneNumber("123", defaultCountryCallingCode: "1") == nil) // too short (< 7 digits)
        #expect(ContactMatchingService.normalizePhoneNumber("+123456789012345678", defaultCountryCallingCode: "1") == nil) // too long (> 15 digits)
        
        // 2. Prepare contacts with duplicates, multiple numbers, and self-exclusion
        let verifiedSelfPhone = "+15550000000"
        
        let contact1 = LocalContact(
            id: "c1",
            displayName: "Alice Smith",
            phoneNumbers: ["(555) 234-5678", "555-234-5678", "+1 555 999 1111"] // includes duplicate internal
        )
        let contact2 = LocalContact(
            id: "c2",
            displayName: "Bob Jones",
            phoneNumbers: ["(555) 234-5678", "+44 7911 123456"] // shares duplicate number with Alice
        )
        let contactSelf = LocalContact(
            id: "c_self",
            displayName: "Myself",
            phoneNumbers: ["555-000-0000", "+1 (555) 000-0000"] // self verified number
        )
        let contactInvalid = LocalContact(
            id: "c_invalid",
            displayName: "No Phone Contact",
            phoneNumbers: ["123", "invalid"]
        )
        
        let prepared = ContactMatchingService.prepareContacts(
            contacts: [contact1, contact2, contactSelf, contactInvalid],
            excludingSelfPhone: verifiedSelfPhone,
            defaultCountryCode: "1"
        )
        
        // Verified self numbers must be excluded
        #expect(!prepared.normalizedPhoneNumbers.contains(verifiedSelfPhone))
        #expect(prepared.phoneToContactMap[verifiedSelfPhone] == nil)
        
        // Alice and Bob share +15552345678; it should only appear once in normalizedPhoneNumbers
        let occurrences = prepared.normalizedPhoneNumbers.filter { $0 == "+15552345678" }.count
        #expect(occurrences == 1)
        
        // Alice has second number +15559991111
        #expect(prepared.normalizedPhoneNumbers.contains("+15559991111"))
        #expect(prepared.phoneToContactMap["+15559991111"]?.id == "c1")
        
        // Bob has second number +447911123456
        #expect(prepared.normalizedPhoneNumbers.contains("+447911123456"))
        #expect(prepared.phoneToContactMap["+447911123456"]?.id == "c2")
        
        // Contact with only invalid numbers must be in unmatched
        #expect(prepared.unmatchedContacts.contains(where: { $0.id == "c_invalid" }))
        
        // 3. Test 1,001-number boundary cap
        var massiveContactList: [LocalContact] = []
        for i in 1...1005 {
            // Generate valid 10-digit numbers: 555-100-0000 to 555-100-1004
            let number = String(format: "555100%04d", i)
            massiveContactList.append(LocalContact(
                id: "bulk_\(i)",
                displayName: "User \(i)",
                phoneNumbers: [number]
            ))
        }
        
        let massivePrepared = ContactMatchingService.prepareContacts(
            contacts: massiveContactList,
            excludingSelfPhone: nil,
            defaultCountryCode: "1"
        )
        
        #expect(massivePrepared.normalizedPhoneNumbers.count == 1000)
        #expect(massivePrepared.indexToContactMap.count == 1000)
        #expect(massivePrepared.indexToContactMap[0] != nil)
        #expect(massivePrepared.indexToContactMap[999] != nil)
        #expect(massivePrepared.indexToContactMap[1000] == nil)
    }
    
    // MARK: - G64: Index Mapping Without Uploading Names
    
    @Test("Maps match indexes back to local contact names without uploading names")
    func mapsMatchIndexesWithoutUploadingNames() async throws {
        let contactA = LocalContact(id: "id_alice", displayName: "Alice Wonder", phoneNumbers: ["555-111-2222"])
        let contactB = LocalContact(id: "id_bob", displayName: "Bob Builder", phoneNumbers: ["555-333-4444"])
        let contactC = LocalContact(id: "id_charlie", displayName: "Charlie Brown", phoneNumbers: ["555-555-6666"])
        
        let prepared = ContactMatchingService.prepareContacts(
            contacts: [contactA, contactB, contactC],
            defaultCountryCode: "1"
        )
        
        #expect(prepared.normalizedPhoneNumbers.count == 3)
        #expect(prepared.normalizedPhoneNumbers[0] == "+15551112222")
        #expect(prepared.normalizedPhoneNumbers[1] == "+15553334444")
        #expect(prepared.normalizedPhoneNumbers[2] == "+15555556666")
        
        // Verify encoded input contains ONLY phone strings
        let input = AppBskyContactImportContacts.Input(
            token: "test_verification_token_123",
            contacts: prepared.normalizedPhoneNumbers
        )
        
        #expect(input.contacts.count == 3)
        #expect(input.contacts == ["+15551112222", "+15553334444", "+15555556666"])
        #expect(input.token == "test_verification_token_123")
        
        // Simulate returned service response mapping indexes (e.g., match for index 0 and 2)
        let didAlice = try DID(didString: "did:plc:alice0000000000000000001")
        let didCharlie = try DID(didString: "did:plc:charlie0000000000000002")
        
        let handleAlice = try Handle(handleString: "alice.bsky.social")
        let handleCharlie = try Handle(handleString: "charlie.bsky.social")
        
        let profileAlice = AppBskyActorDefs.ProfileView(
            did: didAlice,
            handle: handleAlice,
            displayName: "Alice on Bluesky",
            pronouns: nil,
            description: nil,
            avatar: nil,
            associated: nil,
            indexedAt: nil,
            createdAt: nil,
            viewer: nil,
            labels: nil,
            verification: nil,
            status: nil,
            debug: nil
        )
        let profileCharlie = AppBskyActorDefs.ProfileView(
            did: didCharlie,
            handle: handleCharlie,
            displayName: "Charlie on Bluesky",
            pronouns: nil,
            description: nil,
            avatar: nil,
            associated: nil,
            indexedAt: nil,
            createdAt: nil,
            viewer: nil,
            labels: nil,
            verification: nil,
            status: nil,
            debug: nil
        )
        
        let match1 = AppBskyContactDefs.MatchAndContactIndex(match: profileAlice, contactIndex: 0)
        let match2 = AppBskyContactDefs.MatchAndContactIndex(match: profileCharlie, contactIndex: 2)
        
        // Correlate
        var correlatedMatches: [ContactMatch] = []
        for item in [match1, match2] {
            let localContact = prepared.indexToContactMap[item.contactIndex]
            correlatedMatches.append(ContactMatch(
                profile: item.match,
                localContact: localContact,
                contactIndex: item.contactIndex
            ))
        }
        
        #expect(correlatedMatches.count == 2)
        #expect(correlatedMatches[0].localContact?.displayName == "Alice Wonder")
        #expect(correlatedMatches[0].profile.handle.description == "alice.bsky.social")
        #expect(correlatedMatches[1].localContact?.displayName == "Charlie Brown")
        #expect(correlatedMatches[1].profile.handle.description == "charlie.bsky.social")
    }
    
    // MARK: - Error Descriptions
    
    @Test("Contact matching errors localized descriptions")
    func errorDescriptions() {
        #expect(ContactMatchingError.permissionDenied.errorDescription?.contains("denied") == true)
        #expect(ContactMatchingError.noValidPhoneNumbers.errorDescription?.contains("No valid phone numbers") == true)
        #expect(ContactMatchingError.tooManyContacts.errorDescription?.contains("1,000") == true)
        #expect(ContactMatchingError.invalidToken.errorDescription?.contains("expired") == true)
    }
}
