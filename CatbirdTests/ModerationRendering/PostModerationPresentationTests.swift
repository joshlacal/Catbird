import Foundation
import Petrel
import Testing

@testable import Catbird

// What a feed row, thread anchor and quote card derive from the engine. These
// are the rules the views render; nothing here touches SwiftUI.

@Suite("Moderation rendering: post presentation")
struct PostModerationPresentationTests {
  private typealias F = RenderingFixtures

  /// Adult content on with every media label set to warn, so no media label
  /// filters a post and the text/media split is observable on its own.
  private let warnEverything = F.policy(labels: ["porn": "warn", "sexual": "warn", "nudity": "warn", "graphic-media": "warn"])

  // MARK: - Media labels blur media only

  @Test("A text-only post with a media label keeps its text visible and shows no warning", arguments: [
    "porn", "sexual", "nudity", "graphic-media",
  ])
  func mediaLabelOnTextOnlyPost(value: String) throws {
    let post = try F.post(labels: [try F.label(value)])
    let presentation = PostModerationPresentation.make(post: post, policy: warnEverything)
    #expect(!presentation.isFilteredFromList)
    #expect(!presentation.concealsBody, "\(value) must not hide the post body")
    #expect(presentation.chips.isEmpty, "\(value) adds no chip; the media gate is the only warning")
  }

  @Test("An image post with a media label shows one media gate and nothing else", arguments: [
    ("porn", "Adult Content"), ("sexual", "Adult Content"), ("nudity", "Non-sexual Nudity"), ("graphic-media", "Graphic Media"),
  ])
  func mediaLabelOnImagePost(value: String, title: String) throws {
    let post = try F.post(labels: [try F.label(value)], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: warnEverything)
    #expect(presentation.concealsMedia)
    #expect(!presentation.concealsBody)
    #expect(!presentation.concealsAvatar)
    #expect(presentation.chips.isEmpty)
    #expect(presentation.media.blurs.count == 1)
    #expect(!presentation.media.noOverride)
    #expect(ModerationPresentation.title(for: presentation.media) == title)
  }

  // MARK: - Adult content off

