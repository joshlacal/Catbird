import Testing
import Foundation
import Petrel
@testable import Catbird

@Suite("PostInteractionSettingsTests")
struct PostInteractionSettingsTests {
    
    @Test("Everybody setting produces nil threadgate allow rules")
    func testEverybodyRules() {
        let pref = AppBskyActorDefs.PostInteractionSettingsPref(
            threadgateAllowRules: nil,
            postgateEmbeddingRules: nil
        )
        
        #expect(pref.threadgateAllowRules == nil)
        #expect(pref.postgateEmbeddingRules == nil)
    }
    
    @Test("Nobody setting produces empty threadgate allow rules array")
    func testNobodyRules() {
        let pref = AppBskyActorDefs.PostInteractionSettingsPref(
            threadgateAllowRules: [],
            postgateEmbeddingRules: nil
        )
        
        #expect(pref.threadgateAllowRules != nil)
        #expect(pref.threadgateAllowRules?.isEmpty == true)
    }
    
    @Test("Custom rules round-trip followers, following, mentions, and lists")
    func testCustomRulesRoundTrip() throws {
        let listUri = try ATProtocolURI(uriString: "at://did:plc:testuser12345/app.bsky.graph.list/3k6wuby6vls2u")
        
        let rules: [AppBskyActorDefs.PostInteractionSettingsPrefThreadgateAllowRulesUnion] = [
            .appBskyFeedThreadgateFollowingRule(.init()),
            .appBskyFeedThreadgateFollowerRule(.init()),
            .appBskyFeedThreadgateMentionRule(.init()),
            .appBskyFeedThreadgateListRule(.init(list: listUri))
        ]
        
        let pref = AppBskyActorDefs.PostInteractionSettingsPref(
            threadgateAllowRules: rules,
            postgateEmbeddingRules: nil
        )
        
        #expect(pref.threadgateAllowRules?.count == 4)
        
        var foundFollowing = false
        var foundFollower = false
        var foundMention = false
        var foundList = false
        
        for rule in pref.threadgateAllowRules ?? [] {
            switch rule {
            case .appBskyFeedThreadgateFollowingRule:
                foundFollowing = true
            case .appBskyFeedThreadgateFollowerRule:
                foundFollower = true
            case .appBskyFeedThreadgateMentionRule:
                foundMention = true
            case .appBskyFeedThreadgateListRule(let listRule):
                foundList = true
                #expect(listRule.list == listUri)
            case .unexpected:
                break
            }
        }
        
        #expect(foundFollowing)
        #expect(foundFollower)
        #expect(foundMention)
        #expect(foundList)
    }
    
    @Test("Quotes disabled maps to postgate disableRule")
    func testQuotesDisabled() {
        let embeddingRules: [AppBskyActorDefs.PostInteractionSettingsPrefPostgateEmbeddingRulesUnion] = [
            .appBskyFeedPostgateDisableRule(.init())
        ]
        
        let pref = AppBskyActorDefs.PostInteractionSettingsPref(
            threadgateAllowRules: nil,
            postgateEmbeddingRules: embeddingRules
        )
        
        #expect(pref.postgateEmbeddingRules?.count == 1)
        if case .appBskyFeedPostgateDisableRule = pref.postgateEmbeddingRules?.first {
            // Passed
        } else {
            Issue.record("Expected appBskyFeedPostgateDisableRule")
        }
    }
    
    @Test("Updating postInteractionSettingsPref preserves unrelated preferences")
    func testPostInteractionSettingsPreservesUnrelatedPreferences() {
        let adultPref = AppBskyActorDefs.AdultContentPref(enabled: true)
        let interestsPref = AppBskyActorDefs.InterestsPref(tags: ["apple", "swift"])
        let oldInteraction = AppBskyActorDefs.PostInteractionSettingsPref(threadgateAllowRules: nil, postgateEmbeddingRules: nil)
        
        var allPrefs: [AppBskyActorDefs.PreferencesForUnionArray] = [
            .adultContentPref(adultPref),
            .postInteractionSettingsPref(oldInteraction),
            .interestsPref(interestsPref)
        ]
        
        // New interaction preference (nobody)
        let newInteraction = AppBskyActorDefs.PostInteractionSettingsPref(threadgateAllowRules: [], postgateEmbeddingRules: nil)
        
        allPrefs.removeAll { item in
            if case .postInteractionSettingsPref = item { return true }
            return false
        }
        allPrefs.append(.postInteractionSettingsPref(newInteraction))
        
        #expect(allPrefs.count == 3)
        
        var foundAdult = false
        var foundInterests = false
        var foundNewInteraction = false
        
        for item in allPrefs {
            switch item {
            case .adultContentPref(let pref):
                foundAdult = true
                #expect(pref.enabled == true)
            case .interestsPref(let pref):
                foundInterests = true
                #expect(pref.tags == ["apple", "swift"])
            case .postInteractionSettingsPref(let pref):
                foundNewInteraction = true
                #expect(pref.threadgateAllowRules?.isEmpty == true)
            default:
                break
            }
        }
        
        #expect(foundAdult)
        #expect(foundInterests)
        #expect(foundNewInteraction)
    }
}
