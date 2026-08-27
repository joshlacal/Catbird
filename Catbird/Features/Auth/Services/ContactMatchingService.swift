import Contacts
import Foundation
import OSLog
import Observation
import Petrel

/// Represents a contact read from the user's on-device address book
public struct LocalContact: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let phoneNumbers: [String]
    
    public init(id: String, displayName: String, phoneNumbers: [String]) {
        self.id = id
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
    }
}

/// Prepared contact payload ready for secure matching
public struct PreparedContacts: Sendable {
    /// Deduplicated E.164 phone numbers (max 1000), excluding verified self number
    public let normalizedPhoneNumbers: [String]
    /// Mapping of normalized phone number to the originating LocalContact
    public let phoneToContactMap: [String: LocalContact]
    /// Mapping of upload index (0..<N) to the originating LocalContact
    public let indexToContactMap: [Int: LocalContact]
    /// Unmatched local contacts
    public let unmatchedContacts: [LocalContact]
    
    public init(
        normalizedPhoneNumbers: [String],
        phoneToContactMap: [String: LocalContact],
        indexToContactMap: [Int: LocalContact],
        unmatchedContacts: [LocalContact]
    ) {
        self.normalizedPhoneNumbers = normalizedPhoneNumbers
        self.phoneToContactMap = phoneToContactMap
        self.indexToContactMap = indexToContactMap
        self.unmatchedContacts = unmatchedContacts
    }
}

/// A matched Bluesky profile correlated with an on-device contact
public struct ContactMatch: Identifiable, Sendable {
    public var id: String { profile.did.description }
    public let profile: AppBskyActorDefs.ProfileView
    public let localContact: LocalContact?
    public let contactIndex: Int
    public var isFollowing: Bool
    public var isDismissed: Bool
    
    public init(
        profile: AppBskyActorDefs.ProfileView,
        localContact: LocalContact?,
        contactIndex: Int,
        isFollowing: Bool = false,
        isDismissed: Bool = false
    ) {
        self.profile = profile
        self.localContact = localContact
        self.contactIndex = contactIndex
        self.isFollowing = isFollowing
        self.isDismissed = isDismissed
    }
}

/// Contact matching errors
public enum ContactMatchingError: LocalizedError, Sendable {
    case permissionDenied
    case permissionRestricted
    case noValidPhoneNumbers
    case tooManyContacts
    case invalidToken
    case verificationFailed(String)
    case importFailed(String)
    case serviceUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Contacts access was denied. Please grant access in iOS Settings to find your friends."
        case .permissionRestricted:
            return "Contacts access is restricted on this device."
        case .noValidPhoneNumbers:
            return "No valid phone numbers were found in your contacts."
        case .tooManyContacts:
            return "Too many contacts to import (maximum 1,000)."
        case .invalidToken:
            return "Your phone verification session expired. Please verify your number again."
        case .verificationFailed(let message):
            return "Phone verification failed: \(message)"
        case .importFailed(let message):
            return "Contact import failed: \(message)"
        case .serviceUnavailable:
            return "The contact discovery service is temporarily unavailable."
        }
    }
}

/// Service managing device contacts access, E.164 normalization, and secure matching via app.bsky.contact
@Observable
public final class ContactMatchingService: @unchecked Sendable {
    private let logger = Logger(subsystem: "blue.catbird", category: "ContactMatchingService")
    private let contactStore = CNContactStore()
    
    // In-memory verification state (never written to disk or logs)
    public var verifiedPhoneNumber: String?
    public var verificationToken: String?
    
    // Common country calling codes
    public static let countryCallingCodes: [String: String] = [
        "US": "1", "CA": "1", "GB": "44", "UK": "44", "AU": "61", "NZ": "64",
        "DE": "49", "FR": "33", "IT": "39", "ES": "34", "NL": "31", "BE": "32",
        "CH": "41", "AT": "43", "SE": "46", "NO": "47", "DK": "45", "FI": "358",
        "IE": "353", "PT": "351", "GR": "30", "PL": "48", "CZ": "420", "HU": "36",
        "RO": "40", "BG": "359", "HR": "385", "SI": "386", "SK": "421", "EE": "372",
        "LV": "371", "LT": "370", "JP": "81", "KR": "82", "CN": "86", "TW": "886",
        "HK": "852", "SG": "65", "MY": "60", "TH": "66", "VN": "84", "PH": "63",
        "ID": "62", "IN": "91", "PK": "92", "BD": "880", "BR": "55", "MX": "52",
        "AR": "54", "CO": "57", "CL": "56", "PE": "51", "ZA": "27", "NG": "234",
        "EG": "20", "KE": "254", "IL": "972", "SA": "966", "AE": "971", "TR": "90",
        "UA": "380", "RU": "7", "KZ": "7"
    ]
    
    public init() {}
    
    // MARK: - Permission
    
