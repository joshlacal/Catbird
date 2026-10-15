#if os(iOS)
import Foundation
import Petrel

// MARK: - Native Feed Row Support

/// Whether a feed post renders in a native UIKit cell or keeps the SwiftUI
/// `FeedPostRow`. A post renders natively only when every feature the SwiftUI
/// row would show for it is supported natively; anything else is hosted, so a
/// native row never silently drops a feature.
enum NativeFeedRowSupport: Equatable {
  case native
  case hosted(Reason)

  /// The first unsupported feature found, in the order `classify` checks them.
  enum Reason: String, Equatable {
    case disabled, decodeFailed, recordNotPost, embed, replyContext, reason, threadSlice, rowFilter,
      pendingClassification, moderation, avatarConcealment, translationOffered, languageIndicator,
      readingTime, tags, pronouns, automated, pinned
  }

  /// The inputs the classifier cannot read from the post. The device language is
  /// passed in, never read from `Locale.current`, so a classification is a pure
  /// function of its arguments.
  struct Settings: Equatable, Sendable {
    let isEnabled: Bool
    /// Base language code of the device (`Locale.current.language.languageCode`).
    let deviceLanguageCode: String
    /// The account's content languages (`appSettings.contentLanguages`).
    let preferredContentLanguages: Set<String>
    let showLanguageIndicators: Bool
    let showReadingTimeEstimates: Bool
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
  /// - translation button, language indicator and tags: `Post`
  /// - reading time, pronouns and the automated badge: `PostContentLayout.postHeader`
  static func classify(
    _ cached: CachedFeedViewPost, moderation: PostModerationPresentation, settings: Settings
  ) -> NativeFeedRowSupport {
    guard settings.isEnabled else { return .hosted(.disabled) }
    guard let item = try? cached.feedViewPost else { return .hosted(.decodeFailed) }
    guard case .knownType(let record) = item.post.record, let post = record as? AppBskyFeedPost else {
      return .hosted(.recordNotPost)
    }
    if item.post.embed != nil { return .hosted(.embed) }
    if item.reason != nil { return .hosted(.reason) }
    if item.reply != nil { return .hosted(.replyContext) }
    if let mode = cached.threadDisplayMode, mode == "expanded" || mode == "collapsed" {
      return .hosted(.threadSlice)
    }
    if cached.intentHiddenRuleText != nil || cached.smartFilterCollapseRuleID != nil {
      return .hosted(.rowFilter)
    }
    if cached.isSmartFilterPending { return .hosted(.pendingClassification) }
    if showsBlockedCard(for: item.post.author) { return .hosted(.moderation) }
    if moderation.hidesRow || moderation.concealsBody || !moderation.chips.isEmpty {
      return .hosted(.moderation)
    }
    if moderation.concealsAvatar || item.post.author.status?.isLiveNow == true {
      return .hosted(.avatarConcealment)
    }
    if item.post.viewer?.pinned == true { return .hosted(.pinned) }

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
