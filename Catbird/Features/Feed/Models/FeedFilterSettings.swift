import Foundation
import Observation
import Petrel
import SwiftUI

// MARK: - Feed Filter Types

/// Defines a filter operation on feed posts
struct FeedFilter: Identifiable, Hashable {
  var id: String { name }
  let name: String
  let description: String
  let isEnabled: Bool
  let filterBlock: (AppBskyFeedDefs.FeedViewPost) -> Bool

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: FeedFilter, rhs: FeedFilter) -> Bool {
    return lhs.id == rhs.id
  }
}

/// Manages filter settings and persists user preferences
@Observable final class FeedFilterSettings {
  var filters: [FeedFilter] = []

  // Feed sorting mode (Latest by default). When set to .relevant,
  // callers may re-rank using on-device embeddings.
  enum FeedSortMode: String, CaseIterable, Identifiable {
    case latest
    case relevant
    var id: String { rawValue }
  }

  var sortMode: FeedSortMode = .latest {
    didSet { saveSettings() }
  }

  // Tracking of active filters
  private(set) var activeFilterIds: Set<String> = []

  // Content processors
  private var contentProcessors: [PostContentProcessor] = []
  private var muteWordProcessor: MuteWordProcessor?
  private var languageProcessor: LanguageFilterProcessor?

  init() {
    // Initialize with standard filters but disabled by default
    setupDefaultFilters()
    loadSavedSettings()
    loadSortMode()
    loadMuteWords()
    loadLanguageFilter()
  }

  private func setupDefaultFilters() {
    filters = [
      FeedFilter(
        name: "Hide Reposts",
        description: "Hide reposts from your feed",
        isEnabled: false,
        filterBlock: { post in
          // Return true to keep, false to filter out
          if case .appBskyFeedDefsReasonRepost = post.reason {
            return false
          }
          return true
        }
      ),
      FeedFilter(
        name: "Hide Replies",
        description: "Hide replies that aren't part of threads you're participating in",
        isEnabled: false,
        filterBlock: { post in
          // Only filter out replies that aren't self-threads
          guard let reply = post.reply else { return true }

          // Check if it's a repost (we don't filter these)
          let isRepost = post.reason != nil

          if !isRepost {
            // Now check if it's a self-thread by comparing authors
            let author = post.post.author
            var isSelfThread = true

            // Check parent author if available
            switch reply.parent {
            case .appBskyFeedDefsPostView(let parentView):
              if parentView.author.did != author.did {
                isSelfThread = false
              }
            default:
              break
            }

            // Check root author if available
            switch reply.root {
            case .appBskyFeedDefsPostView(let rootView):
              if rootView.author.did != author.did {
                isSelfThread = false
              }
            default:
              break
            }

            return isSelfThread
          }

          return true
        }
      ),
      FeedFilter(
        name: "Hide Quote Posts",
        description: "Hide posts that quote other posts",
        isEnabled: false,
        filterBlock: { post in
          if case .appBskyFeedDefsPostView(let parent) = post.reply?.parent {
            // Check if the post is a quote
            if let embed = parent.embed {
              switch embed {
              case .appBskyEmbedRecordView, .appBskyEmbedRecordWithMediaView:
                return false
              default:
                return true
              }
            }
            return true
          }

          if let embed = post.post.embed {
            switch embed {
            case .appBskyEmbedRecordView, .appBskyEmbedRecordWithMediaView:
              return false
            default:
              return true
            }
          }
          return true
        }
      ),
      FeedFilter(
        name: "Hide Duplicate Posts",
        description: "Hide standalone posts that also appear as parent posts in replies",
        isEnabled: true,
        // The actual logic is handled in FeedModel, this block is a placeholder
        filterBlock: { _ in true }
      ),
      FeedFilter(
        name: "Only Text Posts",
        description: "Show only posts with text (no images, videos, or links)",
        isEnabled: false,
        filterBlock: { post in
          return post.post.embed == nil
        }
      ),
      FeedFilter(
        name: "Only Media Posts",
        description: "Show only posts with images or videos",
        isEnabled: false,
        filterBlock: { post in
          // Check the main post's embed
          if let embed = post.post.embed {
            switch embed {
            case .appBskyEmbedImagesView, .appBskyEmbedVideoView:
              return true
            case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
              // Quote post with media - check the media part
              switch recordWithMedia.media {
              case .appBskyEmbedImagesView, .appBskyEmbedVideoView:
                return true
              default:
                return false
              }
            default:
              return false
            }
          }
          return false
        }
      ),
      FeedFilter(
        name: "Hide Link Posts",
        description: "Hide posts with external links",
        isEnabled: false,
        filterBlock: { post in
          // Check the main post for external links in embeds
          if let embed = post.post.embed {
            switch embed {
            case .appBskyEmbedExternalView:
              return false
            case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
              // Quote post with media - check if media is external
              switch recordWithMedia.media {
              case .appBskyEmbedExternalView:
                return false
              default:
                break
              }
            default:
              break
            }
          }

          // Also check for links in the post text via facets
          guard case .knownType(let record) = post.post.record,
            let feedPost = record as? AppBskyFeedPost
          else {
            return true
          }

          // Check facets for links
          if let facets = feedPost.facets {
            for facet in facets {
              for feature in facet.features {
                if case .appBskyRichtextFacetLink = feature {
                  return false
                }
              }
            }
          }

          return true
        }
      ),
      FeedFilter(
        name: "Filter by Language",
        description: "Only show posts in your selected content languages",
        isEnabled: false,
        // The actual filtering is done by LanguageFilterProcessor
        filterBlock: { _ in true }
      ),
    ]
  }

