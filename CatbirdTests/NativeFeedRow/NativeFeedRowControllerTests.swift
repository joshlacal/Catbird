#if os(iOS)
import Foundation
import Petrel
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
