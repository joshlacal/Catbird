#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Feed header environment")
struct FeedHeaderEnvironmentTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @MainActor
  private final class RenderReceipt {
    var count = 0
    var appState: AppState?
    var sceneContext: SceneNavigationContext?
    var fontManager: FontManager?
  }

  /// Deliberately has no environment modifiers. The production header cell must
  /// provide these values at its UIHostingConfiguration boundary.
  @MainActor
  private struct EnvironmentProbe: View {
    @Environment(AppState.self) private var appState
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(\.fontManager) private var fontManager
    let receipt: RenderReceipt

    var body: some View {
      Text("Header \(appState.userDID) · \(sceneContext.sceneID.uuidString)")
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(12)
        .accessibilityIdentifier("feed-header-environment-probe")
        .onAppear {
          receipt.appState = appState
          receipt.sceneContext = sceneContext
          receipt.fontManager = fontManager
          receipt.count += 1
        }
    }
  }

  @Test("The real feed header renders its account and scene environments from a UIKit root")
  @MainActor
  func headerReceivesAccountAndSceneWhenRendered() async throws {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://feed-header-environment.invalid")))
    let appState = AppState(userDID: "did:plc:feedheaderenvironment", client: client,
      regulatoryChecker: NoAgePrompt())
    let sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
    let viewport = sceneContext.feedViewportStore.state(accountDID: appState.userDID,
      feedIdentifier: FetchType.timeline.identifier)
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    model.posts = [try makeLocalPost()]
    let state = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline,
      initialScenePhase: .background)
    state.hasReachedEnd = true
    let controller = FeedCollectionViewControllerIntegrated(stateManager: state,
      viewportState: viewport, sceneContext: sceneContext, navigationPath: .constant(NavigationPath()))
    let receipt = RenderReceipt()
    controller.setHeaderView(AnyView(EnvironmentProbe(receipt: receipt)))

    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
    window.backgroundColor = .systemBackground
    // A UIKit root supplies no outer SwiftUI environment to the feed controller.
    window.rootViewController = controller
    controller.loadViewIfNeeded()
    controller.collectionView.isPrefetchingEnabled = false
    window.isHidden = false
    defer {
      let becameKey = window.isKeyWindow
      window.isHidden = true
      window.rootViewController = nil
      state.cleanup()
      sceneContext.invalidate()
      appState.cleanup()
      if becameKey { previousKeyWindow?.makeKey() }
    }

    await controller.performUpdate()
    let headerIndex = IndexPath(item: 0, section: 0)
    try await waitForRenderedHeader(controller: controller, window: window, receipt: receipt)

    // These identities come from the rendered probe's onAppear, not its initializer.
    #expect(receipt.count > 0, "The SwiftUI header must actually appear in its collection cell")
    #expect(receipt.appState === appState)
    #expect(receipt.sceneContext === sceneContext)
    #expect(receipt.fontManager === appState.fontManager)
    #expect(controller.collectionView.numberOfItems(inSection: 0) == 3,
      "The production snapshot must contain the header, one local post and the pagination footer")
    let headerCell = try #require(controller.collectionView.cellForItem(at: headerIndex))
    #expect(headerCell.contentConfiguration != nil)
    #expect(headerCell.window === window)
    let renderedFrame = headerCell.convert(headerCell.bounds, to: window)
    #expect(renderedFrame.width > 0 && renderedFrame.height > 0 && renderedFrame.intersects(window.bounds),
      "The environment probe must belong to a visible, laid-out header cell")
  }

  @MainActor
  private func waitForRenderedHeader(
    controller: FeedCollectionViewControllerIntegrated, window: UIWindow, receipt: RenderReceipt
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      controller.view.layoutIfNeeded()
      controller.collectionView.layoutIfNeeded()
      if receipt.count > 0,
         let cell = controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)),
         cell.window === window, cell.bounds.height > 0 {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeLocalPost() throws -> CachedFeedViewPost {
    let timestamp = ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:headerfixtureauthor"),
      handle: try Handle(handleString: "header-author.test"), displayName: "Header fixture",
      pronouns: nil, avatar: nil, associated: nil, viewer: nil, labels: nil,
      createdAt: nil, verification: nil, status: nil, debug: nil)
    let record = AppBskyFeedPost(text: "Local post keeps the production scrolling header visible.",
      entities: nil, facets: nil, reply: nil, embed: nil, langs: nil, labels: nil,
      tags: nil, createdAt: timestamp)
    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:headerfixtureauthor/app.bsky.feed.post/header"),
      cid: CID.fromDAGCBOR(Data("feed-header-environment".utf8)), author: author,
      record: .knownType(record), embed: nil, bookmarkCount: nil,
      replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
      indexedAt: timestamp, viewer: nil, labels: nil, threadgate: nil, debug: nil)
    let feedPost = AppBskyFeedDefs.FeedViewPost(post: post, reply: nil, reason: nil,
      feedContext: nil, reqId: nil)
    return try #require(CachedFeedViewPost(from: feedPost, feedType: "timeline"))
  }
}
#endif
