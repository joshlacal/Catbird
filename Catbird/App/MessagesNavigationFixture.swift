#if DEBUG && os(iOS)
import Foundation
@testable import Petrel
import SwiftData
import SwiftUI
import UIKit

/// Hosts the production tabs, split-view conversation list and transcript with
/// local transport responses. No account is authenticated; all writes fail locally.
@MainActor
struct MessagesNavigationFixture: View {
  static let launchArgument = "--messages-navigation-ui-fixture"
  static let accountDID = "did:plc:messagesfixtureviewer"
  static let conversationID = "messages-navigation-fixture"

  @State private var account: AppState?
  @State private var context: SceneNavigationContext?
  @State private var storage: ModelContainer?
  @State private var selectedTab = AppNavigationManager.chatTabIndex
  @State private var lastTappedTab: Int?
  @State private var failure: String?
  @State private var deliveredLinks = 0
  @State private var restoredService = false

  private var failedLoadScenario: Bool {
    ProcessInfo.processInfo.arguments.contains("--messages-navigation-failed-load")
  }

  private var initialLinkScenario: Bool {
    ProcessInfo.processInfo.arguments.contains("--messages-navigation-initial-link")
  }

  var body: some View {
    Group {
      if let account, let context, let storage {
        SceneNavigationHost(appState: account, appStateManager: .shared, context: context) {
          MainContentView(selectedTab: $selectedTab, lastTappedTab: $lastTappedTab)
            .safeAreaInset(edge: .top, spacing: 0) {
              fixtureControls(account: account, context: context)
            }
            .overlay(alignment: .topLeading) {
              MessagesNavigationProbe(account: account, scene: context,
                selectedTab: selectedTab, deliveredLinks: deliveredLinks)
                .frame(width: 2, height: 2)
            }
        }
        .modelContainer(storage)
        .environment(\.fontManager, account.fontManager)
      } else if let failure {
        Text(failure).accessibilityIdentifier("messages-navigation.failure")
      } else {
        ProgressView("Preparing local messages")
      }
    }
    .preferredColorScheme(.light)
    .task { await prepare() }
    .onDisappear {
      account?.chatManager.stopAllPolling()
      context?.invalidate()
    }
  }

  private func fixtureControls(account: AppState, context: SceneNavigationContext) -> some View {
    HStack(spacing: 8) {
      Button("Open link") {
        Task {
          if await context.urlHandler.handleURL(URL(string: "https://bsky.app/messages/\(Self.conversationID)")!) {
            deliveredLinks += 1
          }
        }
      }
      .accessibilityIdentifier("messages-navigation.conversation-link")
      Button("Messages root") {
        Task {
          if await context.urlHandler.handleURL(URL(string: "https://bsky.app/messages")!) {
            deliveredLinks += 1
          }
        }
      }
      .accessibilityIdentifier("messages-navigation.root-link")
      // Compact conversation details intentionally hide the native tab bar.
      // This invokes the same binding event delivered by native tab reselection.
      Button("Retap") { lastTappedTab = AppNavigationManager.chatTabIndex }
        .accessibilityIdentifier("messages-navigation.reselect")
      if failedLoadScenario && !restoredService {
        Button("Restore service") {
          // Stop automatic retries only when restoring the local transport, so
          // recovery below must come from the production Try Again button.
          account.chatManager.stopMessagePolling(for: Self.conversationID)
          MessagesNavigationProtocol.restoreService()
          restoredService = true
        }
        .accessibilityIdentifier("messages-navigation.restore-service")
      } else if !failedLoadScenario && selectedTab == AppNavigationManager.chatTabIndex {
        Button("Nested detail") {
          context.navigationManager.navigate(to: .hashtag("messages-route-fixture"),
            in: AppNavigationManager.chatTabIndex)
        }
        .accessibilityIdentifier("messages-navigation.nested-detail")
      }
    }
    .font(.caption2)
    .buttonStyle(.bordered)
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .background(.background)
  }

