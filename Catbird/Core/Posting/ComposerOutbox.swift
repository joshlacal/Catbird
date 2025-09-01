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

  func enqueuePost(text: String, languages: [LanguageCodeContainer], labels: Set<ComAtprotoLabelDefs.LabelValue>, hashtags: [String]) {
    let item = ComposerOutboxItem(id: UUID(), kind: .post, postText: text, threadTexts: nil, languages: languages, labels: labels, hashtags: hashtags, createdAt: Date())
    items.append(item); persist()
    logger.info("Outbox: enqueued post len=\(text.count)")
  }

  func enqueueThread(texts: [String], languages: [LanguageCodeContainer], labels: Set<ComAtprotoLabelDefs.LabelValue>, hashtags: [String]) {
    let item = ComposerOutboxItem(id: UUID(), kind: .thread, postText: nil, threadTexts: texts, languages: languages, labels: labels, hashtags: hashtags, createdAt: Date())
    items.append(item); persist()
    logger.info("Outbox: enqueued thread count=\(texts.count)")
  }

  func processAll(appState: AppState) async {
    let postManager = appState.postManager
    var remaining: [ComposerOutboxItem] = []
    for item in items {
      do {
        switch item.kind {
        case .post:
          if let text = item.postText {
            try await postManager.createPost(text, languages: item.languages, metadata: [:], hashtags: item.hashtags, facets: [], parentPost: nil, selfLabels: ComAtprotoLabelDefs.SelfLabels(values: item.labels.map { .init(val: $0.rawValue) }), embed: nil, threadgateAllowRules: nil)
          }
        case .thread:
          if let texts = item.threadTexts {
            try await postManager.createThread(posts: texts, languages: item.languages, selfLabels: ComAtprotoLabelDefs.SelfLabels(values: item.labels.map { .init(val: $0.rawValue) }), hashtags: item.hashtags, facets: Array(repeating: [], count: texts.count), embeds: Array(repeating: nil, count: texts.count), threadgateAllowRules: nil)
          }
        }
        logger.info("Outbox: posted item=\(item.id.uuidString)")
      } catch {
        logger.error("Outbox: failed item=\(item.id.uuidString) error=\(error.localizedDescription)")
        remaining.append(item) // keep for retry
      }
    }
    items = remaining
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

