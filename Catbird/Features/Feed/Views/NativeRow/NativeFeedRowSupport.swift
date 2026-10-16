#if os(iOS)
import Foundation
import Petrel

// MARK: - Native Feed Rows Switch

/// The kill switch for native feed rows, for A/B comparison and support. Native rows are on
/// unless the app was launched with `--native-feed-rows=off` or the `nativeFeedRowsDisabled`
/// user default is set; every post then keeps the hosted SwiftUI row.
enum NativeFeedRows {
  static var isEnabled: Bool {
    !ProcessInfo.processInfo.arguments.contains("--native-feed-rows=off")
      && !UserDefaults.standard.bool(forKey: "nativeFeedRowsDisabled")
  }
}

// MARK: - Native Feed Row Support

/// Whether a feed post renders in a native UIKit cell or keeps the SwiftUI
/// `FeedPostRow`. A post renders natively only when every feature the SwiftUI
/// row would show for it is supported natively; anything else is hosted, so a
/// native row never silently drops a feature.
enum NativeFeedRowSupport: Equatable {
  case native
  case hosted(Reason)

  /// The first unsupported feature found, in the order `classify` checks them.
  enum Reason: String, Equatable, CaseIterable, Sendable {
    case disabled, decodeFailed, recordNotPost, embed, replyContext, reason, threadSlice, rowFilter,
      pendingClassification, moderation, avatarConcealment, translationOffered, languageIndicator,
      readingTime, tags, pronouns, automated, pinned, customFacet, liveStatus, blockedAuthor
  }

  /// The inputs the classifier cannot read from the post. The device language is
  /// passed in, never read from `Locale.current`. A classification is still not a
  /// pure function of its arguments: the live-status check compares the status
  /// expiry with the current date, so the same post can classify differently
  /// once its live status lapses.
  struct Settings: Equatable, Sendable {
    let isEnabled: Bool
    /// Base language code of the device, computed as
    /// `Locale.current.language.baseLanguageCode?.lowercased() ?? "en"`, which is how
    /// `Post.swift` derives its translation target.
    let deviceLanguageCode: String
    /// The account's content languages (`appSettings.contentLanguages`).
    let preferredContentLanguages: Set<String>
    let showLanguageIndicators: Bool
    let showReadingTimeEstimates: Bool
  }
}

// MARK: - Classification Input

extension NativeFeedRowSupport {
  /// What `classify` reads from a feed entry, as values: the decoded entry and its thread and
  /// filter state. Captured on the main actor, where the SwiftData model is read, so the entry
  /// can be classified off it.
  struct Entry: Sendable {
    /// The decoded feed entry; `nil` when it does not decode.
    let item: AppBskyFeedDefs.FeedViewPost?
    let threadDisplayMode: String?
    let intentHiddenRuleText: String?
    let smartFilterCollapseRuleID: String?
    let isSmartFilterPending: Bool

    init(_ cached: CachedFeedViewPost) {
      item = try? cached.feedViewPost
      threadDisplayMode = cached.threadDisplayMode
      intentHiddenRuleText = cached.intentHiddenRuleText
      smartFilterCollapseRuleID = cached.smartFilterCollapseRuleID
      isSmartFilterPending = cached.isSmartFilterPending
    }
  }
}

// MARK: - Classification

extension NativeFeedRowSupport {
  /// Phase 1 renders only standard text posts natively. Each check mirrors the
  /// condition under which the SwiftUI row shows the feature:
  /// - embed, reply parent and repost/pin reason: `EnhancedFeedPost` (`FeedStandardThread.showsParent`,
  ///   `FeedEntryContent.isRepost` and `showsPinnedBadge`)
  /// - Smart Filter and intent states: `FeedPostRow`
  /// - moderation gates, chips, the hidden row and avatar placeholder: `PostContentLayout`
  /// - translation button, language indicator, tags and custom facets (Bluemoji): `Post`
  /// - blocked-content card: `PostView.detectPostError`; live ring: `AuthorAvatarColumn`
  /// - reading time, pronouns and the automated badge: `PostContentLayout.postHeader`
  static func classify(
    _ cached: CachedFeedViewPost, moderation: PostModerationPresentation, settings: Settings
  ) -> NativeFeedRowSupport {
    guard settings.isEnabled else { return .hosted(.disabled) }
    return classify(Entry(cached), moderation: moderation, settings: settings)
  }

