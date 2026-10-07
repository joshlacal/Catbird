//
//  CatbirdTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 2/14/25.
//

import Accelerate
import Catbird
import NaturalLanguage
import Petrel
import Testing
import XCTest

struct CatbirdTests {

  @Test func example() async throws {
    // Write your test here and use APIs like `#expect(...)` to check expected conditions.
  }

  // Label rendering contracts live in CatbirdTests/ModerationRendering, which
  // exercise the moderation engine with an account policy instead of the
  // former hardcoded label list.

}

// MARK: - Embedding Evaluation Harness

private struct TestPost: Decodable {
  let id: String
  let text: String
  let topic: String
}

@available(iOS 17.0, macOS 14.0, *)
struct EmbeddingEvaluationHarness {

  private func loadCorpus() throws -> [TestPost] {
    let path =
      "/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/CatbirdTests/embedding_corpus.json"
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([TestPost].self, from: data)
  }

  @Test("Run Embedding Evaluation")
  func runEvaluation() async throws {
    // 1. Load Corpus
    let corpus = try loadCorpus()

    // 2. Setup Backend & Pre-warm
    let backend = ContextualEmbeddingBackend()
    await backend.preWarm(for: .english)

    // 3. Generate Vectors
    var vectors: [String: (vector: [Float], lang: NLLanguage)] = [:]
    for post in corpus {
      if let (vec, lang) = await backend.vector(forText: post.text, preferredLanguage: .english) {
        vectors[post.id] = (vec, lang)
      }
    }

    // 4. Evaluate
    var totalPrecisionAt1: Double = 0
    var totalPrecisionAt3: Double = 0
    var queryCount: Int = 0

    for queryPost in corpus {
      guard let queryVector = vectors[queryPost.id] else { continue }

      let results =
        corpus
        .filter { $0.id != queryPost.id }
        .compactMap { candidatePost -> (post: TestPost, similarity: Float)? in
          guard let candidateVector = vectors[candidatePost.id],
            queryVector.lang == candidateVector.lang
          else { return nil }
          let similarity = vDSP.dot(queryVector.vector, candidateVector.vector)
          return (candidatePost, similarity)
        }
        .sorted { $0.similarity > $1.similarity }

      let top1 = results.prefix(1)
      let top3 = results.prefix(3)

      let precisionAt1 = calculatePrecision(retrieved: top1, expectedTopic: queryPost.topic)
      let precisionAt3 = calculatePrecision(retrieved: top3, expectedTopic: queryPost.topic)

      totalPrecisionAt1 += precisionAt1
      totalPrecisionAt3 += precisionAt3
      queryCount += 1
    }

    let avgPrecisionAt1 = totalPrecisionAt1 / Double(queryCount)
    let avgPrecisionAt3 = totalPrecisionAt3 / Double(queryCount)

    logger.debug("--- Embedding Evaluation Results ---")
    logger.debug("Corpus Size: \(corpus.count) posts")
    logger.debug("Backend: ContextualEmbeddingBackend (Mean Pooling)")
    logger.debug("Average Precision@1: \(String(format: "%.2f", avgPrecisionAt1))")
    logger.debug("Average Precision@3: \(String(format: "%.2f", avgPrecisionAt3))")
    logger.debug("------------------------------------")

    #expect(avgPrecisionAt3 > 0.5, "Average P@3 should be reasonably high")
  }

  private func calculatePrecision(
    retrieved: ArraySlice<(post: TestPost, similarity: Float)>, expectedTopic: String
  ) -> Double {
    guard !retrieved.isEmpty else { return 0.0 }
    let correctCount = retrieved.filter { $0.post.topic == expectedTopic }.count
    return Double(correctCount) / Double(retrieved.count)
  }
}
