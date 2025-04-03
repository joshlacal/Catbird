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

  // Tracking of active filters
  private(set) var activeFilterIds: Set<String> = []

  // Content processors
  private var contentProcessors: [PostContentProcessor] = []
  private var muteWordProcessor: MuteWordProcessor?

  init() {
    // Initialize with standard filters but disabled by default
    setupDefaultFilters()
    loadSavedSettings()
    loadMuteWords()
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
          if case let .appBskyFeedDefsPostView(parent) = post.reply?.parent {
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
    ]
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
  }

  private func loadSavedSettings() {
    // Load filter preferences from UserDefaults
    let defaults = UserDefaults.standard
    if let savedFilters = defaults.object(forKey: "FeedFilterActiveFilters") as? [String] {
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
  }

  private func loadMuteWords() {
    let defaults = UserDefaults.standard
    let muteWordsString = defaults.string(forKey: "muteWords") ?? ""
    let muteWords = muteWordsString.split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if !muteWords.isEmpty {
      let processor = MuteWordProcessor(muteWords: muteWords)
      updateMuteWordProcessor(processor)
    }
  }

  private func saveSettings() {
    // Save filter preferences to UserDefaults
    let defaults = UserDefaults.standard
    defaults.set(Array(activeFilterIds), forKey: "FeedFilterActiveFilters")
  }

  // Update the mute word processor
  func updateMuteWordProcessor(_ processor: MuteWordProcessor) {
    // Remove existing mute word processor if present
    contentProcessors.removeAll { $0 is MuteWordProcessor }

    // Add new processor
    contentProcessors.append(processor)
    muteWordProcessor = processor
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
      if case let .knownType(parentPostObj) = postView.record,
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