  @Test("Adult off: a porn image post is filtered from lists; rendered anyway it is a hidden row whose media stays locked")
  func adultOffPornImage() throws {
    let post = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy(adult: false))
    #expect(presentation.isFilteredFromList)
    #expect(presentation.hidesRow)
    #expect(presentation.hiddenRowCause?.label.val == "porn")
    // The row may be shown (as upstream's PostHider does), but the media gate behind it has no Show.
    #expect(presentation.hiddenRowAllowsReveal)
    #expect(!presentation.concealsBody, "the text is not what adult-off hides")
    #expect(presentation.concealsMedia)
    #expect(presentation.media.noOverride)
    #expect(presentation.media.blurs.first?.isAdultContentDisabled == true)
    #expect(ModerationGateText.explanation(for: presentation.media).contains("bsky.app"))
  }

  @Test("Adult off: the thread anchor keeps its text and locks only the media")
  func adultOffThreadAnchor() throws {
    let post = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy(adult: false), surface: .contentView)
    #expect(!presentation.concealsBody)
    #expect(presentation.chips.isEmpty)
    #expect(presentation.concealsMedia)
    #expect(presentation.media.noOverride)
  }

  @Test("Adult on with porn hidden: the post is filtered and its media gate still offers Show after reveal")
  func hideSettingFiltersButIsRevealable() throws {
    let post = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy(adult: true))
    #expect(presentation.isFilteredFromList)
    #expect(presentation.hiddenRowAllowsReveal)
    #expect(presentation.concealsMedia)
    #expect(!presentation.media.noOverride)
  }

  // MARK: - Post-level restrictions

  @Test("A !warn label on a text post gates the body with Show")
  func warnLabelGatesBody() throws {
    let post = try F.post(labels: [try F.label("!warn")])
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy())
    #expect(!presentation.isFilteredFromList)
    #expect(presentation.concealsBody)
    #expect(!presentation.body.noOverride)
    #expect(!presentation.concealsMedia)
    #expect(presentation.chips.isEmpty)
    #expect(ModerationPresentation.title(for: presentation.body) == "Content Warning")
  }

  @Test("A !hide label filters the post and the hidden row has no Show")
  func hideLabelLocksRow() throws {
    let post = try F.post(labels: [try F.label("!hide")])
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy())
    #expect(presentation.isFilteredFromList)
    #expect(!presentation.hiddenRowAllowsReveal)
    #expect(presentation.concealsBody)
    #expect(presentation.body.noOverride)
    #expect(ModerationGateText.explanation(for: presentation.body) == "This content was hidden by the moderators.")
  }

  @Test("An account labelled !warn gates the body and hides the avatar")
  func accountWarnGatesBodyAndAvatar() throws {
    let author = try F.profile(labels: [try F.accountLabel("!warn")])
    let post = try F.post(author: author)
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy())
    #expect(presentation.concealsBody)
    #expect(presentation.concealsAvatar)
    #expect(!presentation.concealsMedia)
    #expect(presentation.chips.isEmpty)
  }

  @Test("An author with a porn account label gets a placeholder avatar and nothing else on the post")
  func accountMediaLabelHidesAvatarOnly() throws {
    let author = try F.profile(labels: [try F.accountLabel("porn")])
    let post = try F.post(author: author)
    let presentation = PostModerationPresentation.make(post: post, policy: warnEverything)
    #expect(presentation.concealsAvatar)
    #expect(!presentation.concealsBody)
    #expect(!presentation.concealsMedia)
    #expect(!presentation.isFilteredFromList)
  }

  // MARK: - Custom labelers

  @Test("A labeler's blurs:content label gates the body; blurs:media gates the media; blurs:none is a chip")
  func customLabelerBlurs() throws {
    let label = try F.label("custom", src: F.customLabelerDID)
    let post = try F.post(labels: [label], embed: F.imageEmbed)

    let content = PostModerationPresentation.make(post: post, policy: F.customLabelerPolicy(blurs: "content", severity: "alert"))
    #expect(content.concealsBody)
    #expect(!content.concealsMedia)
    #expect(content.chips.isEmpty, "the gate already names the cause")

    let media = PostModerationPresentation.make(post: post, policy: F.customLabelerPolicy(blurs: "media", severity: "alert"))
    #expect(!media.concealsBody)
    #expect(media.concealsMedia)
    #expect(media.chips.isEmpty)

    let none = PostModerationPresentation.make(post: post, policy: F.customLabelerPolicy(blurs: "none", severity: "alert"))
    #expect(!none.concealsBody)
    #expect(!none.concealsMedia)
    #expect(none.chips.map(\.label.val) == ["custom"])
  }

  @Test("On the thread anchor a blurs:content alert label becomes a chip rather than a gate")
  func customContentLabelOnAnchorIsAChip() throws {
    let post = try F.post(labels: [try F.label("custom", src: F.customLabelerDID)])
    let presentation = PostModerationPresentation.make(
      post: post, policy: F.customLabelerPolicy(blurs: "content", severity: "alert"), surface: .contentView)
    #expect(!presentation.concealsBody)
    #expect(presentation.chips.map(\.label.val) == ["custom"])
  }

  @Test("An alert label set to Hide keeps its chip on the thread anchor, and loses it only to the hidden row")
  func hideSettingAlertKeepsChipWhereNoRowHidesIt() throws {
    let post = try F.post(labels: [try F.label("custom", src: F.customLabelerDID)])
    let hide = F.customLabelerPolicy(blurs: "none", severity: "alert", labels: ["custom": "hide"])

    let anchor = PostModerationPresentation.make(post: post, policy: hide, surface: .contentView)
    #expect(anchor.isFilteredFromList, "the hide setting still filters lists")
    #expect(!anchor.concealsBody)
    #expect(anchor.chips.map(\.label.val) == ["custom"], "ThreadItemAnchor renders PostAlerts regardless of the list filter")

    let row = PostModerationPresentation.make(post: post, policy: hide)
    #expect(row.hidesRow)
    #expect(row.chips.isEmpty, "the hidden row already names the cause")

    let ownProfile = PostModerationPresentation.make(post: post, policy: hide, listFilterExemptDID: F.authorDID)
    #expect(!ownProfile.hidesRow)
    #expect(ownProfile.chips.map(\.label.val) == ["custom"])
  }

  @Test("A label from an unsubscribed labeler has no effect")
  func unsubscribedLabelerIgnored() throws {
    let post = try F.post(labels: [try F.label("!hide", src: "did:web:stranger.test")], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy())
    #expect(presentation.decision.isEmpty)
    #expect(!presentation.isFilteredFromList)
    #expect(!presentation.concealsBody)
    #expect(!presentation.concealsMedia)
    #expect(presentation.chips.isEmpty)
  }

  // MARK: - Quotes

  @Test("A quoted porn image never blurs the parent; the quote gates its media; adult off filters the parent")
  func quotedPornImage() throws {
    let quoted = try F.quoted(labels: [try F.label("porn", uri: F.quotedURI)], withImage: true)
    let parent = try F.post(quote: quoted)

    let parentPresentation = PostModerationPresentation.make(post: parent, policy: warnEverything)
    #expect(!parentPresentation.concealsBody)
    #expect(!parentPresentation.concealsMedia)
    #expect(!parentPresentation.isFilteredFromList)
    #expect(parentPresentation.chips.isEmpty)

    let quotePresentation = PostModerationPresentation.make(quoted: quoted, policy: warnEverything)
    #expect(quotePresentation.concealsMedia)
    #expect(!quotePresentation.concealsBody)
    #expect(!quotePresentation.isFilteredFromList, "quotes are never list-filtered on their own")

    let adultOff = PostModerationPresentation.make(post: parent, policy: F.policy(adult: false))
    #expect(adultOff.isFilteredFromList, "the downgraded quote cause still filters the parent from lists")
    #expect(!adultOff.hidesRow, "rendered on a thread or profile, the parent shows with the quote card gated")
    #expect(adultOff.hiddenRowCause == nil)
    #expect(!adultOff.concealsBody)
    #expect(!adultOff.concealsMedia)
    #expect(PostModerationPresentation.make(quoted: quoted, policy: F.policy(adult: false)).media.noOverride)
  }

  @Test("A row whose only filter is inherited from a quote is not a hidden row, even for a quoted !hide")
  func inheritedFilterDoesNotHideRow() throws {
    let quoted = try F.quoted(labels: [try F.label("!hide", uri: F.quotedURI)])
    let parent = try F.post(quote: quoted)
    let presentation = PostModerationPresentation.make(post: parent, policy: F.policy())
    #expect(presentation.isFilteredFromList, "feeds drop it, as the upstream feed query does")
    #expect(!presentation.hidesRow)
    #expect(!presentation.concealsBody)
    #expect(presentation.chips.isEmpty)
    let quote = PostModerationPresentation.make(quoted: quoted, policy: F.policy())
    #expect(quote.concealsBody)
    #expect(quote.body.noOverride)
  }

  @Test("quotedRecord finds the quoted post behind a record embed and a record-with-media embed")
  func quotedRecordLookup() throws {
    let quoted = try F.quoted()
    #expect(PostModerationPresentation.quotedRecord(in: try F.post(quote: quoted))?.uri.uriString() == F.quotedURI)
    #expect(PostModerationPresentation.quotedRecord(in: try F.post(quote: quoted, quoteWithMedia: true))?.uri.uriString() == F.quotedURI)
    #expect(PostModerationPresentation.quotedRecord(in: try F.post(embed: F.imageEmbed)) == nil)
    #expect(PostModerationPresentation.quotedRecord(in: try F.post()) == nil)
  }

  @Test("A quoted author's !warn account label gates the quote body and avatar, not the parent")
  func quotedAuthorWarn() throws {
    let quoted = try F.quoted(authorLabels: [try F.accountLabel("!warn", did: F.quotedAuthorDID)])
    let parent = try F.post(quote: quoted)
    let quotePresentation = PostModerationPresentation.make(quoted: quoted, policy: F.policy())
    #expect(quotePresentation.concealsBody)
    #expect(quotePresentation.concealsAvatar)
    let parentPresentation = PostModerationPresentation.make(post: parent, policy: F.policy())
    #expect(!parentPresentation.concealsBody)
    #expect(!parentPresentation.concealsAvatar)
  }

  // MARK: - Profile owner exemption

  @Test("The profile being viewed keeps its own filtered posts; other authors are still filtered")
  func profileOwnerExemption() throws {
    let post = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    let policy = F.policy(adult: false)
    let onOwnProfile = PostModerationPresentation.make(post: post, policy: policy, listFilterExemptDID: F.authorDID)
    #expect(!onOwnProfile.isFilteredFromList)
    #expect(onOwnProfile.concealsMedia, "the exemption lifts only the list filter")
    #expect(onOwnProfile.media.noOverride)
    let elsewhere = PostModerationPresentation.make(post: post, policy: policy, listFilterExemptDID: F.quotedAuthorDID)
    #expect(elsewhere.isFilteredFromList)
  }

  // MARK: - Self-labels

  @Test("A record self-label the AppView has not merged still gates the media")
  func unmergedSelfLabel() throws {
    let post = try F.post(selfLabels: ["porn"], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: warnEverything)
    #expect(presentation.concealsMedia)
    #expect(presentation.media.blurs.first?.source == .user)
    #expect(presentation.media.blurs.first?.label.uri.uriString() == F.postURI)
  }

  @Test("A self-label already merged by the AppView is not counted twice")
  func mergedSelfLabelCountedOnce() throws {
    let merged = try F.label("porn", src: F.authorDID)
    let post = try F.post(labels: [merged], selfLabels: ["porn"], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: warnEverything)
    #expect(presentation.media.blurs.count == 1)
  }

  @Test("A self-applied !warn is ignored, as the engine refuses no-self labels")
  func selfAppliedSystemLabelIgnored() throws {
    let post = try F.post(selfLabels: ["!warn"])
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy())
    #expect(!presentation.concealsBody)
    #expect(presentation.decision.isEmpty)
  }

  // MARK: - One warning per subject

  @Test("Two body blurs show one gate and no chips; the same cause never repeats as a chip")
  func noDuplicateWarnings() throws {
    let author = try F.profile(labels: [try F.accountLabel("!warn")])
    let post = try F.post(author: author, labels: [try F.label("!warn")], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy())
    #expect(presentation.body.blurs.count == 2)
    #expect(presentation.chips.isEmpty)
    #expect(!presentation.concealsMedia)
  }

  @Test("The hidden row names the post's own filter, never one inherited from a quote")
  func hiddenRowNamesOwnCause() throws {
    let quoted = try F.quoted(labels: [try F.label("!hide", uri: F.quotedURI)])
    let post = try F.post(labels: [try F.label("porn")], quote: quoted)
    let presentation = PostModerationPresentation.make(post: post, policy: F.policy(adult: false))
    #expect(presentation.isFilteredFromList)
    #expect(presentation.hidesRow)
    #expect(presentation.hiddenRowCause?.label.val == "porn")
    #expect(presentation.hiddenRowCause?.downgraded == false)
  }
}

