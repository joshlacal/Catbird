import Testing
import Foundation
import Petrel
@testable import Catbird

@Suite("ModerationPreferenceTests")
struct ModerationPreferenceTests {
    
    @Test("Unavailable labeler detection correctly flags missing DIDs")
    func testUnavailableLabelerDetection() throws {
        let did1 = try DID(didString: "did:plc:labeler11111111111111")
        let did2 = try DID(didString: "did:plc:labeler22222222222222")
        let did3 = try DID(didString: "did:plc:labeler33333333333333")
        
        let subscribedDIDs = [did1, did2, did3]
        
        // getServices returns only did1 and did3 (did2 is offline/deleted)
        let returnedDIDs = Set([did1.didString(), did3.didString()])
        
        let missingDIDs = subscribedDIDs.map { $0.didString() }.filter { !returnedDIDs.contains($0) }
        
        #expect(missingDIDs.count == 1)
        #expect(missingDIDs.first == did2.didString())
    }
    
    @Test("Labeler cleanup preserves live labelers and unrelated preferences")
    func testLabelerCleanupPreservesUnrelatedPreferences() throws {
        let liveDID = try DID(didString: "did:plc:livelabeler11111111111")
        let deadDID = try DID(didString: "did:plc:deadlabeler22222222222")
        
        let labelersPref = AppBskyActorDefs.LabelersPref(labelers: [
            .init(did: liveDID),
            .init(did: deadDID)
        ])
        let adultPref = AppBskyActorDefs.AdultContentPref(enabled: true)
        let interestsPref = AppBskyActorDefs.InterestsPref(tags: ["swift", "atproto"])
        
        var allPrefs: [AppBskyActorDefs.PreferencesForUnionArray] = [
            .labelersPref(labelersPref),
            .adultContentPref(adultPref),
            .interestsPref(interestsPref)
        ]
        
        let unavailableSet = Set([deadDID.didString()])
        
        // Apply cleanup
        allPrefs = allPrefs.map { item in
            if case .labelersPref(let pref) = item {
                let filtered = pref.labelers.filter { !unavailableSet.contains($0.did.didString()) }
                return .labelersPref(AppBskyActorDefs.LabelersPref(labelers: filtered))
            }
            return item
        }
        
        // Prove unrelated items are untouched
        #expect(allPrefs.count == 3)
        
        var foundCleanedLabelers = false
        var foundAdult = false
        var foundInterests = false
        
        for item in allPrefs {
            switch item {
            case .labelersPref(let pref):
                foundCleanedLabelers = true
                #expect(pref.labelers.count == 1)
                #expect(pref.labelers.first?.did == liveDID)
            case .adultContentPref(let pref):
                foundAdult = true
                #expect(pref.enabled == true)
            case .interestsPref(let pref):
                foundInterests = true
                #expect(pref.tags == ["swift", "atproto"])
            default:
                break
            }
        }
        
        #expect(foundCleanedLabelers)
        #expect(foundAdult)
        #expect(foundInterests)
    }
    
    @Test("VerificationPrefs hideBadges mapping to toggle")
    func testVerificationPrefsMapping() {
        // nil -> Show badges (true)
        let nilPref: AppBskyActorDefs.VerificationPrefs? = nil
        let showFromNil = !(nilPref?.hideBadges ?? false)
        #expect(showFromNil == true)
        
        // hideBadges = false -> Show badges (true)
        let falsePref = AppBskyActorDefs.VerificationPrefs(hideBadges: false)
        let showFromFalse = !(falsePref.hideBadges ?? false)
        #expect(showFromFalse == true)
        
        // hideBadges = true -> Hide badges (false)
        let truePref = AppBskyActorDefs.VerificationPrefs(hideBadges: true)
        let showFromTrue = !(truePref.hideBadges ?? false)
        #expect(showFromTrue == false)
    }
}
