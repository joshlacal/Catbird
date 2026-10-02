import Foundation
import os
import Petrel

/// A lightweight outbox that queues posts/threads when online submission fails,
/// and retries them later. Storage is JSON in the app's documents directory.
/// BGTaskScheduler hooks can be added to process in background when available.
struct ComposerOutboxItem: Codable, Identifiable {
  enum Kind: String, Codable { case post, thread }
  let id: UUID
  let kind: Kind
  let postText: String?
  let threadTexts: [String]?
  let languages: [LanguageCodeContainer]
  let labels: Set<ComAtprotoLabelDefs.LabelValue>
  let hashtags: [String]
  let createdAt: Date
  let threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]?
  let postgateEmbeddingRules: [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]?

  init(
    id: UUID = UUID(),
    kind: Kind,
    postText: String?,
    threadTexts: [String]?,
    languages: [LanguageCodeContainer],
    labels: Set<ComAtprotoLabelDefs.LabelValue>,
    hashtags: [String],
    createdAt: Date = Date(),
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil,
    postgateEmbeddingRules: [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]? = nil
  ) {
    self.id = id
    self.kind = kind
    self.postText = postText
    self.threadTexts = threadTexts
    self.languages = languages
    self.labels = labels
    self.hashtags = hashtags
    self.createdAt = createdAt
    self.threadgateAllowRules = threadgateAllowRules
    self.postgateEmbeddingRules = postgateEmbeddingRules
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(Kind.self, forKey: .kind)
    postText = try container.decodeIfPresent(String.self, forKey: .postText)
    threadTexts = try container.decodeIfPresent([String].self, forKey: .threadTexts)
    languages = try container.decode([LanguageCodeContainer].self, forKey: .languages)
    labels = try container.decode(Set<ComAtprotoLabelDefs.LabelValue>.self, forKey: .labels)
    hashtags = try container.decode([String].self, forKey: .hashtags)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    threadgateAllowRules = try container.decodeIfPresent([AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion].self, forKey: .threadgateAllowRules)
    postgateEmbeddingRules = try container.decodeIfPresent([AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion].self, forKey: .postgateEmbeddingRules)
  }
}

@MainActor
final class ComposerOutbox {
  static let shared = ComposerOutbox()
  private let logger = Logger(subsystem: "blue.catbird", category: "ComposerOutbox")
  private var items: [ComposerOutboxItem] = []
  private let queueURL: URL

  private init() {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    queueURL = dir.appendingPathComponent("composer_outbox.json")
    load()
  }

  func enqueuePost(
    text: String,
    languages: [LanguageCodeContainer],
    labels: Set<ComAtprotoLabelDefs.LabelValue>,
    hashtags: [String],
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil,
    postgateEmbeddingRules: [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]? = nil
  ) {
    let item = ComposerOutboxItem(
      id: UUID(),
      kind: .post,
      postText: text,
      threadTexts: nil,
      languages: languages,
      labels: labels,
      hashtags: hashtags,
      createdAt: Date(),
      threadgateAllowRules: threadgateAllowRules,
      postgateEmbeddingRules: postgateEmbeddingRules
    )
    items.append(item); persist()
    logger.info("Outbox: enqueued post len=\(text.count)")
  }

  func enqueueThread(
    texts: [String],
    languages: [LanguageCodeContainer],
    labels: Set<ComAtprotoLabelDefs.LabelValue>,
    hashtags: [String],
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil,
    postgateEmbeddingRules: [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]? = nil
  ) {
    let item = ComposerOutboxItem(
      id: UUID(),
      kind: .thread,
      postText: nil,
      threadTexts: texts,
      languages: languages,
      labels: labels,
      hashtags: hashtags,
      createdAt: Date(),
      threadgateAllowRules: threadgateAllowRules,
      postgateEmbeddingRules: postgateEmbeddingRules
    )
    items.append(item); persist()
    logger.info("Outbox: enqueued thread count=\(texts.count)")
  }

  func processAll(appState: AppState, maxItems: Int? = nil) async {
    let postManager = appState.postManager
    let processingCap = maxItems.map { max(0, $0) } ?? items.count
    let processingCount = min(processingCap, items.count)

    guard processingCount > 0 else { return }

    let pendingItems = Array(items.prefix(processingCount))
    let untouchedItems = Array(items.dropFirst(processingCount))
    var failedOrUnprocessedItems: [ComposerOutboxItem] = []

    if processingCount < items.count {
        logger.info("Outbox: processing bounded batch size=\(processingCount) remaining=\(self.items.count - processingCount)")
    }

    var index = pendingItems.startIndex
    while index < pendingItems.endIndex {
      if Task.isCancelled {
        failedOrUnprocessedItems.append(contentsOf: pendingItems[index...])
        break
      }

      let item = pendingItems[index]
      do {
        let threadgateRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]?
        let postgateRules: [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]?
        if item.threadgateAllowRules != nil || item.postgateEmbeddingRules != nil {
          threadgateRules = item.threadgateAllowRules
          postgateRules = item.postgateEmbeddingRules
        } else if let defaultPref = appState.preferencesManager.cachedPostInteractionSettingsPref() {
          let settings = PostComposerViewModel.interactionSettings(from: defaultPref)
          threadgateRules = settings.toThreadgateAllowRules()
          postgateRules = settings.toPostgateEmbeddingRules()
        } else if let pref = try? await appState.preferencesManager.getPostInteractionSettingsPref() {
          let settings = PostComposerViewModel.interactionSettings(from: pref)
          threadgateRules = settings.toThreadgateAllowRules()
          postgateRules = settings.toPostgateEmbeddingRules()
        } else {
          threadgateRules = nil
          postgateRules = nil
        }

        switch item.kind {
        case .post:
          if let text = item.postText {
            try await postManager.createPost(
              text,
              languages: item.languages,
              metadata: [:],
              hashtags: item.hashtags,
              facets: [],
              parentPost: nil,
              selfLabels: ComAtprotoLabelDefs.SelfLabels(values: item.labels.map { .init(val: $0.rawValue) }),
              embed: nil,
              threadgateAllowRules: threadgateRules,
              postgateEmbeddingRules: postgateRules
            )
          }
        case .thread:
          if let texts = item.threadTexts {
            try await postManager.createThread(
              posts: texts,
              languages: item.languages,
              selfLabels: ComAtprotoLabelDefs.SelfLabels(values: item.labels.map { .init(val: $0.rawValue) }),
              hashtags: item.hashtags,
              facets: Array(repeating: [], count: texts.count),
              embeds: Array(repeating: nil, count: texts.count),
              parentPost: nil,
              threadgateAllowRules: threadgateRules,
              postgateEmbeddingRules: postgateRules
            )
          }
        }
        logger.info("Outbox: posted item=\(item.id.uuidString)")
      } catch {
        logger.error("Outbox: failed item=\(item.id.uuidString) error=\(error.localizedDescription)")
        failedOrUnprocessedItems.append(item)
      }

      pendingItems.formIndex(after: &index)
    }

    items = failedOrUnprocessedItems + untouchedItems
    persist()
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(items)
      try data.write(to: queueURL, options: .atomic)
    } catch {
      logger.error("Outbox: persist failed: \(error.localizedDescription)")
    }
  }

  private func load() {
    do {
      let data = try Data(contentsOf: queueURL)
      items = try JSONDecoder().decode([ComposerOutboxItem].self, from: data)
    } catch { items = [] }
  }
}
