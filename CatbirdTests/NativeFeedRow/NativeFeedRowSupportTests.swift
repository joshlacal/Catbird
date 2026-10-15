#if os(iOS)
import Foundation
import Petrel
import Testing
@testable import Catbird

// MARK: - Native Feed Row Support Tests

/// One test per reason a post stays on the SwiftUI row. A post that shows a
/// feature the native cell cannot draw must never classify as `.native`.
@MainActor
@Suite("Native feed row support")
struct NativeFeedRowSupportTests {
  private typealias F = RenderingFixtures

  private let settings = NativeFeedRowSupport.Settings(
    isEnabled: true, deviceLanguageCode: "en", preferredContentLanguages: ["en"],
    showLanguageIndicators: false, showReadingTimeEstimates: false)

  private func classify(
    _ post: CachedFeedViewPost, moderation: PostModerationPresentation = .empty,
    settings: NativeFeedRowSupport.Settings? = nil
  ) -> NativeFeedRowSupport {
    NativeFeedRowSupport.classify(post, moderation: moderation, settings: settings ?? self.settings)
  }

  /// The presentation the row derives for a post carrying `labels`, from a real policy.
  private func presentation(
    labels: [ComAtprotoLabelDefs.Label]? = nil, author: AppBskyActorDefs.ProfileViewBasic? = nil,
    policy: ModerationPolicy = F.policy()
  ) throws -> PostModerationPresentation {
    PostModerationPresentation.make(post: try F.post(author: author, labels: labels), policy: policy)
  }

  // MARK: - Native