  private func prepare() async {
    guard account == nil else { return }
    do {
      try MessagesNavigationProtocol.prepare(failedLoad: failedLoadScenario)
      guard URLProtocol.registerClass(MessagesNavigationProtocol.self) else {
        throw URLError(.cannotLoadFromNetwork)
      }
      await NetworkService.setNetworkTestProtocolClasses([MessagesNavigationProtocol.self])
      let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)
      let state = AppState(userDID: Self.accountDID, client: client, regulatoryChecker: NoAgePrompt())
      state.currentUserProfile = try JSONDecoder().decode(AppBskyActorDefs.ProfileViewBasic.self,
        from: Data(#"{"did":"did:plc:messagesfixtureviewer","handle":"messages-viewer.test","displayName":"Local Messages Viewer"}"#.utf8))
      let memory = try CatbirdSwiftDataStore.makeContainer(
        configuration: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
      PersistentFeedStateManager.initialize(with: memory)
      state.composerDraftManager.configureForTesting(modelContext: memory.mainContext)
      state.preferencesManager.setModelContext(memory.mainContext)
      let preferences = try await state.preferencesManager.getPreferences()
      preferences.nuxStates = []
      state.onboardingManager.showWelcomeSheet = false
      let scene = SceneNavigationContext(appState: state, sceneID: UUID())
      if initialLinkScenario {
        // Deliver the real URL before publishing the context: ChatTabView has
        // not mounted yet and must consume its pending target on appearance.
        guard await scene.urlHandler.handleURL(URL(string: "https://bsky.app/messages/\(Self.conversationID)")!) else {
          throw URLError(.unsupportedURL)
        }
        deliveredLinks = 1
      }
      guard !Task.isCancelled else { return }
      storage = memory
      context = scene
      account = state
    } catch {
      failure = "Messages fixture failed: \(error.localizedDescription)"
    }
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }
}

/// All HTTP(S) is intercepted; only declared local reads have responses.
/// Failed message loads remain failed across background polls until restored.
private final class MessagesNavigationProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responses: [String: Data] = [:]
  nonisolated(unsafe) private static var recoveredMessages = Data()
  nonisolated(unsafe) private static var failMessages = false
  nonisolated(unsafe) private static var useRecoveredMessages = false
  nonisolated(unsafe) private static var listReads = 0
  nonisolated(unsafe) private static var messageReads = 0
  nonisolated(unsafe) private static var writes = 0

  static func prepare(failedLoad: Bool) throws {
    let viewer: [String: Any] = ["did": "did:plc:messagesfixtureviewer", "handle": "messages-viewer.test", "displayName": "Local Messages Viewer"]
    let partner: [String: Any] = ["did": "did:plc:messagesfixturepartner", "handle": "messages-partner.test", "displayName": "Local Chat Partner"]
    let other: [String: Any] = ["did": "did:plc:messagesfixtureother", "handle": "messages-other.test", "displayName": "Another Local Chat"]
    func conversation(_ id: String, peer: [String: Any]) -> [String: Any] {
      ["id": id, "rev": "fixture-revision", "members": [viewer, peer], "muted": false,
       "status": "accepted", "unreadCount": 0]
    }
    let first = conversation("messages-navigation-fixture", peer: partner)
    let second = conversation("messages-navigation-other", peer: other)
    let payloads: [String: [String: Any]] = [
      "chat.bsky.convo.listConvos": ["convos": [first, second]],
      "chat.bsky.convo.getConvo": ["convo": first],
      "chat.bsky.convo.getMessages": ["messages": []],
      "app.bsky.actor.getPreferences": ["preferences": []],
      "app.bsky.feed.getTimeline": ["feed": []],
      "app.bsky.feed.getFeed": ["feed": []],
      "app.bsky.feed.searchPosts": ["posts": []],
      "app.bsky.notification.listNotifications": ["notifications": []],
      "app.bsky.notification.getUnreadCount": ["count": 0],
      "app.bsky.bookmark.getBookmarks": ["bookmarks": []]
    ]
    let message: [String: Any] = ["$type": "chat.bsky.convo.defs#messageView", "id": "recovered-message",
      "rev": "fixture-revision", "text": "Recovered local message after retry.",
      "sender": ["did": "did:plc:messagesfixturepartner"],
      "sentAt": ISO8601DateFormatter().string(from: Date())]
    let encoded = try payloads.mapValues { try JSONSerialization.data(withJSONObject: $0) }
    let recovery = try JSONSerialization.data(withJSONObject: ["messages": [message]])
    lock.withLock {
      responses = encoded
      recoveredMessages = recovery
      failMessages = failedLoad
      useRecoveredMessages = failedLoad
      listReads = 0
      messageReads = 0
      writes = 0
    }
  }

  static func restoreService() { lock.withLock { failMessages = false } }
  static var counts: (lists: Int, messages: Int, writes: Int) {
    lock.withLock { (listReads, messageReads, writes) }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, url.scheme == "https", url.host == "127.0.0.1",
      url.port == nil, url.user == nil, url.password == nil,
      request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
      url.path.hasPrefix("/xrpc/") else {
      if request.httpMethod != "GET" { Self.lock.withLock { Self.writes += 1 } }
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let method = String(url.path.dropFirst("/xrpc/".count))
    let result: (Int, Data)? = Self.lock.withLock {
      guard let data = Self.responses[method] else { return nil }
      if method == "chat.bsky.convo.listConvos" { Self.listReads += 1 }
      if method == "chat.bsky.convo.getMessages" {
        Self.messageReads += 1
        if Self.failMessages {
          return (503, Data(#"{"error":"ServiceUnavailable","message":"Local messages service unavailable"}"#.utf8))
        }
        if Self.useRecoveredMessages { return (200, Self.recoveredMessages) }
      }
      return (200, data)
    }
    guard let (status, data) = result else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Read-only diagnostics of the real route manager and request counts.
private struct MessagesNavigationProbe: UIViewRepresentable {
  let account: AppState
  let scene: SceneNavigationContext
  let selectedTab: Int
  let deliveredLinks: Int

  func makeUIView(context: Context) -> ProbeView { ProbeView() }
  func updateUIView(_ uiView: ProbeView, context: Context) {
    uiView.account = account
    uiView.scene = scene
    uiView.selectedTab = selectedTab
    uiView.deliveredLinks = deliveredLinks
    uiView.publish()
  }
  static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) { uiView.stop() }

  @MainActor
  final class ProbeView: UIView {
    weak var account: AppState?
    weak var scene: SceneNavigationContext?
    var selectedTab = AppNavigationManager.chatTabIndex
    var deliveredLinks = 0
    private var timer: Timer?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      stop()
      guard window != nil else { return }
      isAccessibilityElement = true
      accessibilityIdentifier = "messages-navigation.probe"
      accessibilityLabel = "Messages navigation state"
      accessibilityTraits = .staticText
      isUserInteractionEnabled = false
      timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.publish() }
      }
      publish()
    }

    func stop() { timer?.invalidate(); timer = nil }
    func publish() {
      guard let scene, let account else { return }
      let counts = MessagesNavigationProtocol.counts
      let value: [String: Any] = [
        "selectedTab": selectedTab,
        "chatDepth": scene.navigationManager.tabPaths[AppNavigationManager.chatTabIndex]?.count ?? 0,
        "pendingConversation": scene.navigationManager.targetConversationId ?? "",
        "activeConversation": account.chatManager.activeConversationId ?? "",
        "deliveredLinks": deliveredLinks,
        "listReads": counts.lists,
        "messageReads": counts.messages,
        "writes": counts.writes
      ]
      if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
        accessibilityValue = String(data: data, encoding: .utf8)
      }
    }
  }
}
#endif