// MARK: - Reveal state

/// The reveal a gate keeps: it is for one set of causes, so a different set
/// is concealed again even when the hosting view is reused for another post.
@Suite("Moderation rendering: reveal state")
struct ModerationRevealStateTests {
  private typealias F = RenderingFixtures

  private func bodyUI(_ labels: [ComAtprotoLabelDefs.Label], author: AppBskyActorDefs.ProfileViewBasic? = nil) throws -> ModerationUI {
    try PostModerationPresentation.make(post: F.post(author: author, labels: labels), policy: F.policy()).body
  }

  @Test("A reveal applies to the causes it was given and ends on Hide")
  func revealFollowsCauses() throws {
    let warn = try bodyUI([try F.label("!warn")])
    var state = ModerationRevealState()
    #expect(!state.isRevealed(warn))
    state.show(warn)
    #expect(state.isRevealed(warn))
    state.hide()
    #expect(!state.isRevealed(warn))
  }

  @Test("A reused host showing another post's causes is concealed, with or without an unblurred post in between")
  func reuseConcealsOtherCauses() throws {
    let replyA = try bodyUI([try F.label("!warn")])
    let replyB = try bodyUI([])
    let replyC = try bodyUI([try F.label("!warn", uri: "at://\(F.authorDID)/app.bsky.feed.post/three")])
    let accountC = try bodyUI([], author: try F.profile(labels: [try F.accountLabel("!warn")]))
    var state = ModerationRevealState()
    state.show(replyA)
    #expect(!replyB.blur, "the gate renders B directly and never consults the reveal")
    #expect(!state.isRevealed(replyC), "the same label on another post is another cause")
    #expect(!state.isRevealed(accountC), "an account cause is not the post cause that was shown")
  }