  // Convenience methods for quick filter access
  func isFilterEnabled(name: String) -> Bool {
    return filters.first(where: { $0.name == name })?.isEnabled ?? false
  }

  func enableOnlyFilter(name: String) {
    // Disable all filters first
    for index in filters.indices {
      let filter = filters[index]
      filters[index] = FeedFilter(
        name: filter.name,
        description: filter.description,
        isEnabled: false,
        filterBlock: filter.filterBlock
      )
    }
    // Enable the specified filter
    if let index = filters.firstIndex(where: { $0.name == name }) {
      let filter = filters[index]
      filters[index] = FeedFilter(
        name: filter.name,
        description: filter.description,
        isEnabled: true,
        filterBlock: filter.filterBlock
      )
      activeFilterIds.insert(name)
    }
    saveSettings()
  }

  func clearAllFilters() {
    for index in filters.indices {
      let filter = filters[index]
      // Skip "Hide Duplicate Posts" which should stay enabled
      if filter.name == "Hide Duplicate Posts" { continue }
      filters[index] = FeedFilter(
        name: filter.name,
        description: filter.description,
        isEnabled: false,
        filterBlock: filter.filterBlock
      )
    }
    activeFilterIds.removeAll()
    activeFilterIds.insert("Hide Duplicate Posts")
    saveSettings()
  }

  func toggleFilter(id: String) {
    guard let index = filters.firstIndex(where: { $0.id == id }) else { return }

    // Create new filter with toggled state
    let filter = filters[index]
    let updatedFilter = FeedFilter(
      name: filter.name,
      description: filter.description,
      isEnabled: !filter.isEnabled,
      filterBlock: filter.filterBlock
    )

    // Update our filter list
    filters[index] = updatedFilter

    // Update tracking set
    if updatedFilter.isEnabled {
      activeFilterIds.insert(id)
    } else {
      activeFilterIds.remove(id)
    }

    // Persist settings
    saveSettings()

    // Handle language filter toggle
    if filter.name == "Filter by Language" {
      if updatedFilter.isEnabled {
        loadLanguageFilter()
      } else {
        // Remove language processor when disabled
        contentProcessors.removeAll { $0 is LanguageFilterProcessor }
        languageProcessor = nil
      }
    }
  }

  private func loadSavedSettings() {
    // Load filter preferences from UserDefaults
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    if let savedFilters = defaults?.object(forKey: "FeedFilterActiveFilters") as? [String] {
      activeFilterIds = Set(savedFilters)

      // Update filters based on saved settings
      for i in 0..<filters.count {
        let filter = filters[i]
        let isEnabled = activeFilterIds.contains(filter.id)
        if filter.isEnabled != isEnabled {
          filters[i] = FeedFilter(
            name: filter.name,
            description: filter.description,
            isEnabled: isEnabled,
            filterBlock: filter.filterBlock
          )
        }
      }
    }
    // Load additional settings
    if let raw = defaults?.string(forKey: "FeedSortMode"), let mode = FeedSortMode(rawValue: raw) {
      sortMode = mode
    }
  }

