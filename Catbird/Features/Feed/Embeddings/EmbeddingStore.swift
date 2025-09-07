import Foundation
import SwiftData
import NaturalLanguage
import OSLog

/// SwiftData-backed persistence for embeddings
@MainActor
final class EmbeddingStore {
    private let logger = Logger(subsystem: "blue.catbird", category: "EmbeddingStore")
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func save(postID: String, language: NLLanguage, vector: [Float]) {
        do {
            let ctx = ModelContext(container)
            // Upsert
            if let existing = try fetch(postID: postID, in: ctx) {
                existing.languageCode = language.rawValue
                existing.vectorData = Data(buffer: UnsafeBufferPointer(start: vector, count: vector.count))
                existing.timestamp = Date()
                try ctx.save()
                return
            }
            let data = Data(buffer: UnsafeBufferPointer(start: vector, count: vector.count))
            let rec = CachedPostEmbedding(postID: postID, languageCode: language.rawValue, vectorData: data, timestamp: Date())
            ctx.insert(rec)
            try ctx.save()
        } catch {
            logger.error("Failed to save embedding for \(postID): \(error.localizedDescription)")
        }
    }

    func load(postID: String) -> (vector: [Float], language: NLLanguage)? {
        do {
            let ctx = ModelContext(container)
            if let rec = try fetch(postID: postID, in: ctx) {
                let count = rec.vectorData.count / MemoryLayout<Float>.size
                let vec = rec.vectorData.withUnsafeBytes { ptr -> [Float] in
                    let bp = ptr.bindMemory(to: Float.self)
                    return Array(bp)
                }
                guard vec.count == count else { return nil }
                let lang = NLLanguage(rawValue: rec.languageCode)
                return (vec, lang)
            }
        } catch {
            logger.error("Failed to load embedding for \(postID): \(error.localizedDescription)")
        }
        return nil
    }

    func prune(capacity: Int = 2500, ttlDays: Int = 2) {
        do {
            let ctx = ModelContext(container)
            // Delete old entries by TTL first
            let cutoff = Date().addingTimeInterval(-Double(ttlDays) * 24 * 3600)
            let fetchOld = FetchDescriptor<CachedPostEmbedding>(predicate: #Predicate { $0.timestamp < cutoff })
            if let olds = try? ctx.fetch(fetchOld) {
                for rec in olds { ctx.delete(rec) }
            }
            try ctx.save()

            // Enforce capacity by deleting oldest
            let fetchAll = FetchDescriptor<CachedPostEmbedding>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            let all = try ctx.fetch(fetchAll)
            if all.count > capacity {
                for rec in all.suffix(from: capacity) { ctx.delete(rec) }
                try ctx.save()
            }
        } catch {
            logger.error("Failed to prune embeddings: \(error.localizedDescription)")
        }
    }

    private func fetch(postID: String, in ctx: ModelContext) throws -> CachedPostEmbedding? {
        let desc = FetchDescriptor<CachedPostEmbedding>(predicate: #Predicate { $0.postID == postID })
        return try ctx.fetch(desc).first
    }
}

