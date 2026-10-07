@testable import Catbird
import Foundation
import Petrel
import Testing
#if os(iOS)
import SwiftUI
import UIKit
#endif

@Suite("Message request presentation")
struct MessageRequestPresentationTests {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  // MARK: - Context line

  @Test("Known followers name the first and count the rest")
  func knownFollowersContext() {
    #expect(MessageRequestPresentation.contextLine(
      followsYou: false, knownFollowerNames: ["Jay"], knownFollowerCount: 4, accountCreatedAt: nil, now: now)
      == "Followed by Jay and 3 others you know")
    #expect(MessageRequestPresentation.contextLine(
      followsYou: false, knownFollowerNames: ["Jay", "Rae"], knownFollowerCount: 2, accountCreatedAt: nil, now: now)
      == "Followed by Jay and Rae")
    #expect(MessageRequestPresentation.contextLine(
      followsYou: false, knownFollowerNames: ["Jay"], knownFollowerCount: 2, accountCreatedAt: nil, now: now)
      == "Followed by Jay and 1 other you know")
    #expect(MessageRequestPresentation.contextLine(
      followsYou: false, knownFollowerNames: ["Jay"], knownFollowerCount: 0, accountCreatedAt: nil, now: now)
      == "Followed by Jay")
  }

  @Test("Follows-you combines with known followers and wins over new account")
  func followsYouContext() {
    #expect(MessageRequestPresentation.contextLine(
      followsYou: true, knownFollowerNames: [], knownFollowerCount: 0,
      accountCreatedAt: now.addingTimeInterval(-60), now: now) == "Follows you")
    #expect(MessageRequestPresentation.contextLine(
      followsYou: true, knownFollowerNames: ["Jay"], knownFollowerCount: 1, accountCreatedAt: nil, now: now)
      == "Follows you · Followed by Jay")
  }

  @Test("New account only within seven days, and blank names are ignored")
  func newAccountContext() {
    let day: TimeInterval = 24 * 60 * 60
    #expect(MessageRequestPresentation.contextLine(
      followsYou: false, knownFollowerNames: ["  "], knownFollowerCount: 1,
      accountCreatedAt: now.addingTimeInterval(-2 * day), now: now) == "New account")
    #expect(MessageRequestPresentation.contextLine(
      followsYou: false, knownFollowerNames: [], knownFollowerCount: 0,
      accountCreatedAt: now.addingTimeInterval(-8 * day), now: now) == nil)
    #expect(MessageRequestPresentation.contextLine(
      followsYou: false, knownFollowerNames: [], knownFollowerCount: 0, accountCreatedAt: nil, now: now) == nil)
  }

  // MARK: - Text

  @Test("Group invitations quote the title and pluralize members")
  func groupInvitationDescription() {
    #expect(MessageRequestPresentation.groupInvitationDescription(title: "Design Crit", memberCount: 4)
      == "Invited you to \u{201C}Design Crit\u{201D} · 4 members")
    #expect(MessageRequestPresentation.groupInvitationDescription(title: " ", memberCount: 1)
      == "Invited you to a group chat · 1 member")
    #expect(MessageRequestPresentation.groupInvitationDescription(title: "Room", memberCount: nil)
      == "Invited you to \u{201C}Room\u{201D}")
  }

  @Test("Relative timestamps are compact, then fall back to dates")
  func relativeTimestamps() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let format = { (offset: TimeInterval) in
      MessageRequestPresentation.relativeTimestamp(for: now.addingTimeInterval(-offset), now: now, calendar: calendar)
    }
    #expect(format(10) == "now")
    #expect(format(5 * 60) == "5m")
    #expect(format(3 * 60 * 60) == "3h")
    #expect(format(2 * 24 * 60 * 60) == "2d")
    #expect(!format(30 * 24 * 60 * 60).contains("2026"))
    #expect(format(400 * 24 * 60 * 60).contains("2025"))
  }

  // MARK: - Sections

  @Test("Sections show Bluesky requests and hide the empty section")
  func sectionsHideEmpty() {
    let bluesky = item(id: "bsky:1", origin: .bluesky(convoID: "1"))
    #expect(MessageRequestPresentation.sections(bluesky: [bluesky]).map(\.source) == [.bluesky])
    #expect(MessageRequestPresentation.sections(bluesky: []).isEmpty)
  }

  @Test("Rows without a real sender never show a DID and cannot be moderated")
  func unknownSenderTitle() {
    let anonymous = item(id: "bsky:3", origin: .bluesky(convoID: "3"))
    #expect(anonymous.title == "Chat request")
    #expect(!anonymous.canModerateSender)
    let deleted = RequestParticipant(did: "did:plc:gone", handle: "missing.invalid", displayName: nil, avatarURL: nil, isDeletedAccount: true)
    #expect(deleted.name == "Deleted Account")
    #expect(deleted.handleText == nil)
    #expect(!deleted.canOpenProfile)
  }

  // MARK: - Bluesky mapping

  @Test("Bluesky requests map sender, time, message, and social context")
  func blueskyMapping() throws {
    let sentAt = now.addingTimeInterval(-90)
    let jay = try AppBskyActorDefs.ProfileViewBasic(
      did: DID(didString: "did:plc:jay"), handle: Handle(handleString: "jay.test"), displayName: "Jay")
    let viewer = AppBskyActorDefs.ViewerState(
      followedBy: try ATProtocolURI(uriString: "at://did:plc:maya/app.bsky.graph.follow/1"),
      knownFollowers: AppBskyActorDefs.KnownFollowers(count: 3, followers: [jay]))
    let maya = try profile(did: "did:plc:maya", handle: "maya.test", displayName: "Maya", viewer: viewer)
    let me = try profile(did: "did:plc:me", handle: "me.test", displayName: "Me")
    let message = ChatBskyConvoDefs.MessageView(
      id: "m1", rev: "r1", text: "Coffee next week?",
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:maya")),
      sentAt: ATProtocolDate(date: sentAt))
    let convo = ChatBskyConvoDefs.ConvoView(
      id: "convo-1", rev: "rev-1", members: [me, maya],
      lastMessage: .chatBskyConvoDefsMessageView(message), lastReaction: nil,
      muted: false, status: .request, unreadCount: 1,
      kind: .chatBskyConvoDefsDirectConvo(ChatBskyConvoDefs.DirectConvo()))

    let item = MessageRequestItem(bluesky: convo, currentUserDID: "did:plc:me", now: now)

    #expect(item.id == "bsky:convo-1")
    #expect(item.source == .bluesky)
    #expect(item.title == "Maya")
    #expect(item.sender?.handleText == "@maya.test")
    #expect(item.participants.map(\.did) == ["did:plc:maya"])
    #expect(item.preview == .message("Coffee next week?"))
    #expect(item.context == "Follows you · Followed by Jay and 2 others you know")
    #expect(item.isUnread)
    #expect(!item.isGroup)
    #expect(item.canModerateSender)
    #expect(abs((item.date?.timeIntervalSince1970 ?? 0) - sentAt.timeIntervalSince1970) < 1)
  }

  @Test("A Bluesky request without a message still reads as a request, not a rev")
  func blueskyMappingWithoutMessage() throws {
    let me = try profile(did: "did:plc:me", handle: "me.test", displayName: "Me")
    let other = try profile(did: "did:plc:other", handle: "other.test", displayName: nil)
    let convo = ChatBskyConvoDefs.ConvoView(
      id: "convo-2", rev: "rev-2", members: [me, other],
      lastMessage: nil, lastReaction: nil, muted: false, status: .request, unreadCount: 0, kind: nil)

    let item = MessageRequestItem(bluesky: convo, currentUserDID: "did:plc:me", now: now)

    #expect(item.title == "@other.test")
    #expect(item.preview == .description("Wants to chat"))
    #expect(item.date == nil)
    #expect(item.context == nil)
  }

  // MARK: - Helpers

  private func item(id: String, origin: MessageRequestOrigin) -> MessageRequestItem {
    MessageRequestItem(
      id: id, origin: origin, sender: nil, participants: [], groupTitle: nil, memberCount: nil,
      date: nil, context: nil, preview: .description("Wants to chat"), isUnread: false)
  }

  private func profile(
    did: String, handle: String, displayName: String?, viewer: AppBskyActorDefs.ViewerState? = nil
  ) throws -> ChatBskyActorDefs.ProfileViewBasic {
    try ChatBskyActorDefs.ProfileViewBasic(
      did: DID(didString: did), handle: Handle(handleString: handle), displayName: displayName,
      avatar: nil, associated: nil, viewer: viewer, labels: nil, createdAt: nil,
      chatDisabled: nil, verification: nil, kind: nil)
  }
}

