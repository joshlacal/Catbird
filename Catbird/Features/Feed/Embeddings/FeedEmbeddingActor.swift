import Accelerate
import Foundation
import NaturalLanguage
import OSLog
import Petrel

/// Actor responsible for computing and caching on-device sentence embeddings
/// using Apple's NaturalLanguage framework.
actor FeedEmbeddingActor {
    private let logger = Logger(subsystem: "blue.catbird", category: "Embeddings")

    // MARK: - Models & Cache

    private var models: [NLLanguage: NLEmbedding] = [:]
    private let cache = NSCache<NSString, VectorWrapper>()

    init() {
        cache.countLimit = 3000 // soft cap to keep memory bounded
    }

    // MARK: - Public API

    func embedPosts(_ posts: [CachedFeedViewPost]) async {
        for post in posts {
            await embedPostIfNeeded(post)
        }
    }

    func embedPostIfNeeded(_ post: CachedFeedViewPost) async {
        if cache.object(forKey: post.id as NSString) != nil { return }
        // Try to hydrate from disk cache first
        if let disk = await AppState.shared.loadEmbedding(postID: post.id) {
            cache.setObject(VectorWrapper(vector: disk.vector, language: disk.language), forKey: post.id as NSString)
            return
        }
        // Always include quoted text content by default for better semantics
        guard let text = EmbeddingTextExtractor.text(for: post, includeQuoted: true) else { return }

        // Language detection (reuse existing detector)
        let langCode = LanguageDetector.shared.detectLanguage(for: text)
        guard let langCode, let lang = NLLanguage(rawValue: langCode) else { return }

        guard let model = await embeddingModel(for: lang) else { return }
        guard let vectorD = model.vector(for: text) else { return }
        var v: [Float] = vectorD.map(Float.init)
        normalize(&v)
        cache.setObject(VectorWrapper(vector: v, language: lang), forKey: post.id as NSString)
        // Persist to SwiftData sidecar (on main actor)
        await AppState.shared.saveEmbedding(postID: post.id, language: lang, vector: v)
    }

    func vector(for postID: String) -> (vector: [Float], language: NLLanguage)? {
        if let w = cache.object(forKey: postID as NSString) {
            return (w.vector, w.language)
        }
        // Attempt lazy load from disk if memory cache missed
        if let disk = await AppState.shared.loadEmbedding(postID: postID) {
            cache.setObject(VectorWrapper(vector: disk.vector, language: disk.language), forKey: postID as NSString)
            return (disk.vector, disk.language)
        }
        return nil
    }

    /// Semantic search over provided posts using cosine similarity.
    /// Returns posts sorted by similarity to the query (highest first).
    func semanticSearch(query: String, in posts: [CachedFeedViewPost], topK: Int = 20) async -> [CachedFeedViewPost] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        // Detect language for query
        let langCode = LanguageDetector.shared.detectLanguage(for: cleaned)
        guard let langCode, let lang = NLLanguage(rawValue: langCode) else { return [] }
        guard let model = await embeddingModel(for: lang), let qD = model.vector(for: cleaned) else { return [] }
        var q = qD.map(Float.init)
        normalize(&q)

        // Ensure we have vectors for all candidate posts (same language only)
        var scored: [(CachedFeedViewPost, Float)] = []
        for post in posts {
            await embedPostIfNeeded(post)
            guard let (v, plang) = vector(for: post.id), plang == lang else { continue }
            let s = dot(q, v)
            scored.append((post, s))
        }

        // Sort by similarity descending and take topK
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
    }

    /// Finds related posts to a given post within the provided set (same language),
    /// ranked by cosine similarity.
    func relatedPosts(for post: CachedFeedViewPost, in posts: [CachedFeedViewPost], topK: Int = 5, minCos: Float = 0.3) async -> [CachedFeedViewPost] {
        await embedPostIfNeeded(post)
        guard let (pvec, plang) = vector(for: post.id) else { return [] }

        var scored: [(CachedFeedViewPost, Float)] = []
        for other in posts {
            if other.id == post.id { continue }
            await embedPostIfNeeded(other)
            guard let (ovec, olang) = vector(for: other.id), olang == plang else { continue }
            let s = dot(pvec, ovec)
            if s >= minCos { scored.append((other, s)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
    }

    // MARK: - Internals

    private func embeddingModel(for language: NLLanguage) async -> NLEmbedding? {
        if let m = models[language] { return m }
        let revision = NLEmbedding.currentSentenceEmbeddingRevision(for: language)
        if let m = NLEmbedding.sentenceEmbedding(for: language, revision: revision) ?? NLEmbedding.sentenceEmbedding(for: language) {
            models[language] = m
            logger.debug("Loaded sentence embedding model for \(String(describing: language.rawValue)) rev=\(revision)")
            return m
        }
        logger.debug("No sentence embedding model available for \(String(describing: language.rawValue))")
        return nil
    }

    private func normalize(_ v: inout [Float]) {
        var sum: Float = 0
        v.withUnsafeBufferPointer { buf in
            vDSP_dotpr(buf.baseAddress!, 1, buf.baseAddress!, 1, &sum, vDSP_Length(v.count))
        }
        let len = sqrtf(max(sum, 0))
        guard len > 0 else { return }
        var l = len
        v.withUnsafeMutableBufferPointer { buf in
            vDSP_vsdiv(buf.baseAddress!, 1, &l, buf.baseAddress!, 1, vDSP_Length(v.count))
        }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var d: Float = 0
        a.withUnsafeBufferPointer { ab in
            b.withUnsafeBufferPointer { bb in
                vDSP_dotpr(ab.baseAddress!, 1, bb.baseAddress!, 1, &d, vDSP_Length(a.count))
            }
        }
        return d
    }
}

private final class VectorWrapper: NSObject {
    let vector: [Float]
    let language: NLLanguage
    init(vector: [Float], language: NLLanguage) {
        self.vector = vector
        self.language = language
    }
}

/// Shared facade to access the embedding actor
enum FeedEmbeddings {
    static let shared = FeedEmbeddingActor()
}