  @Test("A policy change that adds a cause conceals a revealed post; the same causes stay revealed")
  func policyChangeConceals() throws {
    let author = try F.profile(labels: [try F.accountLabel("!warn")])
    let before = try bodyUI([try F.label("!warn")])
    let after = try bodyUI([try F.label("!warn")], author: author)
    var state = ModerationRevealState()
    state.show(before)
    #expect(state.isRevealed(before))
    #expect(!state.isRevealed(after), "two blurs are a different cause set from one")
    #expect(state.isRevealed(try bodyUI([try F.label("!warn")])), "an equal decision for the same post stays revealed")
  }

  @Test("A revealed body is concealed again once adult content is turned off, although its cause is unchanged")
  func adultOffConcealsRevealedBody() throws {
    let post = try F.post(labels: [try F.label("custom", src: F.customLabelerDID)])
    let warned = PostModerationPresentation.make(
      post: post, policy: F.customLabelerPolicy(blurs: "content", severity: "alert", adultOnly: true)).body
    let locked = PostModerationPresentation.make(
      post: post, policy: F.customLabelerPolicy(blurs: "content", severity: "alert", adultOnly: true, adult: false)).body
    #expect(warned.blur && !warned.noOverride)
    #expect(locked.blur && locked.noOverride)
    #expect(warned.blurs.map(\.key) == locked.blurs.map(\.key), "adult-off keeps the same cause identity")

    var state = ModerationRevealState()
    state.show(warned)
    #expect(state.isRevealed(warned))
    #expect(!state.isRevealed(locked), "a cause set the viewer may no longer override is concealed")
  }

