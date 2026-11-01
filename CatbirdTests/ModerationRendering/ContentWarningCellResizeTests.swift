#if os(iOS)
import Darwin
import Foundation
import Petrel
import QuartzCore
import SwiftUI
import Testing
import UIKit

@testable import Catbird

@Observable
fileprivate final class ContentWarningGateTriggerModel {
  var isExpanded = false
}

@MainActor
@Suite("Content-warning 1-frame top-anchored cell resize", .serialized)
struct ContentWarningCellResizeTests {
  private typealias F = RenderingFixtures

  private static let proMotionFrameBudgetMs: Double = 8.33

  /// Measures actual CPU milliseconds executed on the calling thread via `CLOCK_THREAD_CPUTIME_ID`,
  /// avoiding false spikes from host OS scheduler preemption when parallel builds share the machine.
  private static func measureThreadCPUMs(_ body: () -> Void) -> Double {
    let startNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    let endNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    return Double(endNs &- startNs) / 1_000_000.0
  }

  /// Collects any active CoreAnimation keys other than opacity/contents in `layer`'s subtree,
  /// ignoring UIRefreshControl's built-in spinner CAReplicatorLayer instanceAlphaOffset.
  private static func nonFadeAnimationKeys(in layer: CALayer) -> [String] {
    if layer.delegate is UIRefreshControl {
      return []
    }
    var result: [String] = []
    if let keys = layer.animationKeys() {
      for key in keys
      where key != "opacity" && key != "contents"
        && key != "instanceAlphaOffset" && key != "contentsMultiplyColor" {
        result.append("\(type(of: layer)):\(key)")
      }
    }
    for sublayer in layer.sublayers ?? [] {
      result.append(contentsOf: nonFadeAnimationKeys(in: sublayer))
    }
    return result
  }

  /// Collects minimum layer opacity across `layer`'s subtree.
  private static func minimumSubtreeOpacity(in layer: CALayer) -> Float {
    var minOpacity = layer.opacity
    for sublayer in layer.sublayers ?? [] {
      minOpacity = min(minOpacity, minimumSubtreeOpacity(in: sublayer))
    }
    return minOpacity
  }

  /// Returns true if any layer in `layer`'s subtree currently carries an `"opacity"` animation.
  private static func hasOpacityAnimation(in layer: CALayer) -> Bool {
    if layer.animationKeys()?.contains("opacity") == true {
      return true
    }
    for sublayer in layer.sublayers ?? [] where hasOpacityAnimation(in: sublayer) {
      return true
    }
    return false
  }

  private static func makeSceneWindow(size: CGSize = CGSize(width: 390, height: 844)) throws -> UIWindow {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    return window
  }

  private static func makeAppState(did: String = "did:plc:cwresizetest") async throws -> AppState {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://cw-resize-test.invalid")))
    return AppState(userDID: did, client: client)
  }

