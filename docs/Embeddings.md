# On‑Device Text Embeddings in Catbird

This document explains the new on‑device text embedding architecture in Catbird: what it does, how it works, how it integrates with the feed, and proposed next steps.

## Overview

Goals:

- Provide privacy‑preserving semantic features (search, related posts, interest re‑rank) using Apple’s on‑device NLP models.
- Keep everything on device: no network calls for embedding, indexing, or ranking.
- Integrate with existing feed flow and Swift 6 concurrency patterns.

Scope (Phase 1 MVP):

- Sentence embeddings with NaturalLanguage `NLEmbedding`.
- Semantic search in the feed.
- Related posts lookup.
- Baseline “Relevant” sort (interest centroid) wiring.

## Key Components

### FeedEmbeddingActor

File: `Catbird/Features/Feed/Embeddings/FeedEmbeddingActor.swift`

- An actor that owns:
  - A small cache of loaded `NLEmbedding` models keyed by `NLLanguage`.
  - An in‑memory vector cache (`NSCache<postID, VectorWrapper>`).
  - Public APIs:
    - `embedPosts(_:)` — batch compute vectors for posts.
    - `semanticSearch(query:in:topK:)` — returns top‑K similar posts to a query.
    - `relatedPosts(for:in:topK:minCos:)` — returns nearest neighbors to a given post.
    - `vector(for:)` — retrieves a vector for a post (hydrates from disk if available).

Behavior:

- Always includes quoted text (if present) when embedding a post (improves semantics for “Check this out” quotes).
- Language detection via `NLLanguageRecognizer.dominantLanguage(for:)`, with fallback to `.english` for short/ambiguous strings.
- Uses `NLEmbedding.sentenceEmbedding(for:revision:)` per language and latest revision.
- Normalizes vectors to unit length. Cosine similarity = dot product (via Accelerate vDSP).
- Persists vectors in a SwiftData sidecar (see below) and hydrates from it on cache misses.

### EmbeddingTextExtractor

File: `Catbird/Features/Feed/Embeddings/EmbeddingTextExtractor.swift`

- Extracts post text from `CachedFeedViewPost`.
- Cleans basic noise: URLs → `[link]`, `@mentions` → `@user`, whitespace collapsed.
- Includes quoted record text by default when present.

### EmbeddingStore + CachedPostEmbedding (SwiftData)

Files:

- `Catbird/Features/Feed/Embeddings/CachedPostEmbedding.swift` — SwiftData model: `{ postID, languageCode, vectorData, timestamp }`.
- `Catbird/Features/Feed/Embeddings/EmbeddingStore.swift` — save/load/prune vectors.

Behavior:

- `save(postID, language, vector)` upserts to disk.
- `load(postID)` hydrates into memory cache on demand.
- `prune(capacity: 2500, ttlDays: 2)` time/capacity based cleanup.

### AppState and ModelContainer

Files:

- `Catbird/Core/State/AppState.swift` — holds an `EmbeddingStore?` and exposes `saveEmbedding`, `loadEmbedding`, `pruneEmbeddings` helpers.
- `Catbird/App/CatbirdApp.swift` — adds `CachedPostEmbedding.self` to `ModelContainer`; registers the store early in the main scene’s `onAppear`.

### FeedManager + FeedModel wiring

Files:

- `Catbird/Features/Feed/Services/FeedManager+Embeddings.swift` — convenience methods:
  - `precomputeEmbeddings(for:)`
  - `semanticSearch(_:in:topK:)`
  - `relatedPosts(for:in:topK:)`
- `Catbird/Features/Feed/Models/FeedModel.swift`
  - After feed loads and on `loadMore`, precomputes embeddings for newly added posts (background).
  - Public APIs for UI:
    - `semanticSearch(_:topK:)`
    - `relatedPosts(for:topK:minCos:)`
  - Baseline “Relevant” mode: computes interest centroid from liked posts (dominant language) and reorders posts by cosine(sim, centroid), keeping others afterward.

### Feed settings and UI

Files:

- `Catbird/Features/Feed/Models/FeedFilterSettings.swift`
  - Adds `FeedSortMode` (Latest | Relevant) with persistence.
- `Catbird/Features/Feed/Views/FeedView.swift`
  - Adds a feed‑local `searchable` bar (Search this feed).
  - On submit, runs semantic search and presents a compact result list at the top (interactive, dismissible).

## Data Flow

### Embedding pipeline

1. Feed posts arrive → `FeedModel` maps into `[CachedFeedViewPost]`.
2. `FeedModel` triggers background precompute:
   - `FeedManager.precomputeEmbeddings` → `FeedEmbeddingActor.embedPosts`.
   - For each post:
     - Try load vector from disk sidecar → memory cache.
     - Else extract text (root + quoted), detect language, load NL model, compute vector, normalize, save to memory and disk.

### Semantic search

1. User enters a query in the feed search bar.
2. `FeedView` calls `FeedStateManager.semanticSearch` → `FeedModel.semanticSearch`:
   - Clean query, detect language (fallback `.english`).
   - Compute normalized query vector with the appropriate `NLEmbedding`.
   - For each candidate post with a vector in the same language, compute dot product (cosine) and rank.
