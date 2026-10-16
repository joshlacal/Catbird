#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// Native rows in the production feed controller react to trait and setting changes while on screen.
@MainActor
@Suite("Native feed rows in the feed controller", .serialized)
struct NativeFeedRowControllerTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  private func makeAppState(_ name: String) async throws -> AppState {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://\(name).invalid")))
    return AppState(userDID: "did:plc:\(name)", client: client, regulatoryChecker: NoAgePrompt())
  }

  @Test("A horizontal size class change moves visible native rows into the hosted row's lane at once")
  func sizeClassChangeRelaysOutVisibleRows() async throws {
    let appState = try await makeAppState("nativerowsizeclass")
    defer { appState.cleanup() }
    let post = try FeedRowTestPosts.cachedPost(postKey: "sizeclass")
    let host = try NativeFeedRowControllerHost(appState: appState, posts: [post], width: 1000)
    defer { host.tearDown() }
    host.controller.traitOverrides.horizontalSizeClass = .compact
    await host.controller.performUpdate()
    let compact = try #require(try await host.waitForPostCell(NativeFeedPostCell.self))
    let m = FeedRowMetrics.self
    let fullLaneAvatarX = m.rowHorizontal + m.avatarColumnInset + (m.avatarColumnWidth - m.avatarSize) / 2
    #expect(compact.avatarViewForTesting.frame.minX == fullLaneAvatarX)

    // No snapshot is applied in between: the trait change itself must relay out the visible row.
    host.controller.traitOverrides.horizontalSizeClass = .regular
    host.window.layoutIfNeeded()
    let cell = try #require(host.controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeFeedPostCell)
    cell.layoutIfNeeded()
    let laneX = (1000 - m.maxRegularWidthContent) / 2
    #expect(cell.avatarViewForTesting.frame.minX == laneX + fullLaneAvatarX)
    #expect(cell.dividerForTesting.frame.width == 1000)
  }

  /// The cell provider only dequeues a native cell once a snapshot resolved the row settings; a
  /// row configured without them takes the bail-out path, which must not leave the reused cell
  /// showing its previous post.
  @Test("A native row configured without row settings shows none of the reused cell's text")
  func bailOutClearsReusedText() async throws {
    let appState = try await makeAppState("nativerowbailout")
    defer { appState.cleanup() }
    let sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
    defer { sceneContext.invalidate() }
    // A row decided by a coordinator whose settings are resolved.
    let deciding = NativeFeedRowCoordinator(
      navigationPath: .constant(NavigationPath()), appState: appState, sceneContext: sceneContext)
    let post = try FeedRowTestPosts.cachedPost(postKey: "bailout")
    let byID = [post.id: post]
    deciding.beginSnapshot(
      posts: byID, signatures: byID.mapValues(FeedPostContentSignature.init),
      traits: UITraitCollection { traits in traits.displayScale = 3 })
    let row = try #require(deciding.nativeRow(forPostID: post.id))

    // A controller that has applied no snapshot has no row settings.
    let viewport = sceneContext.feedViewportStore.state(
      accountDID: appState.userDID, feedIdentifier: FetchType.timeline.identifier)
    let model = FeedModel(feedManager: FeedManager(client: nil, fetchType: .timeline), appState: appState)
    let state = FeedStateManager(appState: appState, feedModel: model, feedType: .timeline, initialScenePhase: .background)
    defer { state.cleanup() }
    let controller = FeedCollectionViewControllerIntegrated(
      stateManager: state, viewportState: viewport, sceneContext: sceneContext,
      navigationPath: .constant(NavigationPath()))
    controller.loadViewIfNeeded()
    try #require(controller.nativeRowsForTesting.typography == nil)

    let (cell, previous) = try NativeFeedRowTestFactory.configuredCell(text: "the previous post")
    cell.prepareForReuse()
    try #require(cell.textViewForTesting.attributedText === previous.text)
    controller.configureNativeCellForTesting(cell, row: row)
    #expect(cell.textViewForTesting.attributedText == nil)
    #expect(cell.postURI == nil)
  }

  @Test("Hiding verification badges while rows are on screen removes the badge from them")
  func hidingBadgesReconfiguresVisibleRows() async throws {
    let appState = try await makeAppState("nativerowbadges")
    defer { appState.cleanup() }
    let post = try FeedRowTestPosts.cachedPost(
      displayName: "Alice Rivera", postKey: "badges", authorDID: VerificationBadge.selfVerifiedDID)
    let host = try NativeFeedRowControllerHost(appState: appState, posts: [post])
    defer { host.tearDown() }
    await host.controller.performUpdate()
    let shown = try #require(try await host.waitForPostCell(NativeFeedPostCell.self))
    #expect(!shown.headerViewForTesting.badgeViewForTesting.isHidden)

    appState.preferencesManager.hideVerificationBadges = true
    let hidden = try await host.waitForPostCell(NativeFeedPostCell.self) {
      $0.headerViewForTesting.badgeViewForTesting.isHidden
    }
    #expect(hidden != nil)
  }
}
#endif
