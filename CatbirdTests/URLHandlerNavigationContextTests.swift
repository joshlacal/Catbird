import Foundation
import XCTest
import Petrel
@testable import Catbird

final class URLHandlerNavigationContextTests: XCTestCase {
  @MainActor
  func testQueuedURLKeepsItsExplicitTabWhenAnotherRequestArrives() async {
    let handler = URLHandler()
    let delivered = expectation(description: "Both requests navigate")
    delivered.expectedFulfillmentCount = 2
    var deliveries: [(NavigationDestination, Int?)] = []
    handler.navigateAction = { destination, tabIndex in
      deliveries.append((destination, tabIndex))
      delivered.fulfill()
    }

    // No suspension between these calls: the first request's task cannot run
    // until the second request has been handled on this same main-actor turn.
    _ = handler.handle(URL(string: "bluesky://video-feed")!, tabIndex: 0)
    _ = handler.handle(URL(string: "tag://example")!, tabIndex: 1)

    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(deliveries.count, 2)
    XCTAssertEqual(deliveries.first { $0.0 == .videoFeed }?.1, 0)
    XCTAssertEqual(deliveries.first { $0.0 == .hashtag("example") }?.1, 1)
  }

  @MainActor
  func testQueuedURLKeepsItsTabWhenAnImplicitMentionArrives() async {
    let handler = URLHandler()
    let delivered = expectation(description: "Both requests navigate")
    delivered.expectedFulfillmentCount = 2
    var deliveries: [(NavigationDestination, Int?)] = []
    handler.navigateAction = { destination, tabIndex in
      deliveries.append((destination, tabIndex))
      delivered.fulfill()
    }

    _ = handler.handle(URL(string: "bluesky://video-feed")!, tabIndex: 3)
    _ = handler.handle(URL(string: "mention://routing-probe")!)

    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(deliveries.count, 2)
    XCTAssertEqual(deliveries.first { $0.0 == .videoFeed }?.1, 3)
    let mention = deliveries.first { $0.0 == .profile("routing-probe") }
    XCTAssertNotNil(mention)
    XCTAssertNil(mention?.1)
  }

  @MainActor
  func testTabSelectionUpdatesContextBeforeTheNextImplicitURL() async {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:routingcontext12345678", client: client)
    let context = SceneNavigationContext(appState: appState, sceneID: UUID())
    let manager = context.navigationManager
    let handler = context.urlHandler
    var visibleTab = 0
    var currentTabDuringCallback: Int?
    var deliveredTab: Int?
    handler.navigateAction = { destination, tabIndex in
      deliveredTab = tabIndex
      manager.navigate(to: destination, in: tabIndex)
    }
    manager.registerTabSelectionCallback { index in
      visibleTab = index
      currentTabDuringCallback = manager.currentTabIndex
      _ = handler.handle(URL(string: "tag://after-selection")!)
    }

    manager.tabSelection?(2)

    XCTAssertEqual(visibleTab, 2)
    XCTAssertEqual(currentTabDuringCallback, 2)
    XCTAssertEqual(manager.currentTabIndex, 2)
    XCTAssertEqual(deliveredTab, 2)
    XCTAssertEqual(manager.tabPaths[2]?.count, 1)
    XCTAssertEqual(manager.tabPaths[0]?.count, 0)
    manager.tabSelection = nil
    handler.navigateAction = nil
  }

  @MainActor
  func testAsyncURLAndSynchronousCustomSchemesReceiveTheirOwnTabs() async {
    let handler = URLHandler()
    var deliveries: [(NavigationDestination, Int?)] = []
    handler.navigateAction = { destination, tabIndex in
      deliveries.append((destination, tabIndex))
    }

    let videoHandled = await handler.handleURL(URL(string: "bluesky://video-feed")!, tabIndex: 4)
    let tagHandled = await handler.handleURL(URL(string: "tag://async-tag")!, tabIndex: 1)
    let mentionHandled = await handler.handleURL(URL(string: "mention://async-mention")!, tabIndex: 2)

    XCTAssertTrue(videoHandled && tagHandled && mentionHandled)
    XCTAssertEqual(deliveries.count, 3)
    XCTAssertEqual(deliveries.first { $0.0 == .videoFeed }?.1, 4)
    XCTAssertEqual(deliveries.first { $0.0 == .hashtag("async-tag") }?.1, 1)
    XCTAssertEqual(deliveries.first { $0.0 == .profile("async-mention") }?.1, 2)
  }

  @MainActor
  func testRegisteredTabCallbackDoesNotRetainNavigationManager() {
    var manager: AppNavigationManager? = AppNavigationManager()
    weak var weakManager: AppNavigationManager?
    weakManager = manager
    manager?.registerTabSelectionCallback { _ in }
    let retainedCallback = manager?.tabSelection

    manager = nil

    XCTAssertNotNil(retainedCallback)
    XCTAssertNil(weakManager)
  }
}