3. Show a result list (top‑K), tappable to navigate to posts.

### Related posts

1. For a post P, compute nearest neighbors among cached posts of the same language via cosine similarity.
2. Present top‑K related posts (UI surfacing is left for subsequent steps; API is ready).

### Relevant sort (baseline)

1. If user selects `Relevant` sort:
   - Build interest centroid from liked posts in the dominant language.
   - Normalize centroid; score posts with cosine(sim, centroid).
   - Reorder by similarity (ties by recency) while leaving other languages in original order.

## Design Notes

- On‑device only: Uses `NaturalLanguage` APIs (no network inference).
- Language handling: Partition by `NLLanguage`; search/neighbor queries compare within the same language.
- Quoted text: Default inclusion for better topical representation.
- Similarity math: Normalize vectors once; cosine = dot(q, v) via Accelerate vDSP.
- Storage:
  - Memory cache (~2–5 MB typical for ~2,500 vectors at 512 dims Float32).
  - Disk sidecar cache with TTL and capacity pruning.

## Performance and Reliability

- Compute occurs in background tasks (actor serializes work); UI thread remains free.
- vDSP used for dot products and normalization.
- Language fallback avoids early bailouts on short queries.
- Precompute happens after posts are loaded; queries hydrate on demand if vectors were evicted.

## Security & Privacy

- All embedding and ranking is on device.
- Vectors are stored inside the app container; subject to the same privacy as post content.

## Potential Improvements / Next Steps

Short‑term:

- Search UX
  - Debounced live results while typing (e.g., 300–400 ms) and loading indicator.
  - Full‑screen result view with richer cells and grouping.
- Related posts UI
  - Button in post menus/detail to open a related posts list (uses existing API).
- Model pre‑warm
  - Preload the device language model at app launch to reduce first‑use latency.
- Pruning schedule
  - Call `AppState.pruneEmbeddings()` on backgrounding and at startup.
- Quote extraction refinements
  - Append only when the parent content is semantically meaningful (heuristics), and strip noise.

Medium‑term:

- Relevant sort
  - Blend recency with similarity explicitly (e.g., `score = α·cos + (1‑α)·recencyScore`).
  - Maintain per‑language interest vectors.
- Multilingual strategy
  - Optionally allow cross‑language retrieval within Apple’s Latin model (if desired by UX), guarded by settings.
- Summaries (extractive, on‑demand)
  - MMR over thread posts; highlight selected posts as a compact summary.
- ANN / batching
  - If scaling beyond a few thousand vectors per view, consider batched GEMV or a tiny ANN index (HNSW).

Operational:

- Telemetry (local only)
  - Measure average embedding time, cache hit/miss, and search latencies to tune thresholds.
- Error states/UX
  - If the language model is missing and device is offline, present a one‑time hint that it will download automatically when possible.

## Testing & Validation

- Manual flows
  - Timeline load → background precompute should not jank scrolling.
  - Search queries return sensible results; no overlay appears when no results.
  - Relevant sort visibly prioritizes liked‑topic content.
- Unit tests (suggested)
  - Text extractor cleaning and quoted concatenation.
  - Vector normalization and cosine scoring.
  - Sidecar save/load, TTL pruning.

## File Map

- Core
  - `Catbird/Features/Feed/Embeddings/FeedEmbeddingActor.swift`
  - `Catbird/Features/Feed/Embeddings/EmbeddingTextExtractor.swift`
  - `Catbird/Features/Feed/Embeddings/CachedPostEmbedding.swift`
  - `Catbird/Features/Feed/Embeddings/EmbeddingStore.swift`
  - `Catbird/Features/Feed/Services/FeedManager+Embeddings.swift`
  - `Catbird/Core/State/AppState.swift` (store registration helpers)
  - `Catbird/App/CatbirdApp.swift` (ModelContainer + registration)
- Feed integration
  - `Catbird/Features/Feed/Models/FeedModel.swift`
  - `Catbird/Features/Feed/Models/CachedFeedViewPost.swift` (post extraction helpers)
  - `Catbird/Features/Feed/Views/FeedView.swift` (semantic search UI)
  - `Catbird/Features/Feed/Models/FeedFilterSettings.swift` (sort mode)

## Platform & API Notes

- iOS 18+ baseline; relies on NaturalLanguage `NLEmbedding` sentence embeddings.
- Language detection via `NLLanguageRecognizer`.
- Accelerate vDSP for fast dot products and normalization.

## FAQ

- Q: Why sentence embeddings and not `NLContextualEmbedding`?
  - A: `NLEmbedding.sentenceEmbedding` is higher‑level and returns a single vector per sentence with Apple’s pooling strategy. We can switch to `NLContextualEmbedding` later if we need token‑level control or custom pooling.
- Q: Why include quoted text by default?
  - A: Quote posts often have minimal original text; including the quoted content improves semantic retrieval.
- Q: Why only compare within the same language?
  - A: Apple’s models are per script/language family; vectors are not guaranteed to be comparable across models. Partitioning avoids spurious matches.

