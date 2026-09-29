#if DEBUG
import Petrel
import SwiftUI

/// Presentation fixture for the Message Requests sheet, launched with
/// `--message-requests-ui-fixture`. It renders the real `MessageRequestsScreen`
/// against canned requests and makes no network or MLS calls.
///
/// Extra launch arguments:
/// - `--message-requests-empty`: no requests (empty state).
/// - `--message-requests-detail=<item id>`: open that request's detail.
struct MessageRequestsUIFixture: View {
  @State private var appState: AppState?
  @State private var store = FixtureMessageRequestsStore(
    empty: ProcessInfo.processInfo.arguments.contains("--message-requests-empty"))
  @State private var isPresented = true

  private var initialRoutes: [MessageRequestRoute] {
    let prefix = "--message-requests-detail="
    guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return [] }
    return [.detail(String(argument.dropFirst(prefix.count)))]
  }

  var body: some View {
    Group {
      if let appState {
        Text("Inbox")
          .font(.largeTitle.bold())
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .sheet(isPresented: $isPresented) {
            MessageRequestsScreen(
              store: store,
              initialRoutes: initialRoutes,
              onAccepted: { _ in },
              onClose: { isPresented = false }
            )
            .presentationDetents([.large])
            .interactiveDismissDisabled()
            .environment(appState)
          }
      } else {
        ProgressView()
      }
    }
    .task {
      let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
      appState = AppState(userDID: FixtureMessageRequestsStore.accountDID, client: client)
    }
  }
}

/// Canned requests covering every row shape: Bluesky direct with social
/// context, a new account, a Bluesky group, and both encrypted kinds.
@MainActor
@Observable
final class FixtureMessageRequestsStore: MessageRequestsStore {
  static let accountDID = "did:plc:requestsfixtureself"

  private(set) var blueskyRequests: [MessageRequestItem]
  private(set) var encryptedRequests: [MessageRequestItem]
  let groupInvitationNotes: [MLSGroupInvitationNotes] = []
  let savedInvitationNotes: [MLSDirectComposeDraft] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = true
  private(set) var inFlight: [MessageRequestItem.ID: MessageRequestDecision] = [:]
  var errorMessage: String?
  let usesVerifiedEncryptedDetail: Bool

