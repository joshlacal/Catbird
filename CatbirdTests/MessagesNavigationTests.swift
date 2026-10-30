import Foundation
import Petrel
import Testing
@testable import Catbird

#if os(iOS)
@Suite(.serialized)
@MainActor
struct MessagesNavigationTests {
  @Test func rootRequestClearsPendingConversationAndOnlyMessagesPath() {
    let manager = AppNavigationManager()
    manager.navigate(to: .hashtag("kept"), in: 1)
    manager.navigate(to: .profile("did:plc:detail"), in: 4)
    manager.targetConversationId = "conversation-a"

    manager.requestChatRoot()

    #expect(manager.targetConversationId == nil)
    #expect(manager.tabPaths[4]?.isEmpty == true)
    #expect(manager.tabPaths[1]?.count == 1)
    #expect(manager.consumeChatRootRequest())
    #expect(!manager.consumeChatRootRequest())
  }

  @Test func repeatedSameConversationTargetsAreConsumedOnceEach() {
    let manager = AppNavigationManager()
    for _ in 0..<2 {
      manager.navigate(to: .conversation("conversation-a"), in: 4)
      #expect(manager.consumeTargetConversation() == "conversation-a")
      #expect(manager.targetConversationId == nil)
      #expect(manager.consumeTargetConversation() == nil)
    }
  }

  @Test func latestExplicitDestinationWinsBeforeMessagesMounts() {
    let manager = AppNavigationManager()
    manager.requestChatRoot()
    manager.navigate(to: .conversation("conversation-a"), in: 4)
    #expect(!manager.consumeChatRootRequest())
    #expect(manager.consumeTargetConversation() == "conversation-a")

    // New-conversation and request-acceptance flows assign the target directly.
    manager.requestChatRoot()
    manager.targetConversationId = "conversation-b"
    #expect(!manager.consumeChatRootRequest())
    #expect(manager.consumeTargetConversation() == "conversation-b")

    manager.navigate(to: .conversation("conversation-a"), in: 4)
    manager.requestChatRoot()
    #expect(manager.consumeTargetConversation() == nil)
    #expect(manager.consumeChatRootRequest())
  }

  @Test func ordinaryTabSelectionPreservesNavigation() {
    let manager = AppNavigationManager()
    manager.navigate(to: .conversation("conversation-a"), in: 4)
    manager.updateCurrentTab(1)
    manager.updateCurrentTab(4)
    #expect(manager.chatRootRequestID == nil)
    #expect(manager.consumeTargetConversation() == "conversation-a")
  }

  @Test func messagesRootURLAndConversationURLKeepTheirDistinctIntent() async {
    let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)
    let appState = AppState(userDID: "did:plc:messagesroutingtest", client: client)
    let context = SceneNavigationContext(appState: appState, sceneID: UUID())
    defer { context.invalidate() }
    let manager = context.navigationManager
    var selectedTab = 0
    manager.registerTabSelectionCallback { selectedTab = $0 }

    #expect(await context.urlHandler.handleURL(URL(string: "https://bsky.app/messages/conversation-a")!))
    #expect(selectedTab == 4)
    #expect(manager.targetConversationId == "conversation-a")
    #expect(manager.chatRootRequestID == nil)

    manager.navigate(to: .profile("did:plc:detail"), in: 4)
    #expect(await context.urlHandler.handleURL(URL(string: "https://bsky.app/messages")!))
    #expect(manager.targetConversationId == nil)
    #expect(manager.tabPaths[4]?.isEmpty == true)
    #expect(manager.consumeChatRootRequest())

    #expect(await context.urlHandler.handleURL(URL(string: "bluesky://messages/conversation-b")!))
    #expect(manager.consumeTargetConversation() == "conversation-b")
    #expect(manager.chatRootRequestID == nil)
  }

  @Test func explicitSceneRootRequestClearsChatSelectionIntent() async {
    let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)
    let appState = AppState(userDID: "did:plc:messagesrootroutetest", client: client)
    let context = SceneNavigationContext(appState: appState, sceneID: UUID())
    let router = SceneRouteCoordinator()
    router.register(context)
    router.setActive(sceneID: context.sceneID, isActive: true)
    defer { router.disconnect(sceneID: context.sceneID) }
    context.navigationManager.targetConversationId = "conversation-a"

    let result = router.submit(SceneRouteRequest(accountDID: appState.userDID,
      command: .showTab(4, resetPath: true), preferredSceneID: context.sceneID))

    #expect(result == .delivered(sceneID: context.sceneID))
    #expect(context.navigationManager.targetConversationId == nil)
    #expect(context.navigationManager.consumeChatRootRequest())
  }
}
#endif
