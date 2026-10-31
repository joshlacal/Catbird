import Foundation
import Petrel
import Testing

@testable import Catbird

// What the notifications list derives from the engine, mirroring
// `shouldFilterNotif` upstream: authors the policy filters are dropped (unless
// followed, except for `!hide`), subject posts the policy filters drop their
// reply, mention and quote groups, and author avatars follow `ui(.avatar)`.

@Suite("Moderation rendering: notifications")
struct NotificationModerationTests {
  private typealias F = RenderingFixtures
  private typealias Notification = AppBskyNotificationListNotifications.Notification

  private static let viewer = "did:web:self.test"

  private func author(
    _ did: String = "did:web:liker.test", labels: [ComAtprotoLabelDefs.Label]? = nil, following: Bool = false
  ) throws -> AppBskyActorDefs.ProfileView {
    let name = String(did.split(separator: ":").last ?? "author").replacingOccurrences(of: ".test", with: "")
    let follow = try ATProtocolURI(uriString: "at://\(Self.viewer)/app.bsky.graph.follow/1")
    return AppBskyActorDefs.ProfileView(
      did: try DID(didString: did), handle: try Handle(handleString: "\(name).test"), displayName: name.capitalized,
      viewer: following ? AppBskyActorDefs.ViewerState(following: follow) : nil,
      labels: labels)
  }