  init(empty: Bool, usesVerifiedEncryptedDetail: Bool = false) {
    self.usesVerifiedEncryptedDetail = usesVerifiedEncryptedDetail
    guard !empty else {
      blueskyRequests = []
      encryptedRequests = []
      return
    }
    let now = Date()
    let maya = RequestParticipant(did: "did:plc:fixturemaya", handle: "maya.bsky.social", displayName: "Maya Chen", avatarURL: nil, badge: .regular)
    let newcomer = RequestParticipant(did: "did:plc:fixturenew", handle: "quietfern.bsky.social", displayName: nil, avatarURL: nil)
    let sam = RequestParticipant(did: "did:plc:fixturesam", handle: "samortiz.dev", displayName: "Sam Ortiz", avatarURL: nil)
    let lee = RequestParticipant(did: "did:plc:fixturelee", handle: "lee.bsky.social", displayName: "Lee Park", avatarURL: nil)
    let priya = RequestParticipant(did: "did:plc:fixturepriya", handle: "priya.dev", displayName: "Priya Raman", avatarURL: nil)
    let alex = RequestParticipant(did: "did:plc:fixturealex", handle: "alexkim.art", displayName: "Alex Kim", avatarURL: nil)
    let jo = RequestParticipant(did: "did:plc:fixturejo", handle: "jo.bsky.social", displayName: "Jo Rivera", avatarURL: nil)

    blueskyRequests = [
      MessageRequestItem(
        id: "bsky:maya", origin: .bluesky(convoID: "maya"), sender: maya, participants: [maya],
        groupTitle: nil, memberCount: nil, date: now.addingTimeInterval(-12 * 60),
        context: MessageRequestPresentation.contextLine(
          followsYou: false, knownFollowerNames: ["Jay"], knownFollowerCount: 4, accountCreatedAt: nil, now: now),
        preview: .message("Hey! Loved your talk at the meetup. Would you be up for coffee next week to talk about the AT Protocol SDK?"),
        isUnread: true),
      MessageRequestItem(
        id: "bsky:newcomer", origin: .bluesky(convoID: "newcomer"), sender: newcomer, participants: [newcomer],
        groupTitle: nil, memberCount: nil, date: now.addingTimeInterval(-3 * 60 * 60),
        context: MessageRequestPresentation.contextLine(
          followsYou: false, knownFollowerNames: [], knownFollowerCount: 0,
          accountCreatedAt: now.addingTimeInterval(-2 * 24 * 60 * 60), now: now),
        preview: .message("hi"),
        isUnread: false),
      MessageRequestItem(
        id: "bsky:swiftnyc", origin: .bluesky(convoID: "swiftnyc"), sender: sam, participants: [sam, lee, maya],
        groupTitle: "Swift Devs NYC", memberCount: 6, date: now.addingTimeInterval(-26 * 60 * 60),
        context: MessageRequestPresentation.contextLine(
          followsYou: true, knownFollowerNames: [], knownFollowerCount: 0, accountCreatedAt: nil, now: now),
        preview: .description(MessageRequestPresentation.groupInvitationDescription(title: "Swift Devs NYC", memberCount: 6)),
        isUnread: false),
    ]
    encryptedRequests = [
      MessageRequestItem(
        id: "mls:priya", origin: .encryptedDirect(conversationID: "priya"), sender: priya, participants: [priya],
        groupTitle: nil, memberCount: nil, date: now.addingTimeInterval(-5 * 60),
        context: nil,
        preview: .message("Sending this over encrypted chat. Can you take a look at the key package fix before Friday?"),
        isUnread: false),
      MessageRequestItem(
        id: "mls:designcrit", origin: .encryptedLegacy(conversationID: "designcrit"), sender: alex, participants: [alex, jo, priya],
        groupTitle: "Design Crit", memberCount: 4, date: now.addingTimeInterval(-2 * 24 * 60 * 60),
        context: nil,
        preview: .description(MessageRequestPresentation.groupInvitationDescription(title: "Design Crit", memberCount: 4)),
        isUnread: false),
    ]
  }

  func refresh() async {}

  func accept(_ item: MessageRequestItem) async -> MessageRequestAcceptance? {
    guard await simulate(.accept, on: item) else { return nil }
    remove(item)
    return item.source == .bluesky
      ? .bluesky(convoID: item.conversationID)
      : .encrypted(conversationID: item.conversationID)
  }

  func decline(_ item: MessageRequestItem) async -> Bool {
    guard await simulate(.decline, on: item) else { return false }
    remove(item)
    return true
  }

  func blockAndClose(_ item: MessageRequestItem) async -> Bool {
    guard await simulate(.block, on: item) else { return false }
    remove(item)
    return true
  }

  func declineAllBluesky() async {
    blueskyRequests.removeAll()
  }

  func blueskyConversation(for item: MessageRequestItem) -> ChatBskyConvoDefs.ConvoView? { nil }

  func mlsReportClient() async -> MLSAPIClient? { nil }

  func invalidate() {}

  private func simulate(_ decision: MessageRequestDecision, on item: MessageRequestItem) async -> Bool {
    guard inFlight[item.id] == nil else { return false }
    inFlight[item.id] = decision
    defer { inFlight[item.id] = nil }
    do { try await Task.sleep(for: .milliseconds(700)) } catch { return false }
    return true
  }

  private func remove(_ item: MessageRequestItem) {
    blueskyRequests.removeAll { $0.id == item.id }
    encryptedRequests.removeAll { $0.id == item.id }
  }
}
#endif