    /// Current Contacts authorization status
    public var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }
    
    /// Request Contacts access
    public func requestContactsAccess() async throws -> Bool {
        let status = authorizationStatus
        switch status {
        case .authorized:
            return true
        #if !os(macOS)
        case .limited:
            return true
        #endif
        case .denied:
            throw ContactMatchingError.permissionDenied
        case .restricted:
            throw ContactMatchingError.permissionRestricted
        case .notDetermined:
            let granted = try await contactStore.requestAccess(for: .contacts)
            if !granted {
                throw ContactMatchingError.permissionDenied
            }
            return granted
        @unknown default:
            throw ContactMatchingError.permissionDenied
        }
    }
    
    // MARK: - E.164 Normalization
    
    /// Normalizes a phone number to standard E.164 format (+[country][national_number])
    public static func normalizePhoneNumber(_ raw: String, defaultCountryCallingCode: String = "1") -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if trimmed.hasPrefix("+") {
            let digitsOnly = trimmed.dropFirst().filter { $0.isNumber }
            guard digitsOnly.count >= 7 && digitsOnly.count <= 15 else { return nil }
            return "+\(digitsOnly)"
        } else if trimmed.hasPrefix("00") {
            let digitsOnly = trimmed.dropFirst(2).filter { $0.isNumber }
            guard digitsOnly.count >= 7 && digitsOnly.count <= 15 else { return nil }
            return "+\(digitsOnly)"
        } else {
            var digitsOnly = String(trimmed.filter { $0.isNumber })
            guard !digitsOnly.isEmpty else { return nil }
            
            // Handle domestic trunk prefix '0' (e.g. UK 07xxx -> +447xxx)
            if defaultCountryCallingCode != "1" && digitsOnly.hasPrefix("0") {
                digitsOnly = String(digitsOnly.dropFirst())
            }
            
            // If country code is 1 and number is 11 digits starting with 1
            if defaultCountryCallingCode == "1" && digitsOnly.count == 11 && digitsOnly.hasPrefix("1") {
                return "+\(digitsOnly)"
            }
            
            let formatted = "+\(defaultCountryCallingCode)\(digitsOnly)"
            let digitsCount = formatted.dropFirst().count
            guard digitsCount >= 7 && digitsCount <= 15 else { return nil }
            return formatted
        }
    }
    
    /// Determine default country calling code from device locale
    public static func defaultCallingCode() -> String {
        let regionCode = Locale.current.region?.identifier ?? "US"
        return countryCallingCodes[regionCode.uppercased()] ?? "1"
    }
    
    // MARK: - Contact Reading & Preparation
    
    /// Reads on-device contacts and prepares normalized payload capped at 1,000 numbers
    public func fetchAndPrepareContacts(excludingSelfPhone: String? = nil) throws -> PreparedContacts {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var contacts: [LocalContact] = []
        
        try contactStore.enumerateContacts(with: request) { cnContact, _ in
            let givenName = cnContact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            let familyName = cnContact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = displayName.isEmpty ? "Contact" : displayName
            
            let phoneNumbers = cnContact.phoneNumbers.map { $0.value.stringValue }
            if !phoneNumbers.isEmpty {
                contacts.append(LocalContact(id: cnContact.identifier, displayName: name, phoneNumbers: phoneNumbers))
            }
        }
        
        return Self.prepareContacts(contacts: contacts, excludingSelfPhone: excludingSelfPhone, defaultCountryCode: Self.defaultCallingCode())
    }
    
    /// Pure functional contact preparation with normalization, deduplication, self-exclusion, and 1,000 cap
    public static func prepareContacts(
        contacts: [LocalContact],
        excludingSelfPhone: String? = nil,
        defaultCountryCode: String = "1"
    ) -> PreparedContacts {
        let normalizedSelf = excludingSelfPhone.flatMap { normalizePhoneNumber($0, defaultCountryCallingCode: defaultCountryCode) }
        
        var normalizedPhoneNumbers: [String] = []
        var phoneToContactMap: [String: LocalContact] = [:]
        var indexToContactMap: [Int: LocalContact] = [:]
        var seenPhones = Set<String>()
        var matchedLocalContactIds = Set<String>()
        
        for contact in contacts {
            var hasValidNumberForContact = false
            for rawPhone in contact.phoneNumbers {
                guard let normalized = normalizePhoneNumber(rawPhone, defaultCountryCallingCode: defaultCountryCode) else {
                    continue
                }
                
                // Exclude verified self phone
                if let normalizedSelf, normalized == normalizedSelf {
                    continue
                }
                
                if !seenPhones.contains(normalized) {
                    // Check 1000 limit
                    if normalizedPhoneNumbers.count < 1000 {
                        let currentIndex = normalizedPhoneNumbers.count
                        seenPhones.insert(normalized)
                        normalizedPhoneNumbers.append(normalized)
                        phoneToContactMap[normalized] = contact
                        indexToContactMap[currentIndex] = contact
                        hasValidNumberForContact = true
                    }
                } else {
                    hasValidNumberForContact = true
                }
            }
            if hasValidNumberForContact {
                matchedLocalContactIds.insert(contact.id)
            }
        }
        
        let unmatched = contacts.filter { !matchedLocalContactIds.contains($0.id) }
        
        return PreparedContacts(
            normalizedPhoneNumbers: normalizedPhoneNumbers,
            phoneToContactMap: phoneToContactMap,
            indexToContactMap: indexToContactMap,
            unmatchedContacts: unmatched
        )
    }
    
    // MARK: - Phone Verification & Matching RPCs
    
    /// Start phone verification by sending SMS code via app.bsky.contact.startPhoneVerification
    public func startPhoneVerification(phone: String, client: ATProtoClient) async throws {
        guard let normalized = Self.normalizePhoneNumber(phone, defaultCountryCallingCode: Self.defaultCallingCode()) else {
            throw ContactMatchingError.verificationFailed("Please enter a valid phone number.")
        }
        
        let input = AppBskyContactStartPhoneVerification.Input(phone: normalized)
        let (code, _) = try await client.app.bsky.contact.startPhoneVerification(input: input)
        
        guard code == 200 else {
            throw ContactMatchingError.verificationFailed("Server returned HTTP \(code)")
        }
        
        self.verifiedPhoneNumber = normalized
        logger.info("Phone verification started successfully")
    }
    
    /// Verify phone with SMS code and obtain short-lived verification token
    public func verifyPhone(phone: String, code: String, client: ATProtoClient) async throws -> String {
        guard let normalized = Self.normalizePhoneNumber(phone, defaultCountryCallingCode: Self.defaultCallingCode()) else {
            throw ContactMatchingError.verificationFailed("Invalid phone number format.")
        }
        
        let input = AppBskyContactVerifyPhone.Input(phone: normalized, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        let (responseCode, output) = try await client.app.bsky.contact.verifyPhone(input: input)
        
        guard responseCode == 200, let token = output?.token else {
            throw ContactMatchingError.verificationFailed("Verification code is incorrect or expired.")
        }
        
        self.verificationToken = token
        self.verifiedPhoneNumber = normalized
        logger.info("Phone verified successfully")
        return token
    }
    
    /// Import contacts and correlate returned matches back to local contacts
    public func importContacts(
        token: String,
        prepared: PreparedContacts,
        client: ATProtoClient
    ) async throws -> [ContactMatch] {
        guard !prepared.normalizedPhoneNumbers.isEmpty else {
            throw ContactMatchingError.noValidPhoneNumbers
        }
        guard prepared.normalizedPhoneNumbers.count <= 1000 else {
            throw ContactMatchingError.tooManyContacts
        }
        
        let input = AppBskyContactImportContacts.Input(
            token: token,
            contacts: prepared.normalizedPhoneNumbers
        )
        
        let (code, output) = try await client.app.bsky.contact.importContacts(input: input)
        
        guard code == 200, let output else {
            if code == 400 {
                throw ContactMatchingError.invalidToken
            }
            throw ContactMatchingError.importFailed("Server returned HTTP \(code)")
        }
        
        var matches: [ContactMatch] = []
        for item in output.matchesAndContactIndexes {
            let localContact = prepared.indexToContactMap[item.contactIndex]
            let isFollowing = item.match.viewer?.following != nil
            matches.append(ContactMatch(
                profile: item.match,
                localContact: localContact,
                contactIndex: item.contactIndex,
                isFollowing: isFollowing
            ))
        }
        
        logger.info("Successfully imported contacts, found \(matches.count) matches")
        return matches
    }
    
    /// Dismiss a matched contact so it won't appear again
    public func dismissMatch(did: DID, client: ATProtoClient) async throws {
        let input = AppBskyContactDismissMatch.Input(subject: did)
        let (code, _) = try await client.app.bsky.contact.dismissMatch(input: input)
        guard code == 200 else {
            throw ContactMatchingError.serviceUnavailable
        }
        logger.info("Dismissed contact match for \(did.description)")
    }
    
    /// Query sync status
    public func getSyncStatus(client: ATProtoClient) async throws -> AppBskyContactDefs.SyncStatus? {
        let (code, output) = try await client.app.bsky.contact.getSyncStatus(input: AppBskyContactGetSyncStatus.Parameters())
        guard code == 200 else { return nil }
        return output?.syncStatus
    }
    
    /// Remove imported contact data from the server
    public func removeData(client: ATProtoClient) async throws {
        let (code, _) = try await client.app.bsky.contact.removeData(input: AppBskyContactRemoveData.Input())
        guard code == 200 else {
            throw ContactMatchingError.serviceUnavailable
        }
        self.verificationToken = nil
        self.verifiedPhoneNumber = nil
        logger.info("Successfully removed imported contact data from server")
    }
}