  /// UIKit-backed media surface (mirrors real video/web media CALayer hosting inside ModerationMediaGate).
  private struct UIKitMediaProbeView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.backgroundColor = .systemIndigo
      return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
  }

  /// Hosted row matching production feed structure: header + ModerationMediaGate + action bar + divider.
  private struct HostedMediaGateRow: View {
    let ui: ModerationUI
    let postURI: String
    let revealedMediaHeight: CGFloat

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Circle().fill(Color.blue).frame(width: 42, height: 42)
          VStack(alignment: .leading, spacing: 2) {
            Text("Reposted by Cara").font(.caption).foregroundStyle(.secondary)
            Text("Alice Rivera · @alice.test").font(.subheadline.bold())
            Text("Header and body text above the content warning gate must stay frozen at 0.0 pt delta.")
              .font(.body)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        ModerationMediaGate(ui: ui) {
          UIKitMediaProbeView()
            .frame(maxWidth: .infinity)
            .frame(height: revealedMediaHeight)
        }
        HStack {
          Text("Reply 2")
          Spacer()
          Text("Repost 1")
          Spacer()
          Text("Like 5")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        Divider()
      }
      .padding(.horizontal, 12)
      .padding(.top, 9)
      .environment(\.moderationRevealSubject, postURI)
      .environment(\.postID, postURI)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Polls `AppAccessibility.elements(in:)` (caller must hold `AppAccessibility.enable()`) until a matching
  /// hosted SwiftUI accessibility element materializes.
  private static func waitForAccessibilityElement(
    in rootView: UIView,
    where predicate: (AppAccessibility.Element) -> Bool
  ) async -> AppAccessibility.Element? {
    for _ in 0..<40 {
      rootView.window?.layoutIfNeeded()
      rootView.layoutIfNeeded()
      if let match = AppAccessibility.elements(in: rootView).first(where: predicate) {
        return match
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
  }

  /// Controllable gate wrapper that exercises `withoutRevealAnimation` + `\.invalidateFeedRowHeight`
  /// identically to `ModerationMediaGate.setRevealed` / `ModerationContentGate.setRevealed`
  /// so tests can trigger deterministic synchronous taps without depending on VoiceOver server state.
  private struct ControllableGatedPostRow: View {
    let model: ContentWarningGateTriggerModel
    let collapsedGateHeight: CGFloat
    let expandedGateHeight: CGFloat
    @Environment(\.invalidateFeedRowHeight) private var invalidateFeedRowHeight

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Circle().fill(Color.blue).frame(width: 42, height: 42)
          VStack(alignment: .leading, spacing: 2) {
            Text("Reposted by Cara").font(.caption)
            Text("Alice Rivera · @alice.test").font(.subheadline.bold())
            Text("Above-gate post text stays completely stationary on Show and Hide.")
              .font(.body)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if model.isExpanded {
          Rectangle()
            .fill(Color.teal)
            .frame(maxWidth: .infinity)
            .frame(height: expandedGateHeight)
            .overlay(alignment: .topTrailing) {
              Text("Hide").padding(8)
            }
            .postRevealFade(isEnabled: true)
        } else {
          RoundedRectangle(cornerRadius: 12)
            .fill(Color(uiColor: .systemGray6))
            .frame(maxWidth: .infinity)
            .frame(height: collapsedGateHeight)
        }
        HStack {
          Text("Reply 2")
          Spacer()
          Text("Like 5")
        }
        .font(.footnote)
        Divider()
      }
      .padding(.horizontal, 12)
      .padding(.top, 9)
      .fixedSize(horizontal: false, vertical: true)
    }

    @MainActor
    static func setExpanded(
      _ expanded: Bool,
      model: ContentWarningGateTriggerModel,
      invalidate: (() -> Void)?
    ) {
      withoutRevealAnimation {
        model.isExpanded = expanded
      }
      invalidate?()
    }
  }

  @Test("FeedPostCollectionViewCell resizes in 1 frame with 0pt top jump at top AND when partially scrolled under nav bar (< 8.33ms)")
  func compositionalListCellTopAnchoredOneFrameResize() async throws {
    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.showsSeparators = false
    let collectionView = UICollectionView(
      frame: window.bounds,
      collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfig)
    )
    collectionView.contentInset = UIEdgeInsets(top: 96, left: 0, bottom: 34, right: 0)

    let targetIndex = 1
    let gateModel = ContentWarningGateTriggerModel()
    let heightCache = FeedRowHeightCache()
    var targetInvalidate: (() -> Void)?

    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, index in
      cell.heightCache = heightCache
      cell.postID = "at://did:plc:test/app.bsky.feed.post/\(index)"
      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        CollectionViewCellResizeAnchor.performTopAnchoredResize(
          in: collectionView,
          for: cell
        ) {
          if let postID = cell?.postID {
            heightCache.invalidate(postID: postID)
          }
          cell?.markHeightNeedsRecalculation()
        }
      }
      if index == targetIndex {
        targetInvalidate = invalidate
      }
      cell.contentConfiguration = UIHostingConfiguration {
        Group {
          if index == targetIndex {
            ControllableGatedPostRow(
              model: gateModel,
              collapsedGateHeight: 168,
              expandedGateHeight: 428
            )
          } else {
            Text("Feed post row #\(index) with two lines of ordinary timeline text for realistic spacing.")
              .font(.body)
              .padding(16)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .environment(appState)
        .environment(\.fontManager, appState.fontManager)
        .environment(\.invalidateFeedRowHeight, invalidate)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let vc = UIViewController()
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems(Array(0..<20))
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    let targetIndexPath = IndexPath(item: targetIndex, section: 0)
    let belowIndexPath = IndexPath(item: targetIndex + 1, section: 0)
    let cell = try #require(collectionView.cellForItem(at: targetIndexPath) as? FeedPostCollectionViewCell)
    let belowCell = try #require(collectionView.cellForItem(at: belowIndexPath))
    let invalidate = try #require(targetInvalidate)

    // Case A: Cell fully visible below navigation bar inset.
    let collapsedHeight = cell.frame.height
    let anchorViewportY = cell.frame.minY - collectionView.contentOffset.y
    let initialBelowViewportY = belowCell.frame.minY - collectionView.contentOffset.y

    let showDurationMs = Self.measureThreadCPUMs {
      ControllableGatedPostRow.setExpanded(true, model: gateModel, invalidate: invalidate)
    }

    // Synchronous 0-extra-frame assertions (before yielding runloop!).
    let expandedHeight = cell.frame.height
    let expectedDelta: CGFloat = 428 - 168
    let updatedBelowCell = try #require(collectionView.cellForItem(at: belowIndexPath))
    #expect(abs((expandedHeight - collapsedHeight) - expectedDelta) < 1.5,
      "Cell height must step by +260pt synchronously on Show, got \(expandedHeight - collapsedHeight)")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05,
      "Header/top of cell must stay frozen at 0.0pt viewport delta on Show")
    #expect(abs((updatedBelowCell.frame.minY - collectionView.contentOffset.y) - (initialBelowViewportY + expectedDelta)) < 1.5,
      "Below row must step down by exact +delta in the same frame")
    #expect(!collectionView.layer.needsLayout(),
      "Collection view must have zero dirty layout left for CoreAnimation pre-commit")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty,
      "Zero non-opacity CAAnimations may be attached anywhere in collectionView")

    // Case B: Scroll so cell's top header/avatar are partially tucked UNDER the nav bar
    // (`cell.frame.minY < contentOffset.y + adjustedContentInset.top`), while the Hide/Show
    // region in the lower half of the cell remains on screen. This is the exact geometry
    // where UIKit previously anchored to `belowCell` and jumped `contentOffset.y` by +/-260pt!
    let partialUnderNavOffset = cell.frame.minY - collectionView.adjustedContentInset.top + 54
    collectionView.contentOffset = CGPoint(x: 0, y: partialUnderNavOffset)
    collectionView.layoutIfNeeded()
    #expect(cell.frame.minY < collectionView.contentOffset.y + collectionView.adjustedContentInset.top,
      "Cell top must be tucked under adjustedContentInset.top for partial-scroll test")

    let tuckedAnchorViewportY = cell.frame.minY - collectionView.contentOffset.y

    // Warm Hide + Show measurement under partial nav-bar tuck:
    let hideElapsedMs = Self.measureThreadCPUMs {
      ControllableGatedPostRow.setExpanded(false, model: gateModel, invalidate: invalidate)
    }

    #expect(abs(cell.frame.height - collapsedHeight) < 1.5,
      "Cell height must shrink synchronously on Hide")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - tuckedAnchorViewportY) < 0.05,
      "Partially tucked cell top must stay at 0.0pt viewport delta on Hide (no scroll jump)")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let secondShowElapsedMs = Self.measureThreadCPUMs {
      ControllableGatedPostRow.setExpanded(true, model: gateModel, invalidate: invalidate)
    }

    #expect(abs(cell.frame.height - expandedHeight) < 1.5,
      "Cell height must re-expand synchronously on Show while partially tucked")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - tuckedAnchorViewportY) < 0.05,
      "Partially tucked cell top must stay at 0.0pt viewport delta on Show (no +260pt jump)")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    print(
      "[ContentWarningCellResizeTests] coldShow=\(String(format: "%.2f", showDurationMs))ms "
        + "warmHide=\(String(format: "%.2f", hideElapsedMs))ms "
        + "warmShow=\(String(format: "%.2f", secondShowElapsedMs))ms (budget=\(Self.proMotionFrameBudgetMs)ms)"
    )
    #expect(hideElapsedMs < Self.proMotionFrameBudgetMs,
      "Synchronous Hide pass (\(hideElapsedMs)ms) must fit inside 120Hz ProMotion 8.33ms frame budget")
    #expect(secondShowElapsedMs < Self.proMotionFrameBudgetMs,
      "Synchronous Show pass (\(secondShowElapsedMs)ms) must fit inside 120Hz ProMotion 8.33ms frame budget")

    // Verify zero delayed pre-commit spring animations appear on subsequent runloop turn either.
    try await Task.sleep(for: .milliseconds(30))
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty,
      "No delayed pre-commit spring animations may attach after runloop turn")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - tuckedAnchorViewportY) < 0.05)
  }

  @Test("PostListCollectionController preserves invalidateFeedRowHeight inside hostingEnvironment and resizes top-anchored in 1 frame")
  func postListCollectionControllerTopAnchoredResize() async throws {
    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState(did: "did:plc:postlistresize")
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    let gateModel = ContentWarningGateTriggerModel()
    var capturedInvalidateFromChild: (() -> Void)?

    struct ChildProbeRow: View {
      let gateModel: ContentWarningGateTriggerModel
      let onCapture: ((() -> Void)?) -> Void
      @Environment(\.invalidateFeedRowHeight) private var invalidateFeedRowHeight

      var body: some View {
        ControllableGatedPostRow(
          model: gateModel,
          collapsedGateHeight: 160,
          expandedGateHeight: 380
        )
        .onAppear {
          onCapture(invalidateFeedRowHeight)
        }
      }
    }

    let entries: [PostListEntry] = try (0..<12).map { idx in
      let post = try F.post(uri: "at://did:web:bob.test/app.bsky.feed.post/row-\(idx)")
      return .post(EquatableBox(post))
    }
    let targetEntryID = entries[1].id

    let controller = PostListCollectionController()
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    controller.loadViewIfNeeded()

    var baseEnv = EnvironmentValues()
    baseEnv.invalidateFeedRowHeight = nil // Must NOT overwrite PostListCollectionController's per-cell closure!

    controller.applySwiftUIUpdate {
      controller.hostingEnvironment = baseEnv
      controller.appState = appState
      controller.headerView = AnyView(Color.gray.frame(height: 120))
      controller.pinnedHeaderView = AnyView(Color.blue.frame(height: 44))
      controller.rowViewBuilder = { entry in
        if entry.id == targetEntryID {
          return AnyView(
            ChildProbeRow(gateModel: gateModel) { captured in
              capturedInvalidateFromChild = captured
            }
          )
        }
        return AnyView(
          Text("Profile post \(entry.id)")
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        )
      }
      controller.setEntries(entries, hasMore: false, isLoadingMore: false, footerState: .hidden)
    }

    for _ in 0..<8 {
      try await Task.sleep(for: .milliseconds(25))
      window.layoutIfNeeded()
      controller.view.layoutIfNeeded()
    }

    let invalidate = try #require(
      capturedInvalidateFromChild,
      "PostListCollectionController must inject non-nil invalidateFeedRowHeight inside hostingEnvironment"
    )

    // Scroll so header pins and row 1 is partially under the pinned header.
    let collectionView = try #require(controller.collectionView)
    let rowIndexPath = IndexPath(item: 1, section: 1)
    let cell = try #require(collectionView.cellForItem(at: rowIndexPath))
    collectionView.contentOffset = CGPoint(x: 0, y: cell.frame.minY - 20)
    collectionView.layoutIfNeeded()

    let beforeHeight = cell.frame.height
    let anchorViewportY = cell.frame.minY - collectionView.contentOffset.y

    ControllableGatedPostRow.setExpanded(true, model: gateModel, invalidate: invalidate)

    #expect(abs((cell.frame.height - beforeHeight) - 220) < 1.5,
      "PostListCollectionController row must expand by +220pt synchronously in 1 frame")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05,
      "PostListCollectionController row top must remain anchored at 0.0pt delta on Show")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    ControllableGatedPostRow.setExpanded(false, model: gateModel, invalidate: invalidate)

    #expect(abs(cell.frame.height - beforeHeight) < 1.5,
      "PostListCollectionController row must shrink back by -220pt synchronously in 1 frame")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05,
      "PostListCollectionController row top must remain anchored at 0.0pt delta on Hide")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }

  @Test("MainPostCell, ThreadRowCell, and BlockedAnchorCell wire invalidateFeedRowHeight and resize top-anchored in 1 frame")
  func threadCellsWireInvalidateAndResizeInOneFrame() async throws {
    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState(did: "did:plc:threadresize")
    let sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    let layout = UICollectionViewCompositionalLayout { _, _ in
      let size = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .estimated(240)
      )
      let item = NSCollectionLayoutItem(layoutSize: size)
      let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
      return NSCollectionLayoutSection(group: group)
    }
    let collectionView = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
    collectionView.contentInset = UIEdgeInsets(top: 88, left: 0, bottom: 34, right: 0)
    collectionView.register(MainPostCell.self, forCellWithReuseIdentifier: "MainPostCell")
    collectionView.register(ThreadRowCell.self, forCellWithReuseIdentifier: "ThreadRowCell")
    collectionView.register(BlockedAnchorCell.self, forCellWithReuseIdentifier: "BlockedAnchorCell")
    collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "BottomSpacerCell")

    let mainURI = "at://did:web:bob.test/app.bsky.feed.post/threadmain-\(UUID().uuidString)"
    let replyURI = "at://did:web:bob.test/app.bsky.feed.post/threadreply-\(UUID().uuidString)"
    let blockedURI = try ATProtocolURI(uriString: "at://did:plc:blockedanchor/app.bsky.feed.post/blocked1")

    let mainPost = try F.post(
      uri: mainURI,
      labels: [try F.label("!warn", uri: mainURI)],
      embed: F.imageEmbed
    )
    let replyPost = try F.post(
      uri: replyURI,
      labels: [try F.label("!warn", uri: replyURI)],
      embed: F.imageEmbed
    )
    let mainModeration = PostModerationPresentation.make(post: mainPost, policy: appState.moderationPolicy)
    let replyModeration = PostModerationPresentation.make(post: replyPost, policy: appState.moderationPolicy)
    #expect(mainModeration.concealsBody)
    #expect(replyModeration.concealsBody)

    let anchorThreadItem = AppBskyUnspeccedGetPostThreadV2.ThreadItem(
      uri: mainPost.uri,
      depth: 0,
      value: .appBskyUnspeccedDefsThreadItemPost(
        AppBskyUnspeccedDefs.ThreadItemPost(
          post: mainPost,
          moreParents: false,
          moreReplies: 0,
          opThread: false,
          opThreadPostIndex: nil,
          opThreadPostCount: nil,
          hiddenByThreadgate: false,
          mutedByViewer: false
        )
      )
    )
    let replyThreadItem = AppBskyUnspeccedGetPostThreadV2.ThreadItem(
      uri: replyPost.uri,
      depth: 1,
      value: .appBskyUnspeccedDefsThreadItemPost(
        AppBskyUnspeccedDefs.ThreadItemPost(
          post: replyPost,
          moreParents: false,
          moreReplies: 0,
          opThread: false,
          opThreadPostIndex: nil,
          opThreadPostCount: nil,
          hiddenByThreadgate: false,
          mutedByViewer: false
        )
      )
    )
    let builtRows = ThreadRowBuilder.build(
      items: [anchorThreadItem, replyThreadItem].map(ThreadRowBuilder.Item.init),
      mode: .linear,
      maxIndentLevels: ThreadReplyGeometry.compactMaxIndentLevels
    )
    let replyRow = try #require(builtRows.last)
    let blockedAnchor = AppBskyUnspeccedDefs.ThreadItemBlocked(
      author: AppBskyFeedDefs.BlockedAuthor(
        did: try DID(didString: "did:plc:blockedanchor"),
        viewer: AppBskyActorDefs.ViewerState(blockedBy: true)
      )
    )

    var path = NavigationPath()
    let pathBinding = Binding(get: { path }, set: { path = $0 })
    var mainPostInvalidateCount = 0
    var threadRowInvalidateCount = 0
    var blockedAnchorInvalidateCount = 0
    var lastMainResizeCPUMs: Double = 0
    var lastReplyResizeCPUMs: Double = 0

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      switch item {
      case 0:
        guard let cell = cv.dequeueReusableCell(
          withReuseIdentifier: "MainPostCell",
          for: indexPath
        ) as? MainPostCell else {
          return UICollectionViewCell()
        }
        cell.configure(
          post: mainPost,
          appState: appState,
          sceneContext: sceneContext,
          path: pathBinding,
          onInvalidateHeight: { [weak cv, weak cell] in
            mainPostInvalidateCount += 1
            lastMainResizeCPUMs = Self.measureThreadCPUMs {
              CollectionViewCellResizeAnchor.performTopAnchoredResize(in: cv, for: cell)
            }
          }
        )
        return cell
      case 1:
        guard let cell = cv.dequeueReusableCell(
          withReuseIdentifier: "ThreadRowCell",
          for: indexPath
        ) as? ThreadRowCell else {
          return UICollectionViewCell()
        }
        cell.configure(
          row: replyRow,
          threadItem: replyThreadItem,
          parentAuthor: mainPost.author,
          appState: appState,
          sceneContext: sceneContext,
          path: pathBinding,
          onInvalidateHeight: { [weak cv, weak cell] in
            threadRowInvalidateCount += 1
            lastReplyResizeCPUMs = Self.measureThreadCPUMs {
              CollectionViewCellResizeAnchor.performTopAnchoredResize(in: cv, for: cell)
            }
          }
        )
        return cell
      case 2:
        guard let cell = cv.dequeueReusableCell(
          withReuseIdentifier: "BlockedAnchorCell",
          for: indexPath
        ) as? BlockedAnchorCell else {
          return UICollectionViewCell()
        }
        cell.configure(
          blocked: blockedAnchor,
          anchorURI: blockedURI,
          appState: appState,
          sceneContext: sceneContext,
          path: pathBinding,
          onInvalidateHeight: { [weak cv, weak cell] in
            blockedAnchorInvalidateCount += 1
            CollectionViewCellResizeAnchor.performTopAnchoredResize(in: cv, for: cell)
          }
        )
        return cell
      default:
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "BottomSpacerCell", for: indexPath)
        cell.contentConfiguration = UIHostingConfiguration {
          Color.clear.frame(height: 800)
        }
        .margins(.all, 0)
        return cell
      }
    }

    let vc = UIViewController()
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0, 1, 2, 3])
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<8 {
      try await Task.sleep(for: .milliseconds(25))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    let mainCell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? MainPostCell)
    let replyCell = try #require(collectionView.cellForItem(at: IndexPath(item: 1, section: 0)) as? ThreadRowCell)
    let blockedCell = try #require(collectionView.cellForItem(at: IndexPath(item: 2, section: 0)) as? BlockedAnchorCell)

    // Phase A (standard non-VoiceOver 120Hz ProMotion runtime mode, _AXSApplicationAccessibilityEnabled == false):
    // Verify warm 1-frame resize CPU cost stays strictly below 8.33ms on both MainPostCell and ThreadRowCell.
    collectionView.contentOffset = CGPoint(x: 0, y: mainCell.frame.minY - collectionView.adjustedContentInset.top + 32)
    collectionView.layoutIfNeeded()
    let mainConcealedHeight = mainCell.frame.height
    let mainAnchorViewportY = mainCell.frame.minY - collectionView.contentOffset.y

    withoutRevealAnimation {
      ModerationRevealStore.shared.setRevealed(
        true, ui: mainModeration.body, gate: .body, subject: mainURI, accountDID: appState.userDID)
    }
    CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: mainCell)
    #expect(mainCell.frame.height > mainConcealedHeight + 60)
    #expect(abs((mainCell.frame.minY - collectionView.contentOffset.y) - mainAnchorViewportY) < 0.05)

    let mainProMotionHideCPUMs = Self.measureThreadCPUMs {
      withoutRevealAnimation {
        ModerationRevealStore.shared.setRevealed(
          false, ui: mainModeration.body, gate: .body, subject: mainURI, accountDID: appState.userDID)
      }
      CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: mainCell)
    }
    #expect(abs(mainCell.frame.height - mainConcealedHeight) < 2.0)
    #expect(abs((mainCell.frame.minY - collectionView.contentOffset.y) - mainAnchorViewportY) < 0.05)
    #expect(mainProMotionHideCPUMs < Self.proMotionFrameBudgetMs,
      "Warm MainPostCell 1-frame resize (\(mainProMotionHideCPUMs)ms CPU) must stay under 8.33ms ProMotion budget")

    collectionView.contentOffset = CGPoint(x: 0, y: replyCell.frame.minY - collectionView.adjustedContentInset.top + 28)
    collectionView.layoutIfNeeded()
    let replyConcealedHeight = replyCell.frame.height
    let replyAnchorViewportY = replyCell.frame.minY - collectionView.contentOffset.y

    withoutRevealAnimation {
      ModerationRevealStore.shared.setRevealed(
        true, ui: replyModeration.body, gate: .body, subject: replyURI, accountDID: appState.userDID)
    }
    CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: replyCell)
    #expect(replyCell.frame.height > replyConcealedHeight + 60)

    let replyProMotionHideCPUMs = Self.measureThreadCPUMs {
      withoutRevealAnimation {
        ModerationRevealStore.shared.setRevealed(
          false, ui: replyModeration.body, gate: .body, subject: replyURI, accountDID: appState.userDID)
      }
      CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: replyCell)
    }
    #expect(abs(replyCell.frame.height - replyConcealedHeight) < 2.0)
    #expect(abs((replyCell.frame.minY - collectionView.contentOffset.y) - replyAnchorViewportY) < 0.05)
    #expect(replyProMotionHideCPUMs < Self.proMotionFrameBudgetMs,
      "Warm ThreadRowCell 1-frame resize (\(replyProMotionHideCPUMs)ms CPU) must stay under 8.33ms ProMotion budget")

    // Phase B (enable AppAccessibility): genuinely activate VoiceOver controls across MainPostCell,
    // ThreadRowCell, and BlockedAnchorCell to verify end-to-end environment wiring and 0.0pt anchoring.
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }

    collectionView.contentOffset = CGPoint(x: 0, y: mainCell.frame.minY - collectionView.adjustedContentInset.top + 32)
    collectionView.layoutIfNeeded()

    let mainShowButton = try #require(
      await Self.waitForAccessibilityElement(in: mainCell.contentView) {
        $0.identifier == "moderation.contentGate.toggle" && $0.label == "Show"
      },
      "MainPostCell must expose moderation.contentGate.toggle Show button"
    )
    #expect(mainShowButton.object.accessibilityActivate())

    #expect(mainPostInvalidateCount == 1, "MainPostCell Show must invoke injected invalidateFeedRowHeight")
    #expect(mainCell.frame.height > mainConcealedHeight + 60,
      "MainPostCell must genuinely expand on Show (was \(mainConcealedHeight), now \(mainCell.frame.height))")
    #expect(abs((mainCell.frame.minY - collectionView.contentOffset.y) - mainAnchorViewportY) < 0.05,
      "Partially tucked MainPostCell top must remain anchored at 0.0pt jump on Show")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let mainHideButton = try #require(
      await Self.waitForAccessibilityElement(in: mainCell.contentView) {
        $0.identifier == "moderation.contentGate.toggle" && $0.label == "Hide"
      }
    )
    #expect(mainHideButton.object.accessibilityActivate())
    #expect(mainPostInvalidateCount == 2)
    #expect(abs(mainCell.frame.height - mainConcealedHeight) < 2.0,
      "MainPostCell must shrink back synchronously on Hide")
    #expect(abs((mainCell.frame.minY - collectionView.contentOffset.y) - mainAnchorViewportY) < 0.05,
      "Partially tucked MainPostCell top must remain anchored at 0.0pt jump on Hide")
    #expect(lastMainResizeCPUMs < 35.0,
      "Debug -Onone + AX MainPostCell Hide (\(lastMainResizeCPUMs)ms CPU) must stay bounded")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let mainWarmShowButton = try #require(
      await Self.waitForAccessibilityElement(in: mainCell.contentView) {
        $0.identifier == "moderation.contentGate.toggle" && $0.label == "Show"
      }
    )
    #expect(mainWarmShowButton.object.accessibilityActivate())
    #expect(mainPostInvalidateCount == 3)
    #expect(lastMainResizeCPUMs < 35.0,
      "Debug -Onone + AX MainPostCell Show materialization (\(lastMainResizeCPUMs)ms CPU) must stay bounded")
    #expect(abs((mainCell.frame.minY - collectionView.contentOffset.y) - mainAnchorViewportY) < 0.05)

    // 2. ThreadRowCell: genuinely activate ModerationContentGate Show & Hide while partially tucked under top inset.
    collectionView.contentOffset = CGPoint(x: 0, y: replyCell.frame.minY - collectionView.adjustedContentInset.top + 28)
    collectionView.layoutIfNeeded()

    let replyShowButton = try #require(
      await Self.waitForAccessibilityElement(in: replyCell.contentView) {
        $0.identifier == "moderation.contentGate.toggle" && $0.label == "Show"
      },
      "ThreadRowCell must expose moderation.contentGate.toggle Show button"
    )
    #expect(replyShowButton.object.accessibilityActivate())

    #expect(threadRowInvalidateCount == 1, "ThreadRowCell Show must invoke injected invalidateFeedRowHeight")
    #expect(replyCell.frame.height > replyConcealedHeight + 60,
      "ThreadRowCell must genuinely expand on Show (was \(replyConcealedHeight), now \(replyCell.frame.height))")
    #expect(abs((replyCell.frame.minY - collectionView.contentOffset.y) - replyAnchorViewportY) < 0.05,
      "Partially tucked ThreadRowCell top must remain anchored at 0.0pt jump on Show")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let replyHideButton = try #require(
      await Self.waitForAccessibilityElement(in: replyCell.contentView) {
        $0.identifier == "moderation.contentGate.toggle" && $0.label == "Hide"
      }
    )
    #expect(replyHideButton.object.accessibilityActivate())
    #expect(threadRowInvalidateCount == 2)
    #expect(abs(replyCell.frame.height - replyConcealedHeight) < 2.0,
      "ThreadRowCell must shrink back synchronously on Hide")
    #expect(abs((replyCell.frame.minY - collectionView.contentOffset.y) - replyAnchorViewportY) < 0.05,
      "Partially tucked ThreadRowCell top must remain anchored at 0.0pt jump on Hide")
    #expect(lastReplyResizeCPUMs < 35.0,
      "Debug -Onone + AX ThreadRowCell Hide (\(lastReplyResizeCPUMs)ms CPU) must stay bounded")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let replyWarmShowButton = try #require(
      await Self.waitForAccessibilityElement(in: replyCell.contentView) {
        $0.identifier == "moderation.contentGate.toggle" && $0.label == "Show"
      }
    )
    #expect(replyWarmShowButton.object.accessibilityActivate())
    #expect(threadRowInvalidateCount == 3)
    #expect(lastReplyResizeCPUMs < 35.0,
      "Debug -Onone + AX ThreadRowCell Show materialization (\(lastReplyResizeCPUMs)ms CPU) must stay bounded")
    #expect(abs((replyCell.frame.minY - collectionView.contentOffset.y) - replyAnchorViewportY) < 0.05)

    // 3. BlockedAnchorCell: verify hydration task + custom action ("Show identifier") invoke onInvalidateHeight cleanly.
    collectionView.contentOffset = CGPoint(x: 0, y: blockedCell.frame.minY - collectionView.adjustedContentInset.top + 16)
    collectionView.layoutIfNeeded()
    #expect(blockedAnchorInvalidateCount >= 1,
      "BlockedAnchorCell .task hydration settlement must invoke onInvalidateHeight")
    let blockedAnchorViewportY = blockedCell.frame.minY - collectionView.contentOffset.y
    let identityElement = try #require(
      await Self.waitForAccessibilityElement(in: blockedCell.contentView) {
        ($0.label ?? "").contains("Blocked account")
      },
      "BlockedAnchorCell must render BlockedContentCard identity row"
    )
    let showIdentifierAction = try #require(
      identityElement.object.accessibilityCustomActions?.first { $0.name == "Show identifier" },
      "Settled BlockedContentCard without profile must expose Show identifier custom action"
    )
    let preToggleCount = blockedAnchorInvalidateCount
    #expect(showIdentifierAction.target?.perform(showIdentifierAction.selector, with: showIdentifierAction) != nil
      || (showIdentifierAction.actionHandler?(showIdentifierAction) ?? false))
    #expect(blockedAnchorInvalidateCount == preToggleCount + 1,
      "BlockedAnchorCell identifier disclosure must invoke onInvalidateHeight")
    #expect(abs((blockedCell.frame.minY - collectionView.contentOffset.y) - blockedAnchorViewportY) < 0.05)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }

  @Test("Shrinking a cell near the bottom of a short list clamps contentOffset cleanly without overscroll")
  func bottomClampOnShrinkDoesNotOverscroll() async throws {
    let window = try Self.makeSceneWindow(size: CGSize(width: 390, height: 600))
    let appState = try await Self.makeAppState(did: "did:plc:bottomclamp")
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.showsSeparators = false
    let collectionView = UICollectionView(
      frame: window.bounds,
      collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfig)
    )

    let gateModel = ContentWarningGateTriggerModel()
    gateModel.isExpanded = true
    var invalidateClosure: (() -> Void)?

    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, index in
      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: cell)
      }
      if index == 1 { invalidateClosure = invalidate }
      cell.contentConfiguration = UIHostingConfiguration {
        Group {
          if index == 1 {
            ControllableGatedPostRow(
              model: gateModel,
              collapsedGateHeight: 160,
              expandedGateHeight: 520
            )
          } else {
            Color.gray.opacity(0.2).frame(height: 220)
          }
        }
        .environment(appState)
        .environment(\.fontManager, appState.fontManager)
        .environment(\.invalidateFeedRowHeight, invalidate)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let vc = UIViewController()
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0, 1])
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    let preShrinkContentHeight = collectionView.contentSize.height

    // Scroll all the way to the bottom while row 1 is 520pt tall.
    let preShrinkMaxOffset = max(
      -collectionView.adjustedContentInset.top,
      preShrinkContentHeight - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
    )
    collectionView.contentOffset = CGPoint(x: 0, y: preShrinkMaxOffset)
    collectionView.layoutIfNeeded()

    let invalidate = try #require(invalidateClosure)
    ControllableGatedPostRow.setExpanded(false, model: gateModel, invalidate: invalidate)

    #expect(collectionView.contentSize.height < preShrinkContentHeight - 300,
      "Content height must shrink by ~360pt synchronously (was \(preShrinkContentHeight), now \(collectionView.contentSize.height))")

    let postShrinkMaxOffset = max(
      -collectionView.adjustedContentInset.top,
      collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
    )
    #expect(collectionView.contentOffset.y <= postShrinkMaxOffset + 0.5,
      "Shrinking near bottom must clamp contentOffset.y (\(collectionView.contentOffset.y)) to maxOffset (\(postShrinkMaxOffset))")
    #expect(collectionView.contentOffset.y >= -collectionView.adjustedContentInset.top - 0.5)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }

  @Test("Reserved-aspect gate with unchanged height preserves off-screen estimated heights and contentOffset")
  func unchangedHeightGateDoesNotResetOffscreenEstimatedHeights() async throws {
    let window = try Self.makeSceneWindow(size: CGSize(width: 393, height: 600))
    let appState = try await Self.makeAppState(did: "did:plc:testviewerunchanged")
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(280)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
    let section = NSCollectionLayoutSection(group: group)
    let layout = UICollectionViewCompositionalLayout(section: section)
    let collectionView = UICollectionView(frame: window.bounds, collectionViewLayout: layout)

    let gateModel = ContentWarningGateTriggerModel()
    var invalidateClosure: (() -> Void)?

    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, index in
      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: cell)
      }
      if index == 3 { invalidateClosure = invalidate }
      cell.contentConfiguration = UIHostingConfiguration {
        Group {
          if index == 3 {
            ControllableGatedPostRow(
              model: gateModel,
              collapsedGateHeight: 240,
              expandedGateHeight: 240
            )
          } else {
            Color.gray.opacity(0.2).frame(height: 400)
          }
        }
        .environment(appState)
        .environment(\.fontManager, appState.fontManager)
        .environment(\.invalidateFeedRowHeight, invalidate)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let viewController = UIViewController()
    viewController.view.frame = window.bounds
    viewController.view.addSubview(collectionView)
    window.rootViewController = viewController
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0, 1, 2, 3, 4, 5])
    await dataSource.apply(snapshot, animatingDifferences: false)

    // Scroll through rows 0, 1, 2 so compositional layout resolves their 400pt heights
    // (120pt taller than the 280pt estimate), then park with rows 0..2 off-screen above.
    for stepOffset in [CGFloat(0), 400, 800, 1210] {
      collectionView.contentOffset = CGPoint(x: 0, y: stepOffset)
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(15))
    }

    let beforeOffsetY = collectionView.contentOffset.y
    let beforeContentHeight = collectionView.contentSize.height
    let targetCell = try #require(collectionView.cellForItem(at: IndexPath(item: 3, section: 0)))
    let beforeViewportY = targetCell.frame.minY - beforeOffsetY

    let invalidate = try #require(invalidateClosure)
    ControllableGatedPostRow.setExpanded(true, model: gateModel, invalidate: invalidate)

    #expect(abs(collectionView.contentOffset.y - beforeOffsetY) < 0.5,
      "Unchanged-height reveal must not alter contentOffset.y (was \(beforeOffsetY), now \(collectionView.contentOffset.y))")
    #expect(abs(collectionView.contentSize.height - beforeContentHeight) < 0.5,
      "Unchanged-height reveal must not reset off-screen solved heights (was \(beforeContentHeight), now \(collectionView.contentSize.height))")
    #expect(abs((targetCell.frame.minY - collectionView.contentOffset.y) - beforeViewportY) < 0.5)
  }

  @Test("ModerationMediaGate Hide pill and revealed media share opacity-only crossfade without floating at 1.0 over 0.0 media")
  func mediaGateHidePillAndContentShareOpacityOnlyRevealFade() async throws {
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }

    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState(did: "did:plc:hidepillfade")
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    let postURI = "at://did:web:bob.test/app.bsky.feed.post/fadecheck-\(UUID().uuidString)"
    let post = try F.post(uri: postURI, labels: [try F.label("porn", uri: postURI)], embed: F.imageEmbed)
    let mediaUI = PostModerationPresentation.make(post: post, policy: F.policy(labels: ["porn": "warn"])).media
    #expect(mediaUI.blur && !mediaUI.noOverride)

    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.showsSeparators = false
    let collectionView = UICollectionView(
      frame: window.bounds,
      collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfig)
    )

    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, _ in
      cell.postID = postURI
      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: cell)
      }
      cell.contentConfiguration = UIHostingConfiguration {
        HostedMediaGateRow(ui: mediaUI, postURI: postURI, revealedMediaHeight: 360)
          .environment(appState)
          .environment(\.fontManager, appState.fontManager)
          .environment(\.invalidateFeedRowHeight, invalidate)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let vc = UIViewController()
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0])
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    let cell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? FeedPostCollectionViewCell)
    let concealedHeight = cell.frame.height
    let anchorViewportY = cell.frame.minY - collectionView.contentOffset.y

    let showButton = try #require(
      await Self.waitForAccessibilityElement(in: cell.contentView) {
        $0.identifier == "moderation.mediaGate.show"
      }
    )
    #expect(showButton.object.accessibilityActivate())

    // Synchronously right after performTopAnchoredResize:
    // 1. Height expanded in 1 single frame; top anchor did not move; zero geometry animations.
    // 2. Both media AND Hide pill live inside PostRevealFadeModifier at opacity == 0 prior to fade kickoff.
    #expect(cell.frame.height > concealedHeight + 120)
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
    #expect(Self.minimumSubtreeOpacity(in: cell.contentView.layer) == 0,
      "Revealed media + Hide pill container must start at opacity 0 synchronously before crossfade begins")

    // Step real RunLoop frames + CATransaction.flush() so SwiftUI's ViewGraph commits hasAppeared = true
    // and drives the 0.18s opacity-only crossfade to completion with zero geometry animations on any frame.
    var sawOpacityTransition = false
    for _ in 0..<12 {
      try await Task.sleep(for: .milliseconds(16))
      CATransaction.flush()
      window.layoutIfNeeded()
      #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty,
        "Opacity fade must never introduce geometry animations on any frame")
      let currentMinOpacity = Self.minimumSubtreeOpacity(in: cell.contentView.layer)
      if Self.hasOpacityAnimation(in: cell.contentView.layer)
        || (currentMinOpacity > 0.0 && currentMinOpacity < 1.0) {
        sawOpacityTransition = true
      }
    }
    try await Task.sleep(for: .milliseconds(100))
    CATransaction.flush()
    window.layoutIfNeeded()
    let settledMinOpacity = Self.minimumSubtreeOpacity(in: cell.contentView.layer)
    #expect(settledMinOpacity == 1.0,
      "Revealed media + Hide pill container must transition from opacity 0.0 to 1.0 after 0.18s fade (got \(settledMinOpacity))")
    #expect(sawOpacityTransition || settledMinOpacity == 1.0)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty,
      "Opacity fade must never introduce geometry animations")

    // Conceal via Hide pill: immediate removal without lingering fade or jump.
    let hideButton = try #require(
      await Self.waitForAccessibilityElement(in: cell.contentView) {
        $0.identifier == "moderation.mediaGate.hide"
      }
    )
    #expect(hideButton.object.accessibilityActivate())
    #expect(abs(cell.frame.height - concealedHeight) < 2.0)
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }

  @Test("Duplicate visible FeedPostCollectionViewCells sharing postID advance revealGeneration, prevent cache poisoning, and keep tapped row anchored")
  func duplicateVisibleCellsAdvanceRevealGenerationAndResizeTogether() async throws {
    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState(did: "did:plc:duplicaterows")
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.showsSeparators = false
    let collectionView = UICollectionView(
      frame: window.bounds,
      collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfig)
    )

    let sharedPostID = "at://did:plc:shared/app.bsky.feed.post/shared-cw-\(UUID().uuidString)"
    let otherPostID = "at://did:plc:other/app.bsky.feed.post/other-cw-\(UUID().uuidString)"
    let sharedUI = PostModerationPresentation.make(
      post: try F.post(uri: sharedPostID, labels: [try F.label("porn", uri: sharedPostID)], embed: F.imageEmbed),
      policy: F.policy(labels: ["porn": "warn"])
    ).media
    let otherUI = PostModerationPresentation.make(
      post: try F.post(uri: otherPostID, labels: [try F.label("porn", uri: otherPostID)], embed: F.imageEmbed),
      policy: F.policy(labels: ["porn": "warn"])
    ).media
    let heightCache = FeedRowHeightCache()
    var secondRowInvalidate: (() -> Void)?

    let postRecord = AppBskyFeedPost(
      text: "Shared post text", entities: nil, facets: nil, reply: nil, embed: nil,
      langs: nil, labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    let author = try F.profile(did: "did:plc:shared")
    let postView = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: sharedPostID),
      cid: CID.fromDAGCBOR(Data("cid-shared".utf8)),
      author: author,
      record: .knownType(postRecord),
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0))
    )
    let cachedPost = try #require(
      CachedFeedViewPost(
        from: AppBskyFeedDefs.FeedViewPost(post: postView, reply: nil, reason: nil, feedContext: nil, reqId: nil),
        feedType: "timeline"
      )
    )
    let signature = FeedPostContentSignature(cachedPost)

    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, index in
      cell.heightCache = heightCache
      let rowPostID: String = {
        if index == 0 || index == 2 { return sharedPostID }
        if index == 1 { return otherPostID }
        return "at://did:plc:other/app.bsky.feed.post/\(index)"
      }()
      cell.postID = rowPostID
      cell.contentSignature = signature
      cell.fontGeneration = 0
      cell.contentSizeCategory = .large
      cell.revealGeneration = ModerationRevealStore.shared.generation
      cell.markConfigured()

      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        let duplicateVisibleCells = (collectionView?.visibleCells ?? [])
          .compactMap { $0 as? FeedPostCollectionViewCell }
          .filter { $0 !== cell && $0.postID == rowPostID }
        CollectionViewCellResizeAnchor.performTopAnchoredResize(
          in: collectionView,
          for: cell,
          additionalCells: duplicateVisibleCells
        ) {
          let currentGeneration = ModerationRevealStore.shared.generation
          heightCache.invalidate(postID: rowPostID)
          cell?.revealGeneration = currentGeneration
          cell?.markHeightNeedsRecalculation()
          for dup in duplicateVisibleCells {
            dup.revealGeneration = currentGeneration
            dup.markHeightNeedsRecalculation()
          }
        }
      }
      if index == 2 { secondRowInvalidate = invalidate }

      cell.contentConfiguration = UIHostingConfiguration {
        Group {
          if index == 0 || index == 2 {
            ModerationMediaGate(ui: sharedUI, reservedAspectRatio: nil) {
              Color.pink.frame(height: 320)
            }
            .environment(\.moderationRevealSubject, sharedPostID)
          } else if index == 1 {
            ModerationMediaGate(ui: otherUI, reservedAspectRatio: nil) {
              Color.blue.frame(height: 320)
            }
            .environment(\.moderationRevealSubject, otherPostID)
          } else {
            Color.gray.opacity(0.15).frame(height: 160)
          }
        }
        .environment(appState)
        .environment(\.fontManager, appState.fontManager)
        .environment(\.invalidateFeedRowHeight, invalidate)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let vc = UIViewController()
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0, 1, 2, 3, 4, 5])
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    // Scroll slightly so there is scroll headroom at the top when row 0 above row 2 also expands.
    collectionView.contentOffset = CGPoint(x: 0, y: 40)
    collectionView.layoutIfNeeded()

    let firstCell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? FeedPostCollectionViewCell)
    let unrelatedCell = try #require(collectionView.cellForItem(at: IndexPath(item: 1, section: 0)) as? FeedPostCollectionViewCell)
    let tappedCell = try #require(collectionView.cellForItem(at: IndexPath(item: 2, section: 0)) as? FeedPostCollectionViewCell)
    let collapsedFirstH = firstCell.frame.height
    let collapsedUnrelatedH = unrelatedCell.frame.height
    let collapsedTappedH = tappedCell.frame.height
    let tappedAnchorViewportY = tappedCell.frame.minY - collectionView.contentOffset.y

    let invalidate = try #require(secondRowInvalidate)
    withoutRevealAnimation {
      ModerationRevealStore.shared.setRevealed(
        true, ui: sharedUI, gate: .media, subject: sharedPostID, accountDID: appState.userDID)
    }
    invalidate()

    let expectedGen = ModerationRevealStore.shared.generation
    #expect(firstCell.revealGeneration == expectedGen)
    #expect(tappedCell.revealGeneration == expectedGen)
    let tappedDelta = tappedCell.frame.height - collapsedTappedH
    #expect(tappedDelta > 100,
      "Tapped ModerationMediaGate cell must expand in 1 frame (delta=\(tappedDelta))")
    #expect(abs((firstCell.frame.height - collapsedFirstH) - tappedDelta) < 2.0,
      "Companion duplicate ModerationMediaGate cell above must observe per-subject reveal and resize in the same 1-frame pass")
    #expect(abs(unrelatedCell.frame.height - collapsedUnrelatedH) < 1.0,
      "Unrelated ModerationMediaGate cell for another postID must remain concealed")
    #expect(abs((tappedCell.frame.minY - collectionView.contentOffset.y) - tappedAnchorViewportY) < 0.05,
      "Tapped cell must stay pinned at 0.0pt jump even when duplicate cell above also expanded")
    #expect(
      heightCache.height(
        for: sharedPostID,
        width: Int(window.bounds.width),
        fontGeneration: 0,
        contentSizeCategory: .large,
        contentSignature: signature,
        revealGeneration: expectedGen
      ) == nil,
      "Transiently resized duplicate cells must never write heights back into FeedRowHeightCache"
    )
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    // Hide again via ModerationRevealStore: both cells must collapse in 1 frame with 0.0pt jump on tapped cell.
    withoutRevealAnimation {
      ModerationRevealStore.shared.setRevealed(
        false, ui: sharedUI, gate: .media, subject: sharedPostID, accountDID: appState.userDID)
    }
    invalidate()
    #expect(abs(firstCell.frame.height - collapsedFirstH) < 2.0)
    #expect(abs(tappedCell.frame.height - collapsedTappedH) < 2.0)
    #expect(abs((tappedCell.frame.minY - collectionView.contentOffset.y) - tappedAnchorViewportY) < 0.05)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }

  @Test("ExternalEmbedView inline web player expand and Hide Embed step in 1 frame with zero geometry animations")
  func externalEmbedShowAndHideStepsInOneFrameWithoutGeometryAnimations() async throws {
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }

    let testDID = "did:plc:externalembedresize-\(UUID().uuidString)"
    let scopedConsentKey = AppSettingsModel.scopedKey("externalMediaConsent.youtube", accountDID: testDID)
    UserDefaults.standard.set(ExternalMediaConsent.allow.rawValue, forKey: scopedConsentKey)
    defer { UserDefaults.standard.removeObject(forKey: scopedConsentKey) }

    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState(did: testDID)
    appState.appSettings.configure(accountDID: testDID)
    let sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.showsSeparators = false
    let collectionView = UICollectionView(
      frame: window.bounds,
      collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfig)
    )

    let external = AppBskyEmbedExternal.ViewExternal(
      uri: URI(uriString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
      title: "Synthetic YouTube Video Card",
      description: "Verifies ExternalEmbedView Show and Hide Embed use 1-frame resize"
    )
    var invalidateCount = 0

    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, _ in
      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        invalidateCount += 1
        CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: cell)
      }
      cell.contentConfiguration = UIHostingConfiguration {
        ExternalEmbedView(
          external: external,
          shouldBlur: false,
          postID: "at://did:plc:test/app.bsky.feed.post/youtube1"
        )
        .padding(12)
        .applyAppStateEnvironment(appState)
        .environment(sceneContext)
        .environment(\.invalidateFeedRowHeight, invalidate)
        .fixedSize(horizontal: false, vertical: true)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let vc = UIViewController()
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0])
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    let cell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? FeedPostCollectionViewCell)
    let cardHeight = cell.frame.height
    let anchorViewportY = cell.frame.minY - collectionView.contentOffset.y

    let cardButton = try #require(
      await Self.waitForAccessibilityElement(in: cell.contentView) {
        $0.identifier == "externalEmbed.linkCard"
      },
      "ExternalEmbedView link card must be reachable as an activatable button"
    )
    #expect(cardButton.object.accessibilityActivate())

    #expect(invalidateCount == 1, "Expanding ExternalEmbedView web player must invoke invalidateFeedRowHeight")
    #expect(cell.frame.height > cardHeight + 60,
      "Expanding YouTube web embed must synchronously grow cell height (was \(cardHeight), now \(cell.frame.height))")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let hideEmbedButton = try #require(
      await Self.waitForAccessibilityElement(in: cell.contentView) {
        $0.identifier == "externalEmbed.hide" || ($0.label ?? "").contains("Hide Embed")
      },
      "Expanded ExternalEmbedView must expose Hide Embed button"
    )
    #expect(hideEmbedButton.object.accessibilityActivate())

    #expect(invalidateCount == 2, "Tapping Hide Embed must invoke invalidateFeedRowHeight")
    #expect(abs(cell.frame.height - cardHeight) < 2.0,
      "Collapsing ExternalEmbedView must synchronously restore link card height")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }

  @Test("Dynamic Type AX5 multi-line warning cover shrinks and re-expands accurately in 1 frame")
  func dynamicTypeAX5MediaGateShowAndHideMeasuresAccurately() async throws {
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }

    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState(did: "did:plc:ax5resize")
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    let longExplanation = String(
      repeating: "Detailed spoiler warning description that wraps across many lines under Accessibility Extra Extra Extra Large. ",
      count: 6
    )
    let policy = F.customLabelerPolicy(
      blurs: "media",
      severity: "none",
      locales: [
        ComAtprotoLabelDefs.LabelValueDefinitionStrings(
          lang: LanguageCodeContainer(languageCode: "en"),
          name: "Major Plot Spoilers",
          description: longExplanation
        )
      ]
    )
    let postURI = "at://did:web:bob.test/app.bsky.feed.post/ax5-\(UUID().uuidString)"
    let post = try F.post(
      uri: postURI,
      labels: [try F.label("custom", uri: postURI, src: F.customLabelerDID)],
      embed: F.imageEmbed
    )
    let mediaUI = PostModerationPresentation.make(post: post, policy: policy).media
    #expect(mediaUI.blur)

    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.showsSeparators = false
    let collectionView = UICollectionView(
      frame: window.bounds,
      collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfig)
    )
    collectionView.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge

    // Short revealed media (80pt) < tall AX5 warning cover (> 300pt), testing shrink on Show and grow on Hide!
    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, _ in
      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: cell)
      }
      cell.contentConfiguration = UIHostingConfiguration {
        HostedMediaGateRow(ui: mediaUI, postURI: postURI, revealedMediaHeight: 80)
          .environment(appState)
          .environment(\.fontManager, appState.fontManager)
          .environment(\.dynamicTypeSize, .accessibility5)
          .environment(\.invalidateFeedRowHeight, invalidate)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let vc = UIViewController()
    vc.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0, 1])
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<6 {
      try await Task.sleep(for: .milliseconds(25))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    let cell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? FeedPostCollectionViewCell)
    let ax5CoverRowHeight = cell.frame.height
    #expect(ax5CoverRowHeight > 500, "AX5 multi-line warning cover row must be tall (got \(ax5CoverRowHeight))")

    let showButton = try #require(
      await Self.waitForAccessibilityElement(in: cell.contentView) {
        $0.identifier == "moderation.mediaGate.show"
      }
    )
    #expect(showButton.object.accessibilityActivate())

    let revealedRowHeight = cell.frame.height
    #expect(revealedRowHeight < ax5CoverRowHeight - 100,
      "Showing compact 80pt media from tall AX5 cover must shrink row synchronously (was \(ax5CoverRowHeight), now \(revealedRowHeight))")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let hideButton = try #require(
      await Self.waitForAccessibilityElement(in: cell.contentView) {
        $0.identifier == "moderation.mediaGate.hide"
      }
    )
    #expect(hideButton.object.accessibilityActivate())

    #expect(abs(cell.frame.height - ax5CoverRowHeight) < 2.0,
      "Hiding back to AX5 multi-line warning cover must restore full height without clipping (expected \(ax5CoverRowHeight), got \(cell.frame.height))")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }

  @Test("Top rubber-band overscroll is preserved without downward snap during cell resize")
  func topOverscrollPreservesRubberBandOffset() async throws {
    let window = try Self.makeSceneWindow()
    let appState = try await Self.makeAppState(did: "did:plc:overscroll")
    defer {
      window.isHidden = true
      window.rootViewController = nil
      appState.cleanup()
    }

    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.showsSeparators = false
    let collectionView = UICollectionView(
      frame: window.bounds,
      collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfig)
    )
    collectionView.contentInset = UIEdgeInsets(top: 96, left: 0, bottom: 34, right: 0)

    let gateModel = ContentWarningGateTriggerModel()
    var invalidateClosure: (() -> Void)?

    let registration = UICollectionView.CellRegistration<FeedPostCollectionViewCell, Int> {
      [weak collectionView] cell, _, index in
      let invalidate: () -> Void = { [weak collectionView, weak cell] in
        CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: cell)
      }
      if index == 0 { invalidateClosure = invalidate }
      cell.contentConfiguration = UIHostingConfiguration {
        Group {
          if index == 0 {
            ControllableGatedPostRow(model: gateModel, collapsedGateHeight: 150, expandedGateHeight: 360)
          } else {
            Color.gray.opacity(0.15).frame(height: 180)
          }
        }
        .environment(appState)
        .environment(\.fontManager, appState.fontManager)
        .environment(\.invalidateFeedRowHeight, invalidate)
      }
      .margins(.all, 0)
    }

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      cv.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
    }

    let vc = UIViewController()
    vc.view.frame = window.bounds
    vc.view.addSubview(collectionView)
    window.rootViewController = vc
    window.isHidden = false

    var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
    snapshot.appendSections([0])
    snapshot.appendItems([0, 1, 2, 3, 4])
    await dataSource.apply(snapshot, animatingDifferences: false)

    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    // Simulate rubber-band pull-to-refresh overscroll (-140 < -96).
    let overscrollY: CGFloat = -140
    collectionView.contentOffset = CGPoint(x: 0, y: overscrollY)
    let cell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
    let anchorViewportY = cell.frame.minY - overscrollY

    let invalidate = try #require(invalidateClosure)
    ControllableGatedPostRow.setExpanded(true, model: gateModel, invalidate: invalidate)

    #expect(abs(collectionView.contentOffset.y - overscrollY) < 0.05,
      "Top rubber-band overscroll (\(overscrollY)) must be preserved instead of snapping to -inset.top (got \(collectionView.contentOffset.y))")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05)
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
  }
}
#endif
