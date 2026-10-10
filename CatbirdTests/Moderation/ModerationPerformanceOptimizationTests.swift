import Foundation
import Petrel
import Testing

@testable import Catbird

@Suite("Moderation Performance Optimizations")
struct ModerationPerformanceOptimizationTests {

  // MARK: - Compiled Muted Word Matcher Equivalence

  @Test("Compiled muted words matcher is semantically equivalent to legacy matcher")
  func compiledMutedWordMatcherEquivalence() {
    let now = Date()
    let words = [
      MutedWord(id: "1", value: "spoiler", targets: ["content"], actorTarget: nil, expiresAt: nil),
      MutedWord(id: "2", value: "#crypto", targets: ["tag"], actorTarget: nil, expiresAt: nil),
      MutedWord(id: "3", value: "café", targets: ["content"], actorTarget: nil, expiresAt: nil),
      MutedWord(id: "4", value: "straße", targets: ["content"], actorTarget: nil, expiresAt: nil),
      MutedWord(id: "5", value: "日本語", targets: ["content"], actorTarget: nil, expiresAt: nil),
      MutedWord(id: "6", value: "blocked-friend", targets: ["content"], actorTarget: "exclude-following", expiresAt: nil),
      MutedWord(id: "7", value: "expired-word", targets: ["content"], actorTarget: nil, expiresAt: now.addingTimeInterval(-3600)),
      MutedWord(id: "8", value: "  trimmed-word  ", targets: ["content", "tag"], actorTarget: nil, expiresAt: nil),
    ]

    let compiled = MutedWordMatcher.Compiled(words: words, now: now)

    struct TestCase {
      let text: String
      let tags: [String]
      let altText: String
      let followed: Bool
      let expected: Bool
      let description: String
    }
    let cases: [TestCase] = [
      TestCase(text: "Check out this spoiler alert", tags: [], altText: "", followed: false, expected: true, description: "Basic content match"),
      TestCase(text: "Clean text", tags: ["crypto"], altText: "", followed: false, expected: true, description: "Tag match without hash in post"),
      TestCase(text: "Clean text", tags: ["#CRYPTO"], altText: "", followed: false, expected: true, description: "Tag match with hash and uppercase"),
      TestCase(text: "I went to a CAFE today", tags: [], altText: "", followed: false, expected: true, description: "Accent folding match"),
      TestCase(text: "Spaziergang auf der STRASSE", tags: [], altText: "", followed: false, expected: true, description: "German eszett match"),
      TestCase(text: "私は日本語を話します", tags: [], altText: "", followed: false, expected: true, description: "CJK match"),
      TestCase(text: "Message from blocked-friend", tags: [], altText: "", followed: true, expected: false, description: "Exclude-following followed (ignored)"),
      TestCase(text: "Message from blocked-friend", tags: [], altText: "", followed: false, expected: true, description: "Exclude-following unfollowed (matches)"),
      TestCase(text: "This has expired-word in it", tags: [], altText: "", followed: false, expected: false, description: "Expired word (omitted)"),
      TestCase(text: "Text mentions trimmed-word here", tags: [], altText: "", followed: false, expected: true, description: "Trimmed word content match"),
      TestCase(text: "Clean text", tags: ["trimmed-word"], altText: "", followed: false, expected: true, description: "Trimmed word tag match"),
      TestCase(text: "Clean text with image", tags: [], altText: "An image with spoiler description", followed: false, expected: true, description: "Alt text match"),
      TestCase(text: "Completely unrelated post", tags: ["swift", "ios"], altText: "Photo of a sunset", followed: false, expected: false, description: "No match"),
    ]

    for tc in cases {
      let compiledResult = compiled.matches(
        text: tc.text, tags: tc.tags, altText: tc.altText, authorIsFollowed: tc.followed
      )
      #expect(
        compiledResult == tc.expected,
        "Mismatch for case '\(tc.description)': expected \(tc.expected), got \(compiledResult)"
      )
    }
  }

  // MARK: - Language Filtering & Cache

  @Test("Reading language policy caches detected language per uri and cid")
  func readingLanguageDetectionCache() {
    let uri = "at://did:plc:test/app.bsky.feed.post/langtest1"
    let cid = "bafyreitestcid1"
    let text = "This is a clean English sentence with sufficient length for reliable language detection."

    // First lookup computes and caches
    let detected1 = ReadingLanguagePolicy.detectedLanguage(uri: uri, cid: cid, text: text)
    #expect(detected1 == "en")

    // Second lookup should return from cache
    let cached = DetectedLanguageCache.shared.get(uri: uri, cid: cid)
    #expect(cached.found)
    #expect(cached.language == "en")

    let detected2 = ReadingLanguagePolicy.detectedLanguage(uri: uri, cid: cid, text: text)
    #expect(detected2 == detected1)

    // Verification of allows with preferred languages
    let englishPreferred: Set<String> = ["en"]
    let spanishPreferred: Set<String> = ["es"]

    #expect(ReadingLanguagePolicy.allows(
      declaredLanguages: [], preferredBaseCodes: englishPreferred,
      uri: uri, cid: cid, text: text
    ))

    #expect(!ReadingLanguagePolicy.allows(
      declaredLanguages: [], preferredBaseCodes: spanishPreferred,
      uri: uri, cid: cid, text: text
    ))

    // When declared languages are present, detection is bypassed
    #expect(ReadingLanguagePolicy.allows(
      declaredLanguages: ["es"], preferredBaseCodes: spanishPreferred,
      uri: uri, cid: cid, text: text
    ))
  }

  // MARK: - Moderation Decision Memoization & Policy Invalidation

  @Test("Moderation decision is memoized per post and invalidated on policy generation change")
  func moderationDecisionMemoizationAndInvalidation() throws {
    let author = try ModerationFixtures.profile("alice")
    let pornLabel = try ModerationFixtures.postLabel("porn", name: "alice")
    let post = try ModerationFixtures.post(author: author, labels: [pornLabel])

    let uri = post.uri.uriString()
    let cid = post.cid.string

    // Policy 1: adult content disabled -> porn is hidden
    let policy1 = ModerationPolicy(
      accountDID: "did:web:viewer.test",
      serverAdultContentEnabled: false,
      contentLabelPrefs: [],
      labelerDIDs: [ModerationFixtures.labelerDID],
      labelerDefinitions: [:],
      isConfirmed: true
    )

    let decision1 = policy1.decide(post: post)
    #expect(decision1.ui(.contentList).filter)

    // Verify cache has the entry for policy1.generation
    let cached1 = ModerationDecisionCache.shared.decision(uri: uri, cid: cid, generation: policy1.generation)
    #expect(cached1 != nil)
    #expect(cached1?.ui(.contentList).filter == true)

    // Repeated call hits the cache
    let decision1Repeat = policy1.decide(post: post)
    #expect(decision1Repeat.ui(.contentList).filter == decision1.ui(.contentList).filter)

    // Policy 2: adult content enabled + porn set to ignore -> different generation
    let policy2 = ModerationPolicy(
      accountDID: "did:web:viewer.test",
      serverAdultContentEnabled: true,
      contentLabelPrefs: [ContentLabelPreference(labelerDid: nil, label: "porn", visibility: "ignore")],
      labelerDIDs: [ModerationFixtures.labelerDID],
      labelerDefinitions: [:],
      isConfirmed: true
    )

    #expect(policy2.generation != policy1.generation)

    // Policy 2 evaluation recomputes because generation changed
    let decision2 = policy2.decide(post: post)
    #expect(!decision2.ui(.contentList).filter)

    // Verify cache has new entry under policy2.generation
    let cached2 = ModerationDecisionCache.shared.decision(uri: uri, cid: cid, generation: policy2.generation)
    #expect(cached2 != nil)
    #expect(cached2?.ui(.contentList).filter == false)
  }

  @Test("Moderation decision memoization distinguishes different labels on same URI and CID")
  func moderationDecisionDistinguishesFingerprints() throws {
    let author = try ModerationFixtures.profile("alice")
    let pornLabel = try ModerationFixtures.postLabel("porn", name: "alice")
    let labeledPost = try ModerationFixtures.post(author: author, labels: [pornLabel])
    let plainPost = try ModerationFixtures.post(author: author, labels: nil)

    #expect(labeledPost.uri.uriString() == plainPost.uri.uriString())
    #expect(labeledPost.cid.string == plainPost.cid.string)

    let policy = ModerationPolicy(
      accountDID: "did:web:viewer.test",
      serverAdultContentEnabled: false,
      contentLabelPrefs: [],
      labelerDIDs: [ModerationFixtures.labelerDID],
      labelerDefinitions: [:],
      isConfirmed: true
    )

    let labeledDecision = policy.decide(post: labeledPost)
    #expect(labeledDecision.ui(.contentList).filter)

    // Same URI and CID with no labels must NOT return the cached labeledDecision
    let plainDecision = policy.decide(post: plainPost)
    #expect(!plainDecision.ui(.contentList).filter)
  }

  @Test("Moderation decision bypasses cache when any label has an expiration date")
  func moderationDecisionBypassesCacheForExpiringLabels() throws {
    let author = try ModerationFixtures.profile("alice")
    let futureExpiry = Date().addingTimeInterval(3600)
    let expiringLabel = try ModerationFixtures.postLabel("porn", name: "alice", exp: futureExpiry)
    let post = try ModerationFixtures.post(author: author, labels: [expiringLabel])

    let uri = post.uri.uriString()
    let cid = post.cid.string

    let policy = ModerationPolicy(
      accountDID: "did:web:viewer.test",
      serverAdultContentEnabled: false,
      contentLabelPrefs: [],
      labelerDIDs: [ModerationFixtures.labelerDID],
      labelerDefinitions: [:],
      isConfirmed: true
    )

    let decision = policy.decide(post: post)
    #expect(decision.ui(.contentList).filter)

    // The decision should NOT be stored in the cache because the label has an expiration date
    let cached = ModerationDecisionCache.shared.decision(uri: uri, cid: cid, generation: policy.generation)
    #expect(cached == nil)
  }

  @Test("Moderation decision bypasses cache for label-free post")
  func moderationDecisionBypassesCacheForLabelFreePost() throws {
    let author = try ModerationFixtures.profile("alice")
    let plainPost = try ModerationFixtures.post(author: author, labels: nil)

    let uri = plainPost.uri.uriString()
    let cid = plainPost.cid.string

    let policy = ModerationPolicy(
      accountDID: "did:web:viewer.test",
      serverAdultContentEnabled: false,
      contentLabelPrefs: [],
      labelerDIDs: [ModerationFixtures.labelerDID],
      labelerDefinitions: [:],
      isConfirmed: true
    )

    let decision = policy.decide(post: plainPost)
    #expect(!decision.ui(.contentList).filter)

    // Unlabeled post fast-paths and bypasses the cache entirely
    let cached = ModerationDecisionCache.shared.decision(uri: uri, cid: cid, generation: policy.generation)
    #expect(cached == nil)
  }

  @Test("Moderation decision cache evicts oldest entry in O(1) FIFO ring order")
  func moderationDecisionCacheO1Eviction() throws {
    let cache = ModerationDecisionCache(capacity: 2)
    let author = try ModerationFixtures.profile("alice")
    let label = try ModerationFixtures.postLabel("porn", name: "alice")
    let post = try ModerationFixtures.post(author: author, labels: [label])
    let fp = ModerationDecisionCache.PostFingerprint(post: post)

    let decision = ModerationDecision(did: "did:plc:test", isMe: false)

    cache.setDecision(decision, uri: "uri1", cid: "cid1", generation: 1, fingerprint: fp)
    cache.setDecision(decision, uri: "uri2", cid: "cid2", generation: 1, fingerprint: fp)
    #expect(cache.decision(uri: "uri1", cid: "cid1", generation: 1, fingerprint: fp) != nil)
    #expect(cache.decision(uri: "uri2", cid: "cid2", generation: 1, fingerprint: fp) != nil)

    // Inserting 3rd entry evicts uri1
    cache.setDecision(decision, uri: "uri3", cid: "cid3", generation: 1, fingerprint: fp)
    #expect(cache.decision(uri: "uri1", cid: "cid1", generation: 1, fingerprint: fp) == nil)
    #expect(cache.decision(uri: "uri2", cid: "cid2", generation: 1, fingerprint: fp) != nil)
    #expect(cache.decision(uri: "uri3", cid: "cid3", generation: 1, fingerprint: fp) != nil)
  }
}