  private func loadMuteWords() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    let muteWordsString = defaults?.string(forKey: "muteWords") ?? ""
    let muteWords = muteWordsString.split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if !muteWords.isEmpty {
      let processor = MuteWordProcessor(muteWords: muteWords)
      updateMuteWordProcessor(processor)
    }
  }

  private func loadLanguageFilter() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    let contentLanguages = defaults?.stringArray(forKey: "contentLanguages") ?? ["en"]
    let isLanguageFilterEnabled =
      filters.first { $0.name == "Filter by Language" }?.isEnabled ?? false

    if isLanguageFilterEnabled && !contentLanguages.isEmpty {
      let processor = LanguageFilterProcessor(contentLanguages: contentLanguages)
      updateLanguageProcessor(processor)
    }

    // Listen for language preference changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(languagePreferencesChanged),
      name: NSNotification.Name("LanguagePreferencesChanged"),
      object: nil
    )
  }

  @objc private func languagePreferencesChanged() {
    loadLanguageFilter()
  }

  private func saveSettings() {
    // Save filter preferences to UserDefaults
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")

    defaults?.set(Array(activeFilterIds), forKey: "FeedFilterActiveFilters")
    defaults?.set(sortMode.rawValue, forKey: "FeedSortMode")
  }

  // Update the mute word processor
  func updateMuteWordProcessor(_ processor: MuteWordProcessor) {
    // Remove existing mute word processor if present
    contentProcessors.removeAll { $0 is MuteWordProcessor }

    // Add new processor
    contentProcessors.append(processor)
    muteWordProcessor = processor
  }

  // Update the language filter processor
  func updateLanguageProcessor(_ processor: LanguageFilterProcessor) {
    // Remove existing language processor if present
    contentProcessors.removeAll { $0 is LanguageFilterProcessor }

    // Add new processor
    contentProcessors.append(processor)
    languageProcessor = processor
  }

  // Get active filters only
  var activeFilters: [FeedFilter] {
    // Combine standard filters with content processor filters
    var allFilters = filters.filter { $0.isEnabled }

    // Add content processor filters
    for processor in contentProcessors {
      allFilters.append(
        FeedFilter(
          name: "Content Filter",
          description: "Content filtering",
          isEnabled: true,
          filterBlock: processor.process
        ))
    }

    return allFilters
  }

  // Load persisted sort mode
  func loadSortMode() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    if let raw = defaults?.string(forKey: "FeedSortMode"),
      let mode = FeedSortMode(rawValue: raw)
    {
      sortMode = mode
    }
  }

  // MARK: - Convenience Properties

  /// Convenience property for checking if "Hide Link Posts" filter is enabled
  var hideLinks: Bool {
    isFilterEnabled(name: "Hide Link Posts")
  }

  /// Convenience property for checking if "Only Text Posts" filter is enabled
  var onlyTextPosts: Bool {
    isFilterEnabled(name: "Only Text Posts")
  }

  /// Convenience property for checking if "Only Media Posts" filter is enabled
  var onlyMediaPosts: Bool {
    isFilterEnabled(name: "Only Media Posts")
  }

  /// Convenience property for checking if "Hide Replies" filter is enabled
  var hideReplies: Bool {
    isFilterEnabled(name: "Hide Replies")
  }

  /// Convenience property for checking if "Hide Reposts" filter is enabled
  var hideReposts: Bool {
    isFilterEnabled(name: "Hide Reposts")
  }

  /// Convenience property for checking if "Hide Quote Posts" filter is enabled
  var hideQuotePosts: Bool {
    isFilterEnabled(name: "Hide Quote Posts")
  }

  /// Convenience property for "Hide Replies By Unfollowed"
  /// Note: This is controlled via FeedViewPreference server sync, not local filters
  var hideRepliesByUnfollowed: Bool {
    // This setting is managed through PreferencesManager.feedViewPref
    // Return false here as it's not part of the local filter system
    false
  }
}

// MARK: - Content Processing Capabilities

/// Protocol for text content processors
protocol PostContentProcessor {
  // Process post content and return true if it should be shown, false if it should be filtered
  func process(post: AppBskyFeedDefs.FeedViewPost) -> Bool

  // Optional metadata the processor might add to a post
  func metadataForPost(uri: String) -> [String: Any]?
}

final class MuteWordProcessor: PostContentProcessor {
  private let muteWords: [String]

  init(muteWords: [String]) {
    self.muteWords = muteWords.map { $0.lowercased() }
  }

  func process(post: AppBskyFeedDefs.FeedViewPost) -> Bool {
    // Extract text from post
    guard case .knownType(let postObj) = post.post.record,
      let feedPost = postObj as? AppBskyFeedPost
    else {
      return true
    }

    // if post has a parent reply, also check the parent post's text for mute words

    switch post.reply?.parent {
    case .appBskyFeedDefsPostView(let postView):
      if case .knownType(let parentPostObj) = postView.record,
        let parentFeedPost = parentPostObj as? AppBskyFeedPost
      {
        // Check the parent post's text for mute words
        let parentText = parentFeedPost.text.lowercased()
        for word in muteWords {
          if parentText.contains(word) {
            return false
          }
        }
      }
    default:
      break
    }

    let text = feedPost.text.lowercased()

    // Check for muted words
    for word in muteWords {
      if text.contains(word) {
        return false
      }
    }

    return true
  }

  func metadataForPost(uri: String) -> [String: Any]? {
    return nil
  }
}

// MARK: - Language Filter Processor

final class LanguageFilterProcessor: PostContentProcessor {
  private let contentLanguages: [String]
  private let detector = LanguageDetector.shared

  init(contentLanguages: [String]) {
    self.contentLanguages = contentLanguages
  }

  func process(post: AppBskyFeedDefs.FeedViewPost) -> Bool {
    // Extract text from post
    guard case .knownType(let postObj) = post.post.record,
      let feedPost = postObj as? AppBskyFeedPost
    else {
      return true
    }

    // Check if the post's language matches our content languages
    return detector.matchesContentLanguages(feedPost.text, contentLanguages: contentLanguages)
  }

  func metadataForPost(uri: String) -> [String: Any]? {
    return nil
  }
}