  private func notification(
    from author: AppBskyActorDefs.ProfileView, reason: String = "like", slug: String = "one",
    labels: [ComAtprotoLabelDefs.Label]? = nil
  ) throws -> Notification {
    let uri = "at://\(author.did.didString())/app.bsky.feed.like/\(slug)"
    return Notification(
      uri: try ATProtocolURI(uriString: uri), cid: CID.fromDAGCBOR(Data(uri.utf8)), author: author, reason: reason,
      record: .object([:]), isRead: false, indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000)),
      labels: labels)
  }

  private func group(
    _ notifications: [Notification], type: NotificationType = .like, subjectPost: AppBskyFeedDefs.PostView? = nil
  ) -> GroupedNotification {
    GroupedNotification(id: "group", type: type, notifications: notifications, subjectPost: subjectPost, parentPost: nil, pageNumber: 0)
  }

  // MARK: - Author labels

  @Test("An author labelled !hide is dropped, even when the viewer follows them")
  func hiddenAuthorIsDropped() throws {
    let labels = [try F.accountLabel("!hide", did: "did:web:liker.test")]
    #expect(NotificationModeration.isListFiltered(try notification(from: try author(labels: labels)), policy: F.policy()))
    #expect(NotificationModeration.isListFiltered(try notification(from: try author(labels: labels, following: true)), policy: F.policy()))
  }

  @Test("An author with an adult account label is dropped under adult-off or a hide setting, unless followed")
  func adultAuthorFollowsSettingAndFollowing() throws {
    let labels = [try F.accountLabel("porn", did: "did:web:liker.test")]
    let stranger = try notification(from: try author(labels: labels))
    #expect(NotificationModeration.isListFiltered(stranger, policy: F.policy(adult: false)))
    #expect(NotificationModeration.isListFiltered(stranger, policy: F.policy(labels: ["porn": "hide"])))
    #expect(!NotificationModeration.isListFiltered(stranger, policy: F.policy(labels: ["porn": "warn"])))
    let followed = try notification(from: try author(labels: labels, following: true))
    #expect(!NotificationModeration.isListFiltered(followed, policy: F.policy(adult: false)))
  }

  @Test("Labels on the notification record itself count as content labels")
  func notificationLabelsCount() throws {
    let liker = try author()
    let labels = [try F.label("!hide", uri: "at://did:web:liker.test/app.bsky.feed.like/one")]
    #expect(NotificationModeration.isListFiltered(try notification(from: liker, labels: labels), policy: F.policy()))
    #expect(!NotificationModeration.isListFiltered(try notification(from: liker), policy: F.policy()))
  }

  @Test("A label from an unsubscribed labeler does not drop a notification")
  func untrustedLabelIgnored() throws {
    let labels = [try F.accountLabel("!hide", did: "did:web:liker.test", src: "did:web:stranger.test")]
    #expect(!NotificationModeration.isListFiltered(try notification(from: try author(labels: labels)), policy: F.policy()))
  }

  // MARK: - Groups

  @Test("A group keeps only the notifications whose authors pass, and is dropped when none do")
  func groupIsPruned() throws {
    let hidden = try author("did:web:hidden.test", labels: [try F.accountLabel("!hide", did: "did:web:hidden.test")])
    let plain = try author()
    let mixed = group([try notification(from: hidden, slug: "a"), try notification(from: plain, slug: "b")])
    let visible = try #require(NotificationModeration.visibleGroup(mixed, policy: F.policy()))
    #expect(visible.id == mixed.id)
    #expect(visible.notifications.map { $0.author.did.didString() } == ["did:web:liker.test"])
    #expect(NotificationModeration.visibleGroup(group([try notification(from: hidden)]), policy: F.policy()) == nil)
    let untouched = group([try notification(from: plain)])
    #expect(NotificationModeration.visibleGroup(untouched, policy: F.policy())?.notifications.count == 1)
  }

  @Test("A reply, mention or quote whose subject post is list-filtered is dropped; a like of it is not")
  func filteredSubjectDropsReplyGroups() throws {
    let adultPost = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    let adultOff = F.policy(adult: false)
    let replier = try author()
    for type in [NotificationType.reply, .mention, .quote] {
      let replies = group([try notification(from: replier, reason: type.rawValue)], type: type, subjectPost: adultPost)
      #expect(NotificationModeration.visibleGroup(replies, policy: adultOff) == nil, "\(type) is dropped")
      #expect(NotificationModeration.visibleGroup(replies, policy: F.policy(labels: ["porn": "warn"])) != nil)
    }
    let likes = group([try notification(from: replier)], type: .like, subjectPost: adultPost)
    #expect(NotificationModeration.visibleGroup(likes, policy: adultOff) != nil, "the card renders the subject under the row rules")
  }

  // MARK: - Avatars and quotes

  @Test("An author's avatar is concealed by a !warn or warned adult account label and not otherwise")
  func avatarFollowsAccountLabels() throws {
    let warned = try author(labels: [try F.accountLabel("!warn", did: "did:web:liker.test")])
    #expect(NotificationModeration.concealsAvatar(of: warned, policy: F.policy()))
    let adult = try author(labels: [try F.accountLabel("porn", did: "did:web:liker.test")])
    #expect(NotificationModeration.concealsAvatar(of: adult, policy: F.policy(labels: ["porn": "warn"])))
    #expect(!NotificationModeration.concealsAvatar(of: adult, policy: F.policy(labels: ["porn": "ignore"])))
    #expect(!NotificationModeration.concealsAvatar(of: try author(), policy: F.policy()))
  }

  @Test("The viewer's own post quoting a !hide-labelled record keeps its preview; the quote is gated with no Show")
  func ownPostQuotingHiddenRecord() throws {
    let quoted = try F.quoted(labels: [try F.label("!hide", uri: F.quotedURI)])
    let own = try F.post(
      uri: "at://\(Self.viewer)/app.bsky.feed.post/mine", author: try F.profile(did: Self.viewer), quote: quoted)
    let parent = PostModerationPresentation.make(post: own, policy: F.policy())
    #expect(!parent.hidesRow)
    #expect(!parent.concealsBody)
    let record = try #require(PostModerationPresentation.quotedRecord(in: own))
    let quote = PostModerationPresentation.make(quoted: record, policy: F.policy())
    #expect(quote.concealsBody)
    #expect(quote.body.noOverride)
  }
}