  /// `classify` for an entry captured as values, which can run off the main actor. It gives the
  /// same result as classifying the cached post the entry was captured from.
  static func classify(
    _ entry: Entry, moderation: PostModerationPresentation, settings: Settings
  ) -> NativeFeedRowSupport {
    guard settings.isEnabled else { return .hosted(.disabled) }
    guard let item = entry.item else { return .hosted(.decodeFailed) }
    guard case .knownType(let record) = item.post.record, let post = record as? AppBskyFeedPost else {
      return .hosted(.recordNotPost)
    }
    if item.post.embed != nil { return .hosted(.embed) }
    if item.reason != nil { return .hosted(.reason) }
    if item.reply != nil { return .hosted(.replyContext) }
    if let mode = entry.threadDisplayMode, mode == "expanded" || mode == "collapsed" {
      return .hosted(.threadSlice)
    }
    if entry.intentHiddenRuleText != nil || entry.smartFilterCollapseRuleID != nil {
      return .hosted(.rowFilter)
    }
    if entry.isSmartFilterPending { return .hosted(.pendingClassification) }
    if showsBlockedCard(for: item.post.author) { return .hosted(.blockedAuthor) }
    if moderation.hidesRow || moderation.concealsBody || !moderation.chips.isEmpty {
      return .hosted(.moderation)
    }
    if moderation.concealsAvatar { return .hosted(.avatarConcealment) }
    if item.post.author.status?.isLiveNow == true { return .hosted(.liveStatus) }
    if item.post.viewer?.pinned == true { return .hosted(.pinned) }
    if hasCustomFacet(post) { return .hosted(.customFacet) }

    let languages = (post.langs ?? []).map { $0.lang.baseLanguageCode?.lowercased() }
    if offersTranslation(text: post.text, languages: languages, settings: settings) {
      return .hosted(.translationOffered)
    }
    if showsLanguageIndicator(languages: languages, settings: settings) { return .hosted(.languageIndicator) }
    if settings.showReadingTimeEstimates, PostReadingTime.minutes(for: post.text) != nil {
      return .hosted(.readingTime)
    }
    if post.tags?.isEmpty == false { return .hosted(.tags) }
    if let pronouns = item.post.author.pronouns, !pronouns.isEmpty { return .hosted(.pronouns) }
    if AutomationBadge.isSelfDeclared(labels: item.post.author.labels, authorDID: item.post.author.did) {
      return .hosted(.automated)
    }
    return .native
  }

  // MARK: - Conditions

  /// `Post` enriches facet features Petrel does not model (`blue.moji.richtext.facet`)
  /// into inline emoji images. `FeedPostTextBuilder` copies only link runs, so a
  /// post carrying any such feature would show its `:alias:` text instead.
  private static func hasCustomFacet(_ post: AppBskyFeedPost) -> Bool {
    post.facets?.contains { facet in
      facet.features.contains { feature in
        if case .unexpected = feature { return true }
        return false
      }
    } ?? false
  }

  /// `PostView.detectPostError` replaces the post with the blocked-content card
  /// when the author blocked the viewer. The viewer's own blocks are never
  /// shown there (`shouldShowBlockedContent` is false).
  private static func showsBlockedCard(for author: AppBskyActorDefs.ProfileViewBasic) -> Bool {
    author.viewer?.blockedBy == true
  }

  /// `Post.shouldShowTranslationButton`: a non-blank post with any language
  /// whose base code differs from the device's. A language with no base code
  /// counts as different.
  private static func offersTranslation(text: String, languages: [String?], settings: Settings) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    let device = settings.deviceLanguageCode.lowercased()
    return languages.contains { ($0 ?? "") != device }
  }

  /// `Post.indicatorLanguage`: a language that is neither the device's nor one
  /// of the account's content languages.
  private static func showsLanguageIndicator(languages: [String?], settings: Settings) -> Bool {
    guard
      PostLanguageIndicators.shouldShow(isEnabled: settings.showLanguageIndicators, languageCount: languages.count)
    else { return false }
    let device = settings.deviceLanguageCode.lowercased()
    let preferred = Set(settings.preferredContentLanguages.map { $0.lowercased() })
    return languages.contains { code in
      guard let code else { return false }
      return code != device && !preferred.contains(code)
    }
  }
}
#endif