  @Test("A plain English text post renders natively")
  func plainPostIsNative() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "hello", langs: ["en"])
    #expect(classify(post) == .native)
  }

  @Test("A post with no declared language renders natively")
  func undeclaredLanguageIsNative() throws {
    #expect(classify(try FeedRowTestPosts.cachedPost(text: "hello")) == .native)
  }

  @Test("A regional variant of the device language renders natively")
  func regionalVariantIsNative() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "hello", langs: ["en-GB"])
    #expect(classify(post) == .native)
  }

  @Test("Reading time and language indicators on do not host a short post in a preferred language")
  func enabledExtrasStayNativeWhenNotShown() throws {
    let all = NativeFeedRowSupport.Settings(
      isEnabled: true, deviceLanguageCode: "en", preferredContentLanguages: ["en"],
      showLanguageIndicators: true, showReadingTimeEstimates: true)
    let post = try FeedRowTestPosts.cachedPost(text: "hello", langs: ["en"])
    #expect(classify(post, settings: all) == .native)
  }

  @Test("Moderation with nothing to show leaves the post native")
  func emptyModerationPostIsNative() throws {
    let moderation = try presentation(labels: [try F.label("porn")], policy: F.policy(labels: ["porn": "warn"]))
    #expect(!moderation.hidesRow && !moderation.concealsBody && moderation.chips.isEmpty)
    let post = try FeedRowTestPosts.cachedPost(text: "hello", langs: ["en"])
    #expect(classify(post, moderation: moderation) == .native)
  }

  // MARK: - Disabled and undecodable

  @Test("Turning the switch off hosts every post")
  func disabledHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "hello", langs: ["en"])
    let off = NativeFeedRowSupport.Settings(
      isEnabled: false, deviceLanguageCode: "en", preferredContentLanguages: ["en"],
      showLanguageIndicators: false, showReadingTimeEstimates: false)
    #expect(classify(post, settings: off) == .hosted(.disabled))
  }

  @Test("A post whose stored data cannot be decoded is hosted")
  func decodeFailureHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "hello", langs: ["en"])
    post.serializedPost = Data("not a feed post".utf8)
    #expect(classify(post) == .hosted(.decodeFailed))
  }

  @Test("A record that is not a post is hosted")
  func foreignRecordHosts() throws {
    let post = try FeedRowTestPosts.cachedPostWithForeignRecord()
    #expect(classify(post) == .hosted(.recordNotPost))
  }

  // MARK: - Embeds, replies, reasons, threads

  @Test("Posts with an embed are hosted")
  func embedHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "look", langs: ["en"], withImageEmbed: true)
    #expect(classify(post) == .hosted(.embed))
  }

  @Test("Replies that show their parent are hosted")
  func replyHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "reply", langs: ["en"], asReply: true)
    #expect(classify(post) == .hosted(.replyContext))
  }

  @Test("Reposts are hosted")
  func repostHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "rt", langs: ["en"], asRepost: true)
    #expect(classify(post) == .hosted(.reason))
  }

  @Test("A reposted reply is hosted for its reason, which the row shows instead of the parent")
  func repostedReplyHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "rt", langs: ["en"], asReply: true, asRepost: true)
    #expect(classify(post) == .hosted(.reason))
  }

  @Test("Pins from the feed are hosted")
  func pinReasonHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "pin", langs: ["en"], asPin: true)
    #expect(classify(post) == .hosted(.reason))
  }

  @Test("A post the viewer pinned is hosted for its Pinned badge")
  func pinnedHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "pin", langs: ["en"], pinned: true)
    #expect(classify(post) == .hosted(.pinned))
  }

  @Test("Consolidated thread slices are hosted", arguments: ["expanded", "collapsed"])
  func threadSliceHosts(mode: String) throws {
    let post = try FeedRowTestPosts.cachedPost(text: "thread", langs: ["en"])
    post.threadDisplayMode = mode
    #expect(classify(post) == .hosted(.threadSlice))
  }

  @Test("A standard thread mode stays native")
  func standardThreadModeIsNative() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "thread", langs: ["en"])
    post.threadDisplayMode = "standard"
    #expect(classify(post) == .native)
  }

  // MARK: - Row filters

  @Test("Smart Filter collapse and intent rules are hosted")
  func rowFiltersHost() throws {
    let collapsed = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"])
    collapsed.smartFilterCollapseRuleID = "rule"
    #expect(classify(collapsed) == .hosted(.rowFilter))

    let intent = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"])
    intent.intentHiddenRuleText = "no politics"
    #expect(classify(intent) == .hosted(.rowFilter))
  }

  @Test("A post awaiting Smart Filter classification is hosted")
  func pendingHosts() throws {
    let pending = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"])
    pending.isSmartFilterPending = true
    #expect(classify(pending) == .hosted(.pendingClassification))
  }

  // MARK: - Moderation

  @Test("A filtered post renders as the hidden row, so it is hosted")
  func hiddenRowHosts() throws {
    let moderation = try presentation(labels: [try F.label("!hide")])
    #expect(moderation.hidesRow)
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"])
    #expect(classify(post, moderation: moderation) == .hosted(.moderation))
  }

  @Test("A blurred body is hosted")
  func bodyBlurHosts() throws {
    let moderation = try presentation(labels: [try F.label("!warn")])
    #expect(moderation.body.blur)
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"])
    #expect(classify(post, moderation: moderation) == .hosted(.moderation))
  }

  @Test("Label chips are hosted")
  func chipsHost() throws {
    let moderation = try presentation(
      labels: [try F.label("custom", src: F.customLabelerDID)],
      policy: F.customLabelerPolicy(blurs: "none", severity: "alert"))
    #expect(!moderation.chips.isEmpty)
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"])
    #expect(classify(post, moderation: moderation) == .hosted(.moderation))
  }

  @Test("An author who blocked the viewer shows the blocked card, so the post is hosted")
  func blockedByAuthorHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"], authorBlockedViewer: true)
    #expect(classify(post) == .hosted(.moderation))
  }

  @Test("A concealed avatar is hosted")
  func avatarConcealmentHosts() throws {
    let author = try F.profile(labels: [try F.accountLabel("porn")])
    let moderation = try presentation(
      author: author, policy: F.policy(labels: ["porn": "warn", "sexual": "warn", "nudity": "warn", "graphic-media": "warn"]))
    #expect(moderation.concealsAvatar)
    #expect(!moderation.hidesRow && !moderation.concealsBody && moderation.chips.isEmpty)
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"])
    #expect(classify(post, moderation: moderation) == .hosted(.avatarConcealment))
  }

  @Test("An author who is live shows the avatar ring, so the post is hosted")
  func liveAuthorHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"], authorIsLive: true)
    #expect(classify(post) == .hosted(.avatarConcealment))
  }

  // MARK: - Language

  @Test("Posts offering translation are hosted")
  func translationHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "bonjour", langs: ["fr"])
    #expect(classify(post) == .hosted(.translationOffered))
  }

  @Test("Any declared language that differs from the device offers translation")
  func mixedLanguagesOfferTranslation() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "hello bonjour", langs: ["en", "fr"])
    #expect(classify(post) == .hosted(.translationOffered))
  }

  @Test("The device language decides, not the account's content languages")
  func deviceLanguageDecidesTranslation() throws {
    let french = NativeFeedRowSupport.Settings(
      isEnabled: true, deviceLanguageCode: "fr", preferredContentLanguages: ["en"],
      showLanguageIndicators: false, showReadingTimeEstimates: false)
    let post = try FeedRowTestPosts.cachedPost(text: "bonjour", langs: ["fr-CA"])
    #expect(classify(post, settings: french) == .native)
    let english = try FeedRowTestPosts.cachedPost(text: "hello", langs: ["en"])
    #expect(classify(english, settings: french) == .hosted(.translationOffered))
  }

  @Test("A blank post offers no translation")
  func blankPostOffersNoTranslation() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "  \n", langs: ["fr"])
    #expect(classify(post) == .native)
  }

  @Test("A language indicator on a blank post is hosted")
  func languageIndicatorHosts() throws {
    let indicators = NativeFeedRowSupport.Settings(
      isEnabled: true, deviceLanguageCode: "en", preferredContentLanguages: ["en"],
      showLanguageIndicators: true, showReadingTimeEstimates: false)
    let post = try FeedRowTestPosts.cachedPost(text: "", langs: ["fr"])
    #expect(classify(post, settings: indicators) == .hosted(.languageIndicator))
    #expect(classify(post) == .native, "with indicators off the blank post shows nothing")
  }

  @Test("A language the account reads shows no indicator")
  func preferredLanguageShowsNoIndicator() throws {
    let indicators = NativeFeedRowSupport.Settings(
      isEnabled: true, deviceLanguageCode: "en", preferredContentLanguages: ["fr"],
      showLanguageIndicators: true, showReadingTimeEstimates: false)
    let post = try FeedRowTestPosts.cachedPost(text: "", langs: ["fr"])
    #expect(classify(post, settings: indicators) == .native)
  }

  // MARK: - Header and footer extras

  @Test("Posts with tags are hosted")
  func tagsHost() throws {
    let tagged = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"], tags: ["swift"])
    #expect(classify(tagged) == .hosted(.tags))
  }

  @Test("A long post is hosted for its reading time when the setting is on")
  func readingTimeHosts() throws {
    let long = try FeedRowTestPosts.cachedPost(text: String(repeating: "word ", count: 220), langs: ["en"])
    let reading = NativeFeedRowSupport.Settings(
      isEnabled: true, deviceLanguageCode: "en", preferredContentLanguages: ["en"],
      showLanguageIndicators: false, showReadingTimeEstimates: true)
    #expect(classify(long, settings: reading) == .hosted(.readingTime))
    #expect(classify(long) == .native, "with the setting off the label is not shown")
  }

  @Test("Authors with pronouns are hosted")
  func pronounsHost() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"], pronouns: "they/them")
    #expect(classify(post) == .hosted(.pronouns))
  }

  @Test("Empty pronouns show nothing")
  func emptyPronounsAreNative() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"], pronouns: "")
    #expect(classify(post) == .native)
  }

  @Test("Self-declared automated accounts are hosted")
  func automatedHosts() throws {
    let post = try FeedRowTestPosts.cachedPost(text: "x", langs: ["en"], selfDeclaredBot: true)
    #expect(classify(post) == .hosted(.automated))
  }
}
#endif