// MARK: - Sheet content and routing

/// The Lite request sheet retains Bluesky request routing and decisions.
@MainActor
@Suite("Message requests sheet content")
struct MessageRequestsSheetContentTests {
  @Test("The sheet lists every pending Bluesky request")
  func blueskyRequestsVisible() {
    let store = FixtureMessageRequestsStore(empty: false)
    let sections = MessageRequestPresentation.sections(bluesky: store.blueskyRequests)
    #expect(sections.map(\.source) == [.bluesky])
    #expect(sections[0].items.map(\.id) == ["bsky:maya", "bsky:newcomer", "bsky:swiftnyc"])
    #expect(!store.isEmpty)
  }

  @Test("Other requests open the request detail, and handled ones say so")
  func otherRoutes() throws {
    let store = FixtureMessageRequestsStore(empty: false)
    let bluesky = try #require(store.item(withID: "bsky:maya"))
    #expect(MessageRequestRoute.detail("bsky:maya").destination(in: store) == .detail(bluesky))
    #expect(MessageRequestRoute.detail("bsky:gone").destination(in: store) == .handled)
  }

  @Test("Declining keeps the other requests and resolves the declined route as handled")
  func declineRemovesOnlyThatRequest() async throws {
    let store = FixtureMessageRequestsStore(empty: false)
    let item = try #require(store.item(withID: "bsky:newcomer"))
    #expect(await store.decline(item))
    #expect(store.item(withID: "bsky:newcomer") == nil)
    #expect(store.blueskyRequests.count == 2)
    #expect(MessageRequestRoute.detail("bsky:newcomer").destination(in: store) == .handled)
  }