  @Test("Revealed media is concealed again once adult content is turned off")
  func adultOffConcealsRevealedMedia() throws {
    let post = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    let warned = PostModerationPresentation.make(post: post, policy: F.policy(labels: ["porn": "warn"])).media
    let locked = PostModerationPresentation.make(post: post, policy: F.policy(adult: false)).media
    #expect(warned.blurs.map(\.key) == locked.blurs.map(\.key))
    var state = ModerationRevealState()
    state.show(warned)
    #expect(state.isRevealed(warned))
    #expect(!state.isRevealed(locked))
    #expect(locked.noOverride)
  }
}

// MARK: - Reveal store

/// What a gate remembers across cell reuse: a reveal belongs to one post (its
/// subject), one kind of gate and one set of causes.
@MainActor
@Suite("Moderation rendering: reveal store")
struct ModerationRevealStoreTests {
  private typealias F = RenderingFixtures

  private func warnBody(uri: String = F.postURI) throws -> ModerationUI {
    try PostModerationPresentation.make(
      post: F.post(uri: uri, labels: [try F.label("!warn", uri: uri)]), policy: F.policy()).body
  }

  @Test("A reveal is remembered for its post, gate kind and account, and ends on Hide")
  func revealIsRememberedForItsPost() throws {
    let warn = try warnBody()
    let store = ModerationRevealStore()
    store.setRevealed(true, ui: warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID)
    #expect(store.isRevealed(warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID))
    #expect(!store.isRevealed(warn, gate: .media, subject: F.postURI, accountDID: F.viewerDID))
    #expect(!store.isRevealed(warn, gate: .body, subject: F.postURI, accountDID: "did:web:other.test"))
    store.setRevealed(false, ui: warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID)
    #expect(!store.isRevealed(warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID))
  }

