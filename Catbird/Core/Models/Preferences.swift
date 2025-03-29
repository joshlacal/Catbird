import Foundation
import OrderedCollections
import Petrel
import SwiftData

// Add enum for system feed types
enum SystemFeedTypes {
  static let following = "following"
  static let timelineV1 = "home"  // Legacy name

  static let protectedSystemFeeds = [
    following,
    timelineV1,
    "timeline",  // Another possible identifier
  ]

  static func isTimelineFeed(_ uri: String) -> Bool {
    return protectedSystemFeeds.contains(uri) || uri.contains("/app.bsky.feed.generator/timeline")
      || uri.contains("/app.bsky.feed.generator/following")
  }
}

@Model
final class Preferences {
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

  // Simple properties
  var adultContentEnabled: Bool = false
  var birthDate: Date?
  var activeProgressGuide: String?

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
      return
        (try? JSONDecoder().decode(
          [ContentLabelPreference].self, from: Data(contentLabelPrefsData.utf8))) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        contentLabelPrefsData = String(data: data, encoding: .utf8) ?? "[]"
      }
    }
  }

  var threadViewPref: ThreadViewPreference? {
    get {
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
      return try? JSONDecoder().decode(FeedViewPreference.self, from: Data(feedViewPrefData.utf8))
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
      return (try? JSONDecoder().decode([MutedWord].self, from: Data(mutedWordsData.utf8))) ?? []
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
      return (try? JSONDecoder().decode([LabelerPreference].self, from: Data(labelersData.utf8)))
        ?? []
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


  // Initialize with all the preferences
  init(
    savedFeeds: [String] = [],
    pinnedFeeds: [String] = [],
    contentLabelPrefs: [ContentLabelPreference] = [],
    threadViewPref: ThreadViewPreference? = nil,
    feedViewPref: FeedViewPreference? = nil,
    adultContentEnabled: Bool = false,
    birthDate: Date? = nil,
    mutedWords: [MutedWord] = [],
    hiddenPosts: [String] = [],
    labelers: [LabelerPreference] = [],
    activeProgressGuide: String? = nil,
    queuedNudges: [String] = [],
    nuxStates: [NuxState] = [],
    interests: [String] = []
  ) {
    // Initialize with empty JSON data
    self.savedFeedsData = "[]"
    self.pinnedFeedsData = "[]"
    self.contentLabelPrefsData = "[]"
    self.threadViewPrefData = "{}"
    self.feedViewPrefData = "{}"
    self.mutedWordsData = "[]"
    self.hiddenPostsData = "[]"
    self.labelersData = "[]"
    self.nuxStatesData = "[]"
    self.interestsData = "[]"
    self.queuedNudgesData = "[]"

    // Set using computed properties
    self.savedFeeds = savedFeeds

    // Ensure timeline feed is present in pinned feeds
    var finalPinnedFeeds = pinnedFeeds
    if !finalPinnedFeeds.contains(where: { SystemFeedTypes.isTimelineFeed($0) }) {
      finalPinnedFeeds.insert(SystemFeedTypes.following, at: 0)
    }
    self.pinnedFeeds = finalPinnedFeeds

    // Set remaining properties
    self.contentLabelPrefs = contentLabelPrefs
    self.threadViewPref = threadViewPref
    self.feedViewPref = feedViewPref
    self.adultContentEnabled = adultContentEnabled
    self.birthDate = birthDate
    self.mutedWords = mutedWords
    self.hiddenPosts = hiddenPosts
    self.labelers = labelers
    self.activeProgressGuide = activeProgressGuide
    self.queuedNudges = queuedNudges
    self.nuxStates = nuxStates
    self.interests = interests
    self.queuedNudges = queuedNudges

    // Ensure timeline feed is present
    //    ensureTimelineFeed()
  }

  func updateFeeds(pinned: [String], saved: [String]) {
    // Get existing protected feeds from pinned list
    let existingProtectedFeeds = self.pinnedFeeds.filter { feed in
      SystemFeedTypes.isTimelineFeed(feed)
    }

    // Start with supplied feeds, ensure no duplicates
    var newPinnedFeeds = Array(OrderedSet(pinned))

    // Add any existing protected feeds that might be missing
    for protectedFeed in existingProtectedFeeds {
      if !newPinnedFeeds.contains(protectedFeed) {
        newPinnedFeeds.append(protectedFeed)
      }
    }

    // If we still don't have any timeline feed, add the default one
    if !newPinnedFeeds.contains(where: { SystemFeedTypes.isTimelineFeed($0) }) {
      newPinnedFeeds.append(SystemFeedTypes.following)
    }

    // Update pinned feeds
    self.pinnedFeeds = Array(OrderedSet(newPinnedFeeds))

    // Update saved feeds, filtering out any that are already pinned
    let allSaved = OrderedSet(saved)
    self.savedFeeds = Array(allSaved.subtracting(self.pinnedFeeds))
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
  func setContentLabelVisibility(for label: String, visibility: String, labelerDid: DID? = nil) {
    // Remove existing preference if any
    contentLabelPrefs.removeAll {
        $0.label == label && $0.labelerDid?.didString() == labelerDid?.didString()
    }

    // Add new preference
    contentLabelPrefs.append(
      ContentLabelPreference(
        labelerDid: labelerDid,
        label: label,
        visibility: visibility
      ))
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