  #if os(iOS)
  @Test("Opening the sheet on a pending request pushes that request's detail")
  func initialRoutePushesDetail() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: FixtureMessageRequestsStore.accountDID, client: client)
    let store = FixtureMessageRequestsStore(empty: false)
    let controller = UIHostingController(rootView: MessageRequestsScreen(
      store: store, initialRoutes: [.detail("bsky:maya")], onAccepted: { _ in }, onClose: {}
    ).environment(appState))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    func navigationTitles() -> [String] {
      guard let nav = findNavigationController(controller) else { return [] }
      return nav.viewControllers.compactMap { $0.navigationItem.title }
    }
    var titles: [String] = []
    for _ in 0..<100 {
      controller.view.layoutIfNeeded()
      titles = navigationTitles()
      if titles.contains("Message Request") { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(titles == ["Message Requests", "Message Request"])
  }

  private func findNavigationController(_ root: UIViewController) -> UINavigationController? {
    if let nav = root as? UINavigationController { return nav }
    for child in root.children {
      if let nav = findNavigationController(child) { return nav }
    }
    return nil
  }
  #endif
}

@Suite("Request participant names")
struct RequestParticipantNameTests {
  @Test("A handle-only sender shows the handle once")
  func handleOnlySenderShowsHandleOnce() {
    let handleOnly = RequestParticipant(did: "did:plc:a", handle: "quiet.test", displayName: nil, avatarURL: nil)
    #expect(handleOnly.name == "@quiet.test")
    #expect(handleOnly.secondaryHandle == nil)
    let named = RequestParticipant(did: "did:plc:b", handle: "maya.test", displayName: "Maya", avatarURL: nil)
    #expect(named.secondaryHandle == "@maya.test")
  }
}
