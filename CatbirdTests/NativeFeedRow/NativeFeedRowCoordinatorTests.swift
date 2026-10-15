#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Native feed row coordinator", .serialized)
struct NativeFeedRowCoordinatorTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  /// A coordinator for a signed-in account that is not connected to any server.
  @MainActor
  private final class Fixture {
    let appState: AppState
    let sceneContext: SceneNavigationContext
    let coordinator: NativeFeedRowCoordinator
    let traits = UITraitCollection { traits in
      traits.horizontalSizeClass = .compact
      traits.displayScale = 3
    }

    init() async throws {
      let client = await ATProtoClient(baseURL: try #require(URL(string: "https://native-row-coordinator.invalid")))
      appState = AppState(userDID: "did:plc:nativerowcoordinator", client: client, regulatoryChecker: NoAgePrompt())
      sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
      coordinator = NativeFeedRowCoordinator(
        navigationPath: .constant(NavigationPath()), appState: appState, sceneContext: sceneContext)
    }

    func show(_ posts: [CachedFeedViewPost]) {
      let byID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
      coordinator.beginSnapshot(posts: byID, signatures: byID.mapValues(FeedPostContentSignature.init), traits: traits)
    }

    func tearDown() {
      sceneContext.invalidate()
      appState.cleanup()
    }
  }

  @Test("A blank display name shows the handle alone and no badge, as the hosted header does")
  func blankDisplayNameHidesBadge() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let named = try FeedRowTestPosts.cachedPost(
      displayName: "Alice Rivera", postKey: "named", authorDID: VerificationBadge.selfVerifiedDID)
    let blank = try FeedRowTestPosts.cachedPost(
      displayName: "   ", postKey: "blank", authorDID: VerificationBadge.selfVerifiedDID)
    fixture.show([named, blank])

    let namedRow = try #require(fixture.coordinator.nativeRow(forPostID: named.id))
    #expect(namedRow.displayName == "Alice Rivera")
    #expect(namedRow.verification == .regular)
    #expect(namedRow.handle == "@author.test")

    let blankRow = try #require(fixture.coordinator.nativeRow(forPostID: blank.id))
    #expect(blankRow.displayName.isEmpty)
    #expect(blankRow.verification == nil)
    let content = try #require(fixture.coordinator.content(for: blankRow, width: 402))
    #expect(content.layout.badgeFrame == nil)
    #expect(content.layout.handleFrame?.minX == content.layout.nameFrame.minX)
  }

  @Test("Hiding verification badges removes the badge and the space reserved for it")
  func hiddenBadges() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost(displayName: "Alice Rivera", authorDID: VerificationBadge.selfVerifiedDID)
    fixture.show([post])
    let shown = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    #expect(try #require(fixture.coordinator.content(for: shown, width: 402)).layout.badgeFrame != nil)

    fixture.appState.preferencesManager.hideVerificationBadges = true
    fixture.show([post])
    let hidden = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    #expect(hidden.verification == nil)
    let content = try #require(fixture.coordinator.content(for: hidden, width: 402))
    #expect(content.verification == nil)
    #expect(content.layout.badgeFrame == nil)
  }

  @Test("A post whose row kind changes needs a reload, not a reconfigure")
  func kindChangeNeedsReload() async throws {
    let fixture = try await Fixture()
    defer {
      UserDefaults.standard.removeObject(forKey: "nativeFeedRowsDisabled")
      fixture.tearDown()
    }
    let post = try FeedRowTestPosts.cachedPost()
    fixture.show([post])
    #expect(fixture.coordinator.nativeRow(forPostID: post.id) != nil)
    fixture.coordinator.recordDequeue(postID: post.id, native: true)
    #expect(!fixture.coordinator.cellKindChanges(postID: post.id))

    UserDefaults.standard.set(true, forKey: "nativeFeedRowsDisabled")
    fixture.show([post])
    guard case .hosted(.disabled)? = fixture.coordinator.decision(forPostID: post.id) else {
      Issue.record("The switch must send the post to the hosted row")
      return
    }
    #expect(fixture.coordinator.cellKindChanges(postID: post.id))
    fixture.coordinator.recordDequeue(postID: post.id, native: false)
    #expect(!fixture.coordinator.cellKindChanges(postID: post.id))
  }

  @Test("Links are drawn as the hosted row's Text draws them for each link style", arguments: [
    (PostLinkPresentationStyle.color, PostLinkPresentationStyle.color, true),
    (.both, .both, true),
    (.disabled, .color, false),
    (.underline, .both, false),
  ])
  func linkPresentationMatchesHostedText(
    style: PostLinkPresentationStyle, drawnStyle: PostLinkPresentationStyle, usesAccent: Bool
  ) {
    let accent = UIColor.systemBlue
    let tint = UIColor.systemOrange
    let presentation = NativeFeedRowCoordinator.linkPresentation(for: style, accent: accent, tint: tint)
    #expect(presentation.style == drawnStyle)
    #expect(presentation.color == (usesAccent ? accent : tint))
  }

  @Test("Rows are laid out for the regular size class's centered content width")
  func regularWidthCentersContent() async throws {
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let post = try FeedRowTestPosts.cachedPost()
    let regular = UITraitCollection { traits in
      traits.horizontalSizeClass = .regular
      traits.displayScale = 2
    }
    let byID = [post.id: post]
    fixture.coordinator.beginSnapshot(posts: byID, signatures: byID.mapValues(FeedPostContentSignature.init), traits: regular)
    let row = try #require(fixture.coordinator.nativeRow(forPostID: post.id))
    let layout = try #require(fixture.coordinator.content(for: row, width: 1000)).layout
    #expect(layout.width == 1000)
    #expect(layout.avatarFrame.minX == 200 + FeedRowMetrics.rowHorizontal + FeedRowMetrics.avatarColumnInset + 3)
    #expect(layout.dividerFrame.width == 1000)
  }
}
#endif