  @Test("Another post by an account-labelled author keeps its own warning")
  func accountCauseIsPerPost() throws {
    let author = try F.profile(labels: [try F.accountLabel("!warn")])
    let otherURI = "at://\(F.authorDID)/app.bsky.feed.post/two"
    let first = try PostModerationPresentation.make(post: F.post(author: author), policy: F.policy()).body
    let second = try PostModerationPresentation.make(
      post: F.post(uri: otherURI, author: author), policy: F.policy()).body
    #expect(first.blurs.map(\.key) == second.blurs.map(\.key), "an account cause is the same on every post")
    let store = ModerationRevealStore()
    store.setRevealed(true, ui: first, gate: .body, subject: F.postURI, accountDID: F.viewerDID)
    #expect(!store.isRevealed(second, gate: .body, subject: otherURI, accountDID: F.viewerDID))
  }

  @Test("Showing a self-quote by an account-labelled author never opens the quote")
  func selfQuoteKeepsItsOwnWarning() throws {
    let accountWarn = try F.accountLabel("!warn", did: F.quotedAuthorDID)
    let quoted = try F.quoted(authorLabels: [accountWarn])
    let parentURI = "at://\(F.quotedAuthorDID)/app.bsky.feed.post/parent"
    let parent = try F.post(
      uri: parentURI, author: F.profile(did: F.quotedAuthorDID, labels: [accountWarn]), quote: quoted)
    let parentBody = PostModerationPresentation.make(post: parent, policy: F.policy()).body
    let quoteBody = PostModerationPresentation.make(quoted: quoted, policy: F.policy()).body
    #expect(parentBody.blur && quoteBody.blur)
    #expect(parentBody.blurs.map(\.key) == quoteBody.blurs.map(\.key), "both gates show the same cause")
    let store = ModerationRevealStore()
    store.setRevealed(true, ui: parentBody, gate: .body, subject: parentURI, accountDID: F.viewerDID)
    #expect(!store.isRevealed(quoteBody, gate: .body, subject: F.quotedURI, accountDID: F.viewerDID))
  }

  @Test("The generation moves only when the recorded reveals change")
  func generationTracksChanges() throws {
    let warn = try warnBody()
    let store = ModerationRevealStore()
    let start = store.generation
    store.setRevealed(false, ui: warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID)
    store.setRevealed(true, ui: warn, gate: .body, subject: "", accountDID: F.viewerDID)
    #expect(store.generation == start, "hiding nothing and a gate with no subject change nothing")
    store.setRevealed(true, ui: warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID)
    let shown = store.generation
    #expect(shown != start)
    store.setRevealed(true, ui: warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID)
    #expect(store.generation == shown, "showing a shown post again changes nothing")
    store.setRevealed(false, ui: warn, gate: .body, subject: F.postURI, accountDID: F.viewerDID)
    #expect(store.generation != shown)
  }

  @Test("A gate with no subject records nothing")
  func noSubjectRecordsNothing() throws {
    let warn = try warnBody()
    let store = ModerationRevealStore()
    store.setRevealed(true, ui: warn, gate: .body, subject: "", accountDID: F.viewerDID)
    #expect(!store.isRevealed(warn, gate: .body, subject: "", accountDID: F.viewerDID))
  }
}

