import Foundation
import Petrel

/// Every viewer-local input that changes what `TrendingTopicPreviewPolicy.select` returns
/// for the same cached posts. Equal tokens mean a memoized selection is still current.
struct TopicPreviewContextToken: Equatable {
  var viewerDID = ""
  var mutedUsers: Set<String> = []
  var blockedUsers: Set<String> = []
  var hiddenPosts: Set<String> = []
  var mutedWords: [MutedWord] = []
  var feedPreference: FeedViewPreference?
  var filters = FeedFilterSettings.ActiveFilterSignature()
  var contentLanguages: [String] = []
  var hidesNonPreferredLanguages = false
  var externalMediaConsents: [ExternalMediaConsent] = []
}

extension AppState {
  /// One evaluation per render: preferences are read once and the preview is selected at most once,
  /// then reused as the participant fallback. `participants` is nil when `actors` is nil.
  @MainActor
  func topicArtwork(
    for link: String,
    actors: [AppBskyActorDefs.ProfileViewBasic]?
  ) -> (preview: TrendingTopicPreview, participants: [TrendingTopicPreview.Participant]?) {
    guard let inputs = topicPreviewInputs() else { return (TrendingTopicPreview(), actors.map { _ in [] }) }
    var context: TrendingTopicPreviewPolicy.Context?
    let preview = trendingTopicMediaStore.preview(key: inputs.labelers + "|" + link, token: inputs.token) {
      let built = topicPreviewContext(inputs.token)
      context = built
      return built
    }
    guard let actors else { return (preview, nil) }
    let participants = TrendingTopicPreviewPolicy.participants(actors: actors, fallback: preview.participants,
      context: context ?? topicPreviewContext(inputs.token))
    return (preview, participants)
  }

  /// Reads every moderation input once. Nil whenever previews are not permitted.
  @MainActor
  private func topicPreviewInputs() -> (labelers: String, token: TopicPreviewContextToken)? {
    guard !isAccountSwitchSuspended, appSettings.showTrendingTopics,
          let preferences = try? preferencesManager.getLocalPreferences() else { return nil }
    let labelers = preferences.labelers.map { $0.did.didString() }
    guard TrendingTopicPreviewPolicy.permitsLabelerScope(local: labelers,
      applied: preferencesManager.appliedAcceptLabelerDIDs) else { return nil }
    let token = TopicPreviewContextToken(
      viewerDID: userDID,
      mutedUsers: graphManager.muteCache,
      blockedUsers: graphManager.blockCache,
      hiddenPosts: postHidingManager.hiddenPosts,
      mutedWords: preferences.mutedWords,
      feedPreference: preferences.feedViewPref,
      filters: feedFilterSettings.activeFilterSignature,
      contentLanguages: appSettings.contentLanguages,
      hidesNonPreferredLanguages: appSettings.hideNonPreferredLanguages,
      externalMediaConsents: ExternalMediaProvider.allCases.map { appSettings.externalMediaConsent(for: $0) }
    )
    return (labelers.sorted().joined(separator: ","), token)
  }

  @MainActor
  private func topicPreviewContext(_ token: TopicPreviewContextToken) -> TrendingTopicPreviewPolicy.Context {
    let filters = feedFilterSettings.activeFilters
    let languageFilter = LanguageFilterProcessor(contentLanguages: token.contentLanguages)
    let consents = Dictionary(uniqueKeysWithValues: zip(ExternalMediaProvider.allCases, token.externalMediaConsents))
    return TrendingTopicPreviewPolicy.Context(
      mutedUsers: token.mutedUsers,
      blockedUsers: token.blockedUsers,
      hiddenPosts: token.hiddenPosts,
      mutedWords: token.mutedWords,
      feedPreference: token.feedPreference,
      currentUserDID: token.viewerDID,
      allowsExternal: { url in
        guard let provider = TrendingTopicExternalMediaPolicy.provider(for: url) else { return true }
        return consents[provider] != .hide
      },
      allowsPost: { item in
        filters.allSatisfy { $0.filterBlock(item) }
          && (!token.hidesNonPreferredLanguages || languageFilter.process(post: item))
      }
    )
  }
}
