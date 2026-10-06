import Foundation
import OrderedCollections
import os
import Petrel
import SwiftData

// Add enum for system feed types
enum SystemFeedTypes {
  static let following = "following"
  static let timelineV1 = "home"  // Legacy name

  static let protectedSystemFeeds = [
    following,
    timelineV1,
    "timeline"  // Another possible identifier
  ]

  static func isTimelineFeed(_ uri: String) -> Bool {
    return protectedSystemFeeds.contains(uri) || uri.contains("timeline")
      || uri.contains("following")
  }
}

/// Feed and trending rows read these JSON-backed preferences per render; decode only when the stored JSON changes.
private final class PreferenceDecodeCache<Value: Sendable>: Sendable {
  private let state = OSAllocatedUnfairLock<(raw: String, value: Value)?>(initialState: nil)

  func value(for raw: String, decode: (String) -> Value) -> Value {
    if let cached = state.withLock({ $0 }), cached.raw == raw { return cached.value }
    let value = decode(raw)
    state.withLock { $0 = (raw, value) }
    return value
  }
}

private let feedViewPrefCache = PreferenceDecodeCache<FeedViewPreference?>()
private let mutedWordsCache = PreferenceDecodeCache<[MutedWord]>()
private let labelersCache = PreferenceDecodeCache<[LabelerPreference]>()
private let contentLabelPrefsCache = PreferenceDecodeCache<[ContentLabelPreference]>()

@Model
final class Preferences {
  // Per-account scoping — used for local DB filtering only, not sent to server
  var accountDID: String = ""

  // Store arrays as JSON strings
  private var pinnedFeedsData: String
  private var savedFeedsData: String

  // New preference storage
  private var contentLabelPrefsData: String = "[]"
  private var threadViewPrefData: String = "{}"
  private var feedViewPrefData: String = "{}"
  private var mutedWordsData: String = "[]"
  private var hiddenPostsData: String = "[]"
  private var labelersData: String = "[]"
  private var nuxStatesData: String = "[]"
  private var interestsData: String = "[]"
  private var queuedNudgesData: String = "[]"
  private var postInteractionSettingsData: String = "{}"
  private var verificationPrefsData: String = "{}"

  // Simple properties
  var hasConfirmedServerPreferences: Bool = false
  var adultContentEnabled: Bool = false
  var hideVerificationBadges: Bool = false
  var activeProgressGuide: String?
  // Language preferences
  var primaryLanguage: String = "en"
  private var contentLanguagesData: String = "[\"en\"]"