@Suite("Moderation reveal motion")
struct ModerationRevealMotionTests {
  @Test("Layout reveal motion is available when accessibility settings allow it")
  func ordinaryMotionIsEnabled() {
    #expect(PostRevealMotion.isLayoutAnimationEnabled(reduceMotion: false, voiceOverEnabled: false))
  }

  @Test("Reduce Motion disables reveal layout animation")
  func reduceMotionDisablesLayoutAnimation() {
    #expect(!PostRevealMotion.isLayoutAnimationEnabled(reduceMotion: true, voiceOverEnabled: false))
  }

  @Test("VoiceOver disables reveal layout animation")
  func voiceOverDisablesLayoutAnimation() {
    #expect(!PostRevealMotion.isLayoutAnimationEnabled(reduceMotion: false, voiceOverEnabled: true))
  }
}

// MARK: - Gate copy

/// The hidden row and the locked bars name the actual reason content is
/// hidden: the account's adult-content setting, the moderators, or the user's
/// own label setting.
@Suite("Moderation rendering: gate copy")
struct ModerationGateCopyTests {
  private typealias F = RenderingFixtures

  @Test("A !hide row is hidden by moderators, an adult-off row by the adult setting, a porn=hide row by the user")
  func hiddenRowNamesItsReason() throws {
    let system = PostModerationPresentation.make(post: try F.post(labels: [try F.label("!hide")]), policy: F.policy())
    #expect(system.hiddenRowReason == .moderators)
    #expect(ModerationGateText.hiddenRowHeadline(for: system) == "Post hidden by moderators")
    #expect(ModerationGateText.hiddenRowDetail(for: system) == "Content Blocked")

    let porn = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    let adultOff = PostModerationPresentation.make(post: porn, policy: F.policy(adult: false))
    #expect(adultOff.hiddenRowReason == .adultContentOff)
    #expect(ModerationGateText.hiddenRowHeadline(for: adultOff) == "Post hidden while adult content is off")
    #expect(ModerationGateText.hiddenRowDetail(for: adultOff).contains("bsky.app"))

    let userHide = PostModerationPresentation.make(post: porn, policy: F.policy(labels: ["porn": "hide"]))
    #expect(userHide.hiddenRowReason == .userSetting)
    #expect(ModerationGateText.hiddenRowHeadline(for: userHide) == "Post hidden by your moderation settings")
    #expect(ModerationGateText.hiddenRowDetail(for: userHide) == "Adult Content")
  }

  @Test("A labeler's hide-by-default label counts as the user's setting; its account label too")
  func labelerDefaultHideIsUserSetting() throws {
    let post = try F.post(labels: [try F.label("custom", src: F.customLabelerDID)])
    let presentation = PostModerationPresentation.make(
      post: post, policy: F.customLabelerPolicy(blurs: "content", severity: "alert", labels: ["custom": "hide"]))
    #expect(presentation.hidesRow)
    #expect(presentation.hiddenRowReason == .userSetting)
  }

  @Test("A locked body gate says why: adult content off for an adult-only label, moderators for !hide")
  func lockedBarNamesItsReason() throws {
    let custom = try F.post(labels: [try F.label("custom", src: F.customLabelerDID)])
    let adultOff = PostModerationPresentation.make(
      post: custom, policy: F.customLabelerPolicy(blurs: "content", severity: "alert", adultOnly: true, adult: false)).body
    #expect(adultOff.noOverride)
    #expect(ModerationGateText.lockedLabel(for: adultOff) == "Adult content off")
    #expect(ModerationGateText.explanation(for: adultOff) == ModerationGateText.adultContentOffExplanation)

    let hidden = PostModerationPresentation.make(post: try F.post(labels: [try F.label("!hide")]), policy: F.policy()).body
    #expect(ModerationGateText.lockedLabel(for: hidden) == "Hidden by moderators")
    #expect(ModerationGateText.explanation(for: hidden) == ModerationGateText.moderatorsExplanation)
  }
}
