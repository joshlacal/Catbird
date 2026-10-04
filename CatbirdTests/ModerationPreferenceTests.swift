import Testing
import Foundation
import Petrel
import SwiftData
@testable import Catbird

@Suite("ModerationPreferenceTests", .serialized)
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
    @Test("Global edits preserve scoped, custom, and newer remote preferences")
    @MainActor
    func globalEditPreservesUnrelatedKeys() async throws {
        let service = try DID(didString: "did:plc:safety-service")
        let fixture = SafetyPreferencesFixture(items: [
            .adultContentPref(.init(enabled: true)), .interestsPref(.init(tags: ["Art"])),
            .contentLabelPref(.init(label: "nsfw", visibility: "warn")),
            .contentLabelPref(.init(labelerDid: service, label: "nsfw", visibility: "ignore")),
            .contentLabelPref(.init(label: "custom-label", visibility: "hide"))
        ])
        let (manager, local) = try fixture.makeManager()
        try await manager.setContentLabelVisibility(label: "nsfw", visibility: "hide", expectedAccountDID: fixture.account)
        #expect(fixture.labels.count == 3)
        #expect(fixture.labels.first { $0.label == "nsfw" && $0.labelerDid == nil }?.visibility == "hide")
        #expect(fixture.labels.first { $0.labelerDid == service }?.visibility == "ignore")
        #expect(fixture.labels.first { $0.label == "custom-label" }?.visibility == "hide")
        #expect(local.contentLabelPrefs.count == 3)
        #expect(fixture.items.contains { if case .adultContentPref(let p) = $0 { return p.enabled }; return false })
        #expect(fixture.items.contains { if case .interestsPref(let p) = $0 { return p.tags == ["Art"] }; return false })
    }

    @Test("Scoped resolution never inherits another service", arguments: [false, true])
    func scopedResolver(reverse: Bool) throws {
        let serviceA = try DID(didString: "did:plc:safety-a")
        let serviceB = try DID(didString: "did:plc:safety-b")
        var preferences = [ContentLabelPreference(labelerDid: serviceB, label: "custom", visibility: "ignore")]
        #expect(ContentFilterManager.getVisibilityForLabel(label: "custom", preferences: preferences) == .warn)
        #expect(ContentFilterManager.getVisibilityForLabel(label: "custom", labelerDid: serviceA, preferences: preferences) == .warn)
        preferences.append(.init(labelerDid: nil, label: "custom", visibility: "hide"))
        preferences.append(.init(labelerDid: serviceA, label: "custom", visibility: "warn"))
        if reverse { preferences.reverse() }
        #expect(ContentFilterManager.getVisibilityForLabel(label: "custom", preferences: preferences) == .hide)
        #expect(ContentFilterManager.getVisibilityForLabel(label: "custom", labelerDid: serviceA, preferences: preferences) == .warn)
        #expect(ContentFilterManager.getVisibilityForLabel(label: "custom", labelerDid: serviceB, preferences: preferences) == .show)
    }

    @Test("Final mute word and service removals send explicit empty collections")
    @MainActor
    func explicitEmptySafetyCollections() async throws {
        let service = try DID(didString: "did:plc:safety-service")
        let fixture = SafetyPreferencesFixture(items: [
            .mutedWordsPref(.init(items: [.init(id: "word1", value: "needle", targets: [.content], actorTarget: "exclude-following")])),
            .labelersPref(.init(labelers: [.init(did: service)])), .adultContentPref(.init(enabled: true))
        ])
        let (manager, local) = try fixture.makeManager()
        try await manager.removeMutedWord(id: "word1", expectedAccountDID: fixture.account)
        try await manager.removeLabelers([service.didString()], expectedAccountDID: fixture.account)
        #expect(fixture.items.contains { if case .mutedWordsPref(let p) = $0 { return p.items.isEmpty }; return false })
        #expect(fixture.items.contains { if case .labelersPref(let p) = $0 { return p.labelers.isEmpty }; return false })
        #expect(local.mutedWords.isEmpty && local.labelers.isEmpty)
        #expect(fixture.items.contains { if case .adultContentPref(let p) = $0 { return p.enabled }; return false })
    }

    @Test("Already subscribed no-op confirms fresh membership and safety without a PUT")
    @MainActor
    func alreadySubscribedPublishesConfirmedSnapshot() async throws {
        let service = try DID(didString: "did:plc:remote-subscribed-service")
        let fixture = SafetyPreferencesFixture(items: [
            .labelersPref(.init(labelers: [.init(did: service)])),
            .adultContentPref(.init(enabled: true)),
            .contentLabelPref(.init(labelerDid: service, label: "custom", visibility: "hide")),
            .mutedWordsPref(.init(items: [.init(id: "remote-word", value: "retained", targets: [.tag], actorTarget: "exclude-following")]))
        ])
        let (manager, local) = try fixture.makeManager()
        #expect(local.labelers.isEmpty)
        try await manager.addLabeler(service, expectedAccountDID: fixture.account)
        #expect(fixture.writes.isEmpty)
        #expect(local.labelers.map(\.did) == [service])
        #expect(local.hasConfirmedServerPreferences)
        #expect(local.adultContentEnabled)
        #expect(local.contentLabelPrefs.first?.visibility == "hide")
        #expect(local.mutedWords.first?.targets == ["tag"])
        #expect(local.mutedWords.first?.actorTarget == "exclude-following")
        #expect(try manager.confirmedFeedFilterPreferences()?.labelers.first?.did == service)
    }

    @Test("A stale already-subscribed no-op cannot publish after account reconfiguration")
    @MainActor
    func staleNoOpSubscriptionRejected() async throws {
        let service = try DID(didString: "did:plc:remote-subscribed-service")
        let fixture = SafetyPreferencesFixture(items: [.labelersPref(.init(labelers: [.init(did: service)]))])
        let (manager, local) = try fixture.makeManager()
        fixture.pauseNextRead = true
        let edit = Task { try await manager.addLabeler(service, expectedAccountDID: fixture.account) }
        try await fixture.waitForPausedRead()
        manager.configure(accountDID: "did:plc:safety-other")
        manager.configure(accountDID: fixture.account)
        fixture.resumeRead()
        do { try await edit.value; Issue.record("A stale no-op must fail") } catch {}
        #expect(fixture.writes.isEmpty)
        #expect(local.labelers.isEmpty)
        #expect(!local.hasConfirmedServerPreferences)
    }

    @Test("Reset builtin service overrides inherits the actual Warn fallback", arguments: ["self-harm", "corpse", "nsfw", "porn", "graphic-media", "NUDITY"])
    @MainActor
    func builtinInheritanceMatchesConsumedPolicy(label: String) async throws {
        let service = try DID(didString: "did:plc:builtin-service")
        let key = ProfileLabelPreferenceAdapter.consumedKey(for: label)
        let fixture = SafetyPreferencesFixture(items: [
            .contentLabelPref(.init(labelerDid: service, label: key, visibility: "ignore")),
            .adultContentPref(.init(enabled: true))
        ])
        let (manager, local) = try fixture.makeManager()
        try await manager.removeContentLabelOverride(label: key, labelerDid: service,
                                                    expectedAccountDID: fixture.account)
        let inherited = ModerationServiceLabelPolicy.inheritedVisibility(label: label,
          preferences: local.contentLabelPrefs, definitionDefault: "hide")
        #expect(inherited == .warn)
        #expect(inherited == ContentFilterManager.getVisibilityForLabel(label: key,
          labelerDid: service, preferences: local.contentLabelPrefs))
        let global = [ContentLabelPreference(labelerDid: nil, label: key, visibility: "ignore")]
        #expect(ModerationServiceLabelPolicy.inheritedVisibility(label: label,
          preferences: global, definitionDefault: "hide") == .show)
    }

    @Test("Custom service inheritance retains supplied defaults and exact key spelling")
    func customServiceInheritanceRemainsExplicit() {
        #expect(ModerationServiceLabelPolicy.inheritedVisibility(label: "Custom-Key",
          preferences: [], definitionDefault: "hide") == .hide)
        #expect(ModerationServiceLabelPolicy.inheritedVisibility(label: "Custom-Key",
          preferences: [], definitionDefault: nil) == .show)
        let global = [ContentLabelPreference(labelerDid: nil, label: "Custom-Key", visibility: "ignore")]
        #expect(ModerationServiceLabelPolicy.inheritedVisibility(label: "Custom-Key",
          preferences: global, definitionDefault: "hide") == .show)
        #expect(ModerationServiceLabelPolicy.inheritedVisibility(label: "custom-key",
          preferences: global, definitionDefault: "hide") == .hide)
    }

    @Test("Failed reads and writes leave confirmed local moderation unchanged", arguments: [false, true])
    @MainActor
    func failuresPreserveLocalState(readFails: Bool) async throws {
        let fixture = SafetyPreferencesFixture(items: [.contentLabelPref(.init(label: "nsfw", visibility: "hide"))])
        fixture.failRead = readFails
        fixture.writeStatus = 503
        let (manager, local) = try fixture.makeManager()
        local.contentLabelPrefs = [.init(labelerDid: nil, label: "nsfw", visibility: "hide")]
        do {
            try await manager.setContentLabelVisibility(label: "nsfw", visibility: "ignore", expectedAccountDID: fixture.account)
            Issue.record("A failed safety transaction must throw")
        } catch {}
        #expect(fixture.writes.count == (readFails ? 0 : 1))
        #expect(local.contentLabelPrefs.first?.visibility == "hide")
        fixture.failRead = false
        fixture.writeStatus = 200
        try await manager.setContentLabelVisibility(label: "nsfw", visibility: "warn", expectedAccountDID: fixture.account)
        #expect(local.contentLabelPrefs.first?.visibility == "warn")
    }

    @Test("A delayed read cannot write after A to B to A reconfiguration")
    @MainActor
    func staleAccountReadRejected() async throws {
        let fixture = SafetyPreferencesFixture(items: [.contentLabelPref(.init(label: "nsfw", visibility: "hide"))])
        fixture.pauseNextRead = true
        let (manager, local) = try fixture.makeManager()
        let edit = Task { @MainActor in
            try await manager.setContentLabelVisibility(label: "nsfw", visibility: "ignore", expectedAccountDID: fixture.account)
        }
        try await fixture.waitForPausedRead()
        manager.configure(accountDID: "did:plc:safety-other")
        manager.configure(accountDID: fixture.account)
        fixture.resumeRead()
        do { try await edit.value; Issue.record("A stale generation must fail") } catch {}
        #expect(fixture.writes.isEmpty)
        #expect(local.contentLabelPrefs.isEmpty)
    }

    @Test("Concurrent different-key edits both survive a serialized remote transaction")
    @MainActor
    func concurrentEditsPreserveBothKeys() async throws {
        let fixture = SafetyPreferencesFixture(items: [])
        fixture.pauseNextRead = true
        let (manager, _) = try fixture.makeManager()
        let first = Task { @MainActor in try await manager.setContentLabelVisibility(label: "nsfw", visibility: "hide") }
        try await fixture.waitForPausedRead()
        let second = Task { @MainActor in try await manager.setContentLabelVisibility(label: "custom", visibility: "warn") }
        await Task.yield()
        fixture.resumeRead()
        try await first.value
        try await second.value
        #expect(fixture.writes.count == 2)
        #expect(fixture.labels.count == 2)
    }

    @Test("Feed row edits preserve remote fields and unrelated feed records")
    @MainActor
    func sparseFeedDelta() async throws {
        let fixture = SafetyPreferencesFixture(items: [
            .feedViewPref(.init(feed: "home", hideReplies: true, hideRepliesByLikeCount: 12, hideReposts: true)),
            .feedViewPref(.init(feed: "other", hideReplies: false, hideRepliesByLikeCount: 42))
        ])
        let (manager, _) = try fixture.makeManager()
        try await manager.setFeedViewPreferences(hideReposts: false, expectedAccountDID: fixture.account)
        let feeds = fixture.items.compactMap { item -> AppBskyActorDefs.FeedViewPref? in
            if case .feedViewPref(let p) = item { return p }; return nil
        }
        #expect(feeds.first { $0.feed == "home" }?.hideRepliesByLikeCount == 12)
        #expect(feeds.first { $0.feed == "home" }?.hideReplies == true)
        #expect(feeds.first { $0.feed == "home" }?.hideReposts == false)
        #expect(feeds.first { $0.feed == "other" }?.hideRepliesByLikeCount == 42)
    }

    @Test("Confirmed defaults reads throw on failure and explicit nil removes only defaults")
    @MainActor
    func confirmedDefaultsBoundary() async throws {
        let fixture = SafetyPreferencesFixture(items: [.postInteractionSettingsPref(.init()), .adultContentPref(.init(enabled: true))])
        let (manager, local) = try fixture.makeManager()
        #expect(try await manager.getConfirmedPostInteractionSettingsPref(expectedAccountDID: fixture.account) != nil)
        fixture.failRead = true
        do { _ = try await manager.getConfirmedPostInteractionSettingsPref(); Issue.record("Failed read must not look absent") } catch {}
        #expect(fixture.writes.isEmpty)
        fixture.failRead = false
        try await manager.setPostInteractionSettingsPref(nil, expectedAccountDID: fixture.account)
        #expect(!fixture.items.contains { if case .postInteractionSettingsPref = $0 { return true }; return false })
        #expect(local.postInteractionSettingsPref == nil)
        #expect(fixture.items.contains { if case .adultContentPref = $0 { return true }; return false })
    }

    @Test("Refresh finishes before the next focused transaction can publish")
    @MainActor
    func queuedRefreshCannotOverwriteEdit() async throws {
        let fixture = SafetyPreferencesFixture(items: [.contentLabelPref(.init(label: "graphic", visibility: "warn"))])
        let (manager, local) = try fixture.makeManager()
        fixture.pauseNextRead = true
        let refresh = Task { try await manager.fetchPreferences(forceRefresh: true) }
        try await fixture.waitForPausedRead()
        let edit = Task { try await manager.setContentLabelVisibility(label: "graphic", visibility: "hide") }
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.writes.isEmpty)
        fixture.resumeRead()
        try await refresh.value
        try await edit.value
        #expect(local.contentLabelPrefs.first?.visibility == "hide")
        #expect(fixture.labels.first?.visibility == "hide")
    }

    @Test("Generic unrelated writes retain fresh remote safety fields")
    @MainActor
    func genericSyncPreservesRemoteSafety() async throws {
        let service = try DID(didString: "did:plc:remote-service")
        let fixture = SafetyPreferencesFixture(items: [
            .contentLabelPref(.init(labelerDid: service, label: "custom", visibility: "hide")),
            .adultContentPref(.init(enabled: true)),
            .mutedWordsPref(.init(items: [.init(id: "fresh", value: "example", targets: [.tag])])),
            .labelersPref(.init(labelers: [.init(did: service)]))
        ])
        let (manager, local) = try fixture.makeManager()
        local.contentLabelPrefs = [.init(labelerDid: nil, label: "custom", visibility: "ignore")]
        local.adultContentEnabled = false
        local.savedFeeds = ["at://did:plc:feed/app.bsky.feed.generator/test"]
        try await manager.saveAndSyncPreferences(local)
        #expect(fixture.labels.count == 1)
        #expect(fixture.labels.first?.labelerDid == service)
        #expect(fixture.labels.first?.visibility == "hide")
        #expect(fixture.items.contains { if case .adultContentPref(let p) = $0 { return p.enabled }; return false })
        #expect(fixture.items.contains { if case .mutedWordsPref(let p) = $0 { return p.items.first?.id == "fresh" }; return false })
        #expect(fixture.items.contains { if case .labelersPref(let p) = $0 { return p.labelers.first?.did == service }; return false })
    }

    @Test("Inherited scoped reset removes exactly one key")
    @MainActor
    func scopedResetPreservesOtherKeys() async throws {
        let a = try DID(didString: "did:plc:service-a")
        let b = try DID(didString: "did:plc:service-b")
        let fixture = SafetyPreferencesFixture(items: [
            .contentLabelPref(.init(label: "custom", visibility: "hide")),
            .contentLabelPref(.init(labelerDid: a, label: "custom", visibility: "ignore")),
            .contentLabelPref(.init(labelerDid: b, label: "custom", visibility: "warn"))])
        let (manager, _) = try fixture.makeManager()
        try await manager.removeContentLabelOverride(label: "custom", labelerDid: a)
        #expect(fixture.labels.count == 2)
        #expect(!fixture.labels.contains { $0.labelerDid == a })
        #expect(fixture.labels.contains { $0.labelerDid == b })
        #expect(fixture.labels.contains { $0.labelerDid == nil })
    }

    @Test("Default rows are not confirmed empty policies")
    @MainActor
    func confirmedPolicyAuthority() async throws {
        let fixture = SafetyPreferencesFixture(items: [.mutedWordsPref(.init(items: []))])
        let (manager, _) = try fixture.makeManager()
        #expect(try manager.confirmedFeedFilterPreferences() == nil)
        try await manager.setContentLabelVisibility(label: "graphic", visibility: "warn")
        let confirmed = try manager.confirmedFeedFilterPreferences()
        #expect(confirmed?.hasConfirmedServerPreferences == true)
        #expect(confirmed?.mutedWords.isEmpty == true)
    }

    @Test("Optional local fields preserve actual absence")
    func optionalLocalAbsence() {
        let local = Preferences()
        #expect(local.threadViewPref == nil)
        #expect(local.feedViewPref == nil)
        local.threadViewPref = .init(sort: "newest", prioritizeFollowedUsers: true)
        local.threadViewPref = nil
        #expect(local.threadViewPref == nil)
    }

    @Test("Paged account lists deduplicate and retry failed removals without false success")
    @MainActor
    func accountListPagingAndRemoval() async {
        let a = ModeratedAccountsModel.Entry(did: "a", handle: "a.test", displayName: nil, avatar: nil)
        let b = ModeratedAccountsModel.Entry(did: "b", handle: "b.test", displayName: nil, avatar: nil)
        var removeSucceeds = false
        var requests: [String?] = []
        let model = ModeratedAccountsModel()
        model.configure(.init(isCurrent: { true }, fetch: { cursor in
            requests.append(cursor)
            return cursor == nil ? .init(entries: [a], cursor: "next") : .init(entries: [a, b], cursor: nil)
        }, remove: { _ in removeSucceeds }))
        await model.loadNextPage()
        await model.loadNextPage()
        #expect(model.entries.map(\.did) == ["a", "b"])
        #expect(requests == [nil, "next"])
        await model.remove(a)
        #expect(model.entries.map(\.did) == ["a", "b"])
        #expect(model.errorMessage != nil)
        removeSucceeds = true
        await model.retry()
        #expect(model.entries.map(\.did) == ["b"])
        #expect(model.errorMessage == nil)
    }

    @Test("Account admission remains registered until the actual preference body completes")
    @MainActor
    func settingsAccountAdmissionBoundary() async throws {
        let fixture = SafetyPreferencesFixture(items: [])
        let (manager, _) = try fixture.makeManager()
        let boundary = SafetyAccountAdmissionFixture()
        manager.beginSettingsAccountOperation = { boundary.begin() }
        manager.endSettingsAccountOperation = { boundary.end($0) }
        fixture.pauseNextRead = true
        let request = Task { try await manager.setContentLabelVisibility(label: "graphic", visibility: "warn") }
        try await fixture.waitForPausedRead()
        #expect(boundary.active.count == 1)
        boundary.isOpen = false
        do {
            try await manager.setContentLabelVisibility(label: "nudity", visibility: "hide")
            Issue.record("Expected closed admission to reject before I/O")
        } catch {
            guard case PreferencesManagerError.accountChanged = error else {
                Issue.record("Expected accountChanged, got \(error)"); return
            }
        }
        #expect(boundary.active.count == 1)
        #expect(fixture.writes.isEmpty)
        fixture.resumeRead()
        try await request.value
        #expect(boundary.active.isEmpty)
        #expect(boundary.completed == 1)
    }

    @Test("Explicit profile builtin choice writes one consumed key and preserves raw records")
    @MainActor
    func profileAliasWritePreservesRawRecords() async throws {
        let service = try DID(didString: "did:plc:profile-service")
        let fixture = SafetyPreferencesFixture(items: [
            .contentLabelPref(.init(label: "nsfw", visibility: "hide")),
            .contentLabelPref(.init(labelerDid: service, label: "porn", visibility: "ignore")),
            .contentLabelPref(.init(labelerDid: service, label: "Custom-Key", visibility: "unknown-imported-value"))])
        let (manager, _) = try fixture.makeManager()
        let consumed = ProfileLabelPreferenceAdapter.consumedKey(for: "porn")
        try await manager.setContentLabelVisibility(label: consumed, visibility: "warn", labelerDid: service,
                                                   expectedAccountDID: fixture.account)
        #expect(fixture.labels.count == 4)
        #expect(fixture.labels.contains { $0.label == "porn" && $0.visibility == "ignore" })
        #expect(fixture.labels.contains { $0.label == "nsfw" && $0.labelerDid == nil && $0.visibility == "hide" })
        #expect(fixture.labels.contains { $0.label == "nsfw" && $0.labelerDid == service && $0.visibility == "warn" })
        #expect(fixture.labels.contains { $0.label == "Custom-Key" && $0.visibility == "unknown-imported-value" })
    }

    @Test("Muted words honor targets, expiry, following exclusions, and alt text")
    func completeMutedWordRules() {
        let now = Date(timeIntervalSince1970: 100)
        func word(_ value: String = "cafe", targets: [String] = ["content"],
                  actor: String? = nil, expiry: Date? = nil) -> MutedWord {
            .init(id: "word", value: value, targets: targets, actorTarget: actor, expiresAt: expiry)
        }
        func matches(_ rule: MutedWord, text: String = "", tags: [String] = [],
                     alt: String = "", followed: Bool = false) -> Bool {
            MutedWordMatcher.matches(text: text, tags: tags, altText: alt,
                                     authorIsFollowed: followed, words: [rule], now: now)
        }
        #expect(matches(word(), text: "A CAFÉ"))
        #expect(matches(word(), alt: "A cafe table"))
        #expect(!matches(word(targets: ["tag"]), text: "cafe", alt: "cafe"))
        #expect(matches(word("#cafe", targets: ["tag"]), tags: ["CAFÉ"]))
        #expect(!matches(word("cafe", targets: ["tag"]), tags: ["cafeteria"]))
        #expect(!matches(word(actor: "exclude-following"), text: "cafe", followed: true))
        #expect(matches(word(actor: "exclude-following"), text: "cafe", followed: false))
        #expect(!matches(word(expiry: now), text: "cafe"))
        #expect(!matches(word(expiry: now.addingTimeInterval(-1)), text: "cafe"))
        #expect(matches(word(expiry: now.addingTimeInterval(1)), text: "cafe"))
        #expect(!matches(word("  "), text: "anything"))
        #expect(!matches(word("#", targets: ["tag"]), tags: ["cafe"]))
        #expect(!matches(word(targets: []), text: "cafe"))
    }

}