  // Computed properties for accessing as arrays
  var pinnedFeeds: [String] {
    get {
      return (try? JSONDecoder().decode([String].self, from: Data(pinnedFeedsData.utf8))) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        pinnedFeedsData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var savedFeeds: [String] {
    get {
      return (try? JSONDecoder().decode([String].self, from: Data(savedFeedsData.utf8))) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        savedFeedsData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  // New computed properties
  var contentLabelPrefs: [ContentLabelPreference] {
    get {
      contentLabelPrefsCache.value(for: contentLabelPrefsData) { raw in
        (try? JSONDecoder().decode([ContentLabelPreference].self, from: Data(raw.utf8))) ?? []
      }
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        contentLabelPrefsData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var threadViewPref: ThreadViewPreference? {
    get {
      guard threadViewPrefData != "{}" else { return nil }
      return try? JSONDecoder().decode(
        ThreadViewPreference.self, from: Data(threadViewPrefData.utf8))
    }
    set {
      if let value = newValue, let data = try? JSONEncoder().encode(value) {
        threadViewPrefData = String(data: data, encoding: .utf8) ?? "{}"
      } else {
        threadViewPrefData = "{}"
      }
    }
  }

  var feedViewPref: FeedViewPreference? {
    get {
      feedViewPrefCache.value(for: feedViewPrefData) { raw in
        guard raw != "{}" else { return nil }
        return try? JSONDecoder().decode(FeedViewPreference.self, from: Data(raw.utf8))
      }
    }
    set {
      if let value = newValue, let data = try? JSONEncoder().encode(value) {
        feedViewPrefData = String(data: data, encoding: .utf8) ?? "{}"
      } else {
        feedViewPrefData = "{}"
      }
    }
  }

  var mutedWords: [MutedWord] {
    get {
      mutedWordsCache.value(for: mutedWordsData) { raw in
        (try? JSONDecoder().decode([MutedWord].self, from: Data(raw.utf8))) ?? []
      }
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        mutedWordsData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var hiddenPosts: [String] {
    get {
      return (try? JSONDecoder().decode([String].self, from: Data(hiddenPostsData.utf8))) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        hiddenPostsData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var labelers: [LabelerPreference] {
    get {
      labelersCache.value(for: labelersData) { raw in
        (try? JSONDecoder().decode([LabelerPreference].self, from: Data(raw.utf8))) ?? []
      }
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        labelersData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var nuxStates: [NuxState] {
    get {
      return (try? JSONDecoder().decode([NuxState].self, from: Data(nuxStatesData.utf8))) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        nuxStatesData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var interests: [String] {
    get {
      return (try? JSONDecoder().decode([String].self, from: Data(interestsData.utf8))) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        interestsData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var queuedNudges: [String] {
    get {
      return (try? JSONDecoder().decode([String].self, from: Data(queuedNudgesData.utf8))) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        queuedNudgesData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }
  
  var contentLanguages: [String] {
    get {
      return (try? JSONDecoder().decode([String].self, from: Data(contentLanguagesData.utf8))) ?? ["en"]
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        contentLanguagesData = String(data: data, encoding: .utf8) ?? "[\"en\"]"
      }
    }
  }
  var postInteractionSettingsPref: AppBskyActorDefs.PostInteractionSettingsPref? {
    get {
      guard postInteractionSettingsData != "{}" && !postInteractionSettingsData.isEmpty else { return nil }
      return try? JSONDecoder().decode(AppBskyActorDefs.PostInteractionSettingsPref.self, from: Data(postInteractionSettingsData.utf8))
    }
    set {
      if let value = newValue, let data = try? JSONEncoder().encode(value) {
        postInteractionSettingsData = String(data: data, encoding: .utf8) ?? "{}"
      } else {
        postInteractionSettingsData = "{}"
      }
    }
  }

  var verificationPrefs: AppBskyActorDefs.VerificationPrefs? {
    get {
      guard verificationPrefsData != "{}" && !verificationPrefsData.isEmpty else { return nil }
      return try? JSONDecoder().decode(AppBskyActorDefs.VerificationPrefs.self, from: Data(verificationPrefsData.utf8))
    }
    set {
      if let value = newValue, let data = try? JSONEncoder().encode(value) {
        verificationPrefsData = String(data: data, encoding: .utf8) ?? "{}"
      } else {
        verificationPrefsData = "{}"
      }
    }
  }

  // Initialize with all the preferences
  /// A detached value copy for restoring an in-memory managed row after save failure.
  func detachedSnapshot() -> Preferences {
    let copy = Preferences(accountDID: accountDID)
    copy.restoreValues(from: self)
    return copy
  }

  func restoreValues(from value: Preferences) {
    hasConfirmedServerPreferences = value.hasConfirmedServerPreferences
    pinnedFeeds = value.pinnedFeeds
    savedFeeds = value.savedFeeds
    contentLabelPrefs = value.contentLabelPrefs
    threadViewPref = value.threadViewPref
    feedViewPref = value.feedViewPref
    adultContentEnabled = value.adultContentEnabled
    mutedWords = value.mutedWords
    hiddenPosts = value.hiddenPosts
    labelers = value.labelers
    activeProgressGuide = value.activeProgressGuide
    queuedNudges = value.queuedNudges
    nuxStates = value.nuxStates
    interests = value.interests
    postInteractionSettingsPref = value.postInteractionSettingsPref
    verificationPrefs = value.verificationPrefs
    hideVerificationBadges = value.hideVerificationBadges
    primaryLanguage = value.primaryLanguage
    contentLanguages = value.contentLanguages
  }

  init(
    accountDID: String = "",
    savedFeeds: [String] = [],
    pinnedFeeds: [String] = [],
    contentLabelPrefs: [ContentLabelPreference] = [],
    threadViewPref: ThreadViewPreference? = nil,
    feedViewPref: FeedViewPreference? = nil,
    adultContentEnabled: Bool = false,
    mutedWords: [MutedWord] = [],
    hiddenPosts: [String] = [],
    labelers: [LabelerPreference] = [],
    activeProgressGuide: String? = nil,
    queuedNudges: [String] = [],
    nuxStates: [NuxState] = [],
    interests: [String] = [],
    primaryLanguage: String = "en",
    contentLanguages: [String] = ["en"],
    hideVerificationBadges: Bool = false,
    postInteractionSettingsPref: AppBskyActorDefs.PostInteractionSettingsPref? = nil,
    verificationPrefs: AppBskyActorDefs.VerificationPrefs? = nil
  ) {
    // Set account scoping
    self.accountDID = accountDID

    // Initialize with empty JSON data
    self.savedFeedsData = "[]"
    self.pinnedFeedsData = "[]"
    self.contentLabelPrefsData = "[]"
    self.threadViewPrefData = "{}"
    self.feedViewPrefData = "{}"
    self.postInteractionSettingsData = "{}"
    self.verificationPrefsData = "{}"
    self.mutedWordsData = "[]"
    self.hideVerificationBadges = hideVerificationBadges
    self.nuxStatesData = "[]"
    self.interestsData = "[]"
    self.queuedNudgesData = "[]"

    // Set using computed properties
    self.savedFeeds = savedFeeds

    // Ensure timeline feed is present in pinned feeds without forcing it to the front
    var finalPinnedFeeds = pinnedFeeds
    if !finalPinnedFeeds.contains(where: { SystemFeedTypes.isTimelineFeed($0) }) {
      finalPinnedFeeds.append(SystemFeedTypes.following)
    }
    self.pinnedFeeds = finalPinnedFeeds

    // Set remaining properties
    self.contentLabelPrefs = contentLabelPrefs
    self.threadViewPref = threadViewPref
    self.feedViewPref = feedViewPref
    self.adultContentEnabled = adultContentEnabled
    self.mutedWords = mutedWords
    self.hiddenPosts = hiddenPosts
    self.labelers = labelers
    self.activeProgressGuide = activeProgressGuide
    self.queuedNudges = queuedNudges
    self.nuxStates = nuxStates
    self.interests = interests
    self.primaryLanguage = primaryLanguage
    self.contentLanguages = contentLanguages

    // Ensure timeline feed is present
    //    ensureTimelineFeed()
  }

  func pinFeed(_ uri: String) {
    // If already pinned, do nothing
    if pinnedFeeds.contains(uri) {
      return
    }

    // Add to pinned feeds
    pinnedFeeds.append(uri)
  }

  func unpinFeed(_ uri: String) {
    // Never unpin protected system feeds
    if SystemFeedTypes.isTimelineFeed(uri) {
      return
    }

    // Only unpin if currently pinned
    if let index = pinnedFeeds.firstIndex(of: uri) {
      pinnedFeeds.remove(at: index)

      // Add to saved feeds if not already there
      if !savedFeeds.contains(uri) {
        savedFeeds.append(uri)
      }
    }
  }

  func updateFeeds(pinned: [String], saved: [String]) {
    logger.debug("[updateFeeds] called with pinned: \(pinned), saved: \(saved)")

    // Start with supplied feeds, ensuring no duplicates and preserving order
    var newPinnedFeeds = Array(OrderedSet(pinned))
    logger.debug("[updateFeeds] Initial newPinnedFeeds from server (ordered): \(newPinnedFeeds)")

    // Check if timeline feed exists in the input
    let hasTimelineInInput = newPinnedFeeds.contains { SystemFeedTypes.isTimelineFeed($0) }
    logger.debug("[updateFeeds] Has timeline in input: \(hasTimelineInInput)")

    // If timeline is missing, ensure it's added
    if !hasTimelineInInput {
      // First check if we have an existing timeline feed locally
      if let existingTimeline = self.pinnedFeeds.first(where: { SystemFeedTypes.isTimelineFeed($0) }
      ) {
        // Insert at the front by default. Server should ideally handle position,
        // but this is a safe fallback if it's missing entirely.
        logger.debug(
          "[updateFeeds] Timeline missing from server, inserting existing local timeline '\(existingTimeline)' at front."
        )
        newPinnedFeeds.insert(existingTimeline, at: 0)
      } else {
        // No timeline feed found locally or on server, add the default one at the front
        logger.debug(
          "[updateFeeds] Timeline missing everywhere, inserting default '\(SystemFeedTypes.following)' at front."
        )
        newPinnedFeeds.insert(SystemFeedTypes.following, at: 0)
      }
    } else {
      logger.debug("[updateFeeds] Timeline feed found in server input.")
    }

    // Update pinned feeds, maintaining the exact order provided (potentially with timeline added)
    // Use OrderedSet again to handle potential duplicates if timeline was added
    self.pinnedFeeds = Array(OrderedSet(newPinnedFeeds))
    logger.debug("[updateFeeds] Final self.pinnedFeeds: \(self.pinnedFeeds)")

    // Update saved feeds, removing any that are already pinned
    let allSaved = OrderedSet(saved)
    self.savedFeeds = Array(allSaved.subtracting(self.pinnedFeeds))
    logger.debug("[updateFeeds] Final self.savedFeeds: \(self.savedFeeds)")
  }

  func allUniqueFeeds() -> [String] {
    Array(OrderedSet(pinnedFeeds + savedFeeds))
  }

  func addFeed(_ uri: String, pinned: Bool = false) {
    if pinned {
      if !pinnedFeeds.contains(uri) {
        pinnedFeeds.append(uri)
      }
    } else {
      if !savedFeeds.contains(uri) {
        savedFeeds.append(uri)
      }
    }
  }

  func removeFeed(_ uri: String) {
    // Never remove protected system feeds
    if SystemFeedTypes.isTimelineFeed(uri) {
      return
    }

    pinnedFeeds.removeAll(where: { $0 == uri })
    savedFeeds.removeAll(where: { $0 == uri })
  }

  func togglePinStatus(for uri: String) {
    if pinnedFeeds.contains(uri) {
      // If this is a timeline feed, don't allow unpinning
      if SystemFeedTypes.isTimelineFeed(uri) {
        return
      }

      pinnedFeeds.removeAll(where: { $0 == uri })
      if !savedFeeds.contains(uri) {
        savedFeeds.append(uri)
      }
    } else {
      pinnedFeeds.append(uri)
      savedFeeds.removeAll(where: { $0 == uri })
    }
  }

  // Helper method to ensure timeline feed is always present
  private func ensureTimelineFeed() {
    // Check if we have a timeline feed in pinned feeds
    let hasTimelineFeed = pinnedFeeds.contains { SystemFeedTypes.isTimelineFeed($0) }

    if !hasTimelineFeed {
      // First check if there's one in saved feeds
      if let timelineFeed = savedFeeds.first(where: { SystemFeedTypes.isTimelineFeed($0) }) {
        // Move from saved to pinned
        savedFeeds.removeAll { $0 == timelineFeed }
        pinnedFeeds.append(timelineFeed)
      } else {
        // No timeline feed found, add the default one
        pinnedFeeds.append(SystemFeedTypes.following)
      }
    }
  }

  // New helper methods for content label preferences
  /// Apply only the addressed (label, service) keys. Other services and custom labels survive.
  static func mergingContentLabelPreferences(
    _ updates: [ContentLabelPreference], into existing: [ContentLabelPreference]
  ) -> [ContentLabelPreference] {
    var result = existing
    for update in updates {
      result.removeAll {
        $0.label == update.label && $0.labelerDid?.didString() == update.labelerDid?.didString()
      }
      result.append(update)
    }
    return result
  }

  func setContentLabelVisibility(for label: String, visibility: String, labelerDid: DID? = nil) {
    contentLabelPrefs = Self.mergingContentLabelPreferences([
      ContentLabelPreference(
        labelerDid: labelerDid,
        label: label,
        visibility: visibility
      )], into: contentLabelPrefs)
  }

  // Helper for muted words
  public func addMutedWord(
    _ word: String,
    targets: [String],
    actorTarget: String? = nil,
    expiresAt: Date? = nil,
    id: String? = nil
  ) {
    if let existingId = id {
      let mutedWord = MutedWord(
        id: existingId,
        value: word,
        targets: targets,
        actorTarget: actorTarget,
        expiresAt: expiresAt
      )
      mutedWords.append(mutedWord)
    } else {
      Task {
        let wordId = await TIDGenerator.next()
        let mutedWord = MutedWord(
          id: wordId.description,
          value: word,
          targets: targets,
          actorTarget: actorTarget,
          expiresAt: expiresAt
        )
        mutedWords.append(mutedWord)
      }
    }
  }

  func removeMutedWord(id: String) {
    mutedWords.removeAll { $0.id == id }
  }

  // Helper for hidden posts
  func hidePost(_ uri: String) {
    if !hiddenPosts.contains(uri) {
      hiddenPosts.append(uri)
    }
  }

  func unhidePost(_ uri: String) {
    hiddenPosts.removeAll { $0 == uri }
  }

  // Helper for labelers
  func addLabeler(_ did: DID) {
    if !labelers.contains(where: { $0.did == did }) {
      labelers.append(LabelerPreference(did: did))
    }
  }

  func removeLabeler(_ did: DID) {
    labelers.removeAll { $0.did == did }
  }

  // Helper for NUX states
  func setNuxCompleted(_ id: String, completed: Bool = true) {
    if let index = nuxStates.firstIndex(where: { $0.id == id }) {
      nuxStates[index].completed = completed
    } else {
      nuxStates.append(NuxState(id: id, completed: completed, data: nil, expiresAt: nil))
    }
  }
}