@MainActor
private final class SafetyPreferencesFixture {
    let account = "did:plc:safety-fixture"
    var items: [AppBskyActorDefs.PreferencesForUnionArray]
    var writes: [[AppBskyActorDefs.PreferencesForUnionArray]] = []
    var failRead = false
    var writeStatus = 200
    var pauseNextRead = false
    private var readContinuation: CheckedContinuation<Void, Never>?

    init(items: [AppBskyActorDefs.PreferencesForUnionArray]) { self.items = items }
    var labels: [AppBskyActorDefs.ContentLabelPref] {
        items.compactMap { if case .contentLabelPref(let p) = $0 { return p }; return nil }
    }
    var transport: PreferencesManager.SpecificPreferencesTransport {
        .init(getPreferences: {
            if self.pauseNextRead {
                self.pauseNextRead = false
                await withCheckedContinuation { self.readContinuation = $0 }
            }
            if self.failRead { throw NSError(domain: "SafetyFixture", code: 503) }
            return self.items
        }, putPreferences: { items in
            self.writes.append(items)
            if (200..<300).contains(self.writeStatus) { self.items = items }
            return self.writeStatus
        })
    }
    func makeManager() throws -> (PreferencesManager, Preferences) {
        let container = try ModelContainer(for: Preferences.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let local = Preferences(accountDID: account)
        context.insert(local)
        try context.save()
        let defaults = UserDefaults(suiteName: "SafetyFixture.\(UUID().uuidString)")!
        let manager = PreferencesManager(modelContext: context, specificPreferencesTransport: transport, sharedDefaults: defaults)
        manager.configure(accountDID: account)
        return (manager, local)
    }
    func waitForPausedRead() async throws {
        for _ in 0..<1000 {
            if readContinuation != nil { return }
            await Task.yield()
        }
        throw NSError(domain: "SafetyFixture", code: 1)
    }
    func resumeRead() { readContinuation?.resume(); readContinuation = nil }
}

@MainActor
private final class SafetyAccountAdmissionFixture {
    var isOpen = true
    var active: Set<UUID> = []
    var completed = 0
    func begin() -> UUID? {
        guard isOpen else { return nil }
        let id = UUID(); active.insert(id); return id
    }
    func end(_ id: UUID) { active.remove(id); completed += 1 }
}
