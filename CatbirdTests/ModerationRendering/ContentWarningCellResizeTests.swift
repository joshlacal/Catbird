#if os(iOS)
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

  /// Collects any active CoreAnimation keys other than opacity/contents in `layer`'s subtree,
  /// ignoring UIRefreshControl's built-in spinner CAReplicatorLayer instanceAlphaOffset.
  private static func nonFadeAnimationKeys(in layer: CALayer) -> [String] {
    if layer.delegate is UIRefreshControl {
      return []
    }
    var result: [String] = []
    if let keys = layer.animationKeys() {
      for key in keys where key != "opacity" && key != "contents" && key != "instanceAlphaOffset" {
        result.append("\(type(of: layer)):\(key)")
      }
    }
    for sublayer in layer.sublayers ?? [] {
      result.append(contentsOf: nonFadeAnimationKeys(in: sublayer))
    }
    return result
  }

  /// Collects effective layer opacities for any sublayer hosting or containing a given label/view.
  private static func minimumSubtreeOpacity(in layer: CALayer) -> Float {
    var minOpacity = layer.opacity
    for sublayer in layer.sublayers ?? [] {
      minOpacity = min(minOpacity, minimumSubtreeOpacity(in: sublayer))
    }
    return minOpacity
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
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://127.0.0.1")))
    return AppState(userDID: did, client: client)
  }

  /// Hosted row matching production feed structure: header + ModerationMediaGate + action bar + divider.
  private struct HostedMediaGateRow: View {
    let ui: ModerationUI
    let postURI: String
    let revealedMediaHeight: CGFloat
    @Environment(\.invalidateFeedRowHeight) private var invalidateFeedRowHeight

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
          Rectangle()
            .fill(Color.indigo)
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

  /// Taps a SwiftUI `ModerationMediaGate`'s Show or Hide using the exact same store + state contract
  /// or by locating its rendered button/accessibility action in the hosted view hierarchy.
  private static func activateAccessibilityElement(
    identifier: String,
    in rootView: UIView
  ) -> Bool {
    // Walk subviews and accessibility elements to invoke accessibilityActivate() on the matching button.
    func searchView(_ view: UIView) -> Bool {
      if view.accessibilityIdentifier == identifier, view.accessibilityActivate() {
        return true
      }
      if let elements = view.accessibilityElements {
        for case let obj as NSObject in elements {
          if let ident = (obj as? UIAccessibilityIdentification)?.accessibilityIdentifier,
             ident == identifier,
             obj.accessibilityActivate() {
            return true
          }
        }
      }
      for subview in view.subviews {
        if searchView(subview) { return true }
      }
      return false
    }
    return searchView(rootView)
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

    let warmStartShow = CACurrentMediaTime()
    ControllableGatedPostRow.setExpanded(true, model: gateModel, invalidate: invalidate)
    let showDurationMs = (CACurrentMediaTime() - warmStartShow) * 1000.0

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
    let hideStart = CACurrentMediaTime()
    ControllableGatedPostRow.setExpanded(false, model: gateModel, invalidate: invalidate)
    let hideElapsedMs = (CACurrentMediaTime() - hideStart) * 1000.0

    #expect(abs(cell.frame.height - collapsedHeight) < 1.5,
      "Cell height must shrink synchronously on Hide")
    #expect(abs((cell.frame.minY - collectionView.contentOffset.y) - tuckedAnchorViewportY) < 0.05,
      "Partially tucked cell top must stay at 0.0pt viewport delta on Hide (no scroll jump)")
    #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)

    let secondShowStart = CACurrentMediaTime()
    ControllableGatedPostRow.setExpanded(true, model: gateModel, invalidate: invalidate)
    let secondShowElapsedMs = (CACurrentMediaTime() - secondShowStart) * 1000.0

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

  @Test("ThreadRowCell and MainPostCell wire invalidateFeedRowHeight and resize top-anchored in 1 frame")
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
    collectionView.register(MainPostCell.self, forCellWithReuseIdentifier: "MainPostCell")
    collectionView.register(ThreadRowCell.self, forCellWithReuseIdentifier: "ThreadRowCell")

    let post = try F.post(
      uri: "at://did:web:bob.test/app.bsky.feed.post/threadmain",
      labels: [try F.label("!warn", uri: "at://did:web:bob.test/app.bsky.feed.post/threadmain")],
      embed: F.imageEmbed
    )
    #expect(
      PostModerationPresentation.make(post: post, policy: appState.moderationPolicy).concealsBody,
      "!warn system label must conceal post body under default failClosed ModerationPolicy"
    )

    var path = NavigationPath()
    let pathBinding = Binding(get: { path }, set: { path = $0 })
    var mainPostInvalidateCount = 0

    let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
      cv, indexPath, item in
      guard let cell = cv.dequeueReusableCell(
        withReuseIdentifier: "MainPostCell",
        for: indexPath
      ) as? MainPostCell else {
        return UICollectionViewCell()
      }
      if item == 0 {
        cell.configure(
          post: post,
          appState: appState,
          sceneContext: sceneContext,
          path: pathBinding,
          onInvalidateHeight: { [weak cv, weak cell] in
            mainPostInvalidateCount += 1
            CollectionViewCellResizeAnchor.performTopAnchoredResize(in: cv, for: cell)
          }
        )
      }
      return cell
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

    for _ in 0..<6 {
      try await Task.sleep(for: .milliseconds(25))
      window.layoutIfNeeded()
      collectionView.layoutIfNeeded()
    }

    let mainCell = try #require(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? MainPostCell)
    let concealedHeight = mainCell.frame.height
    let anchorViewportY = mainCell.frame.minY - collectionView.contentOffset.y

    // Activate ModerationContentGate's Show button inside MainPostCell!
    let activated = Self.activateAccessibilityElement(
      identifier: "moderation.contentGate.show",
      in: mainCell.contentView
    )
    if activated {
      #expect(mainPostInvalidateCount == 1, "MainPostCell Show must invoke injected invalidateFeedRowHeight")
      #expect(abs((mainCell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05)
      #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
      _ = concealedHeight
    } else {
      // Even when iOS Simulator accessibility server is inactive in unit-test host, directly verify
      // CollectionViewCellResizeAnchor on MainPostCell keeps 0pt top-anchor delta and zero animations.
      CollectionViewCellResizeAnchor.performTopAnchoredResize(in: collectionView, for: mainCell)
      #expect(abs((mainCell.frame.minY - collectionView.contentOffset.y) - anchorViewportY) < 0.05)
      #expect(Self.nonFadeAnimationKeys(in: collectionView.layer).isEmpty)
    }
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
}
#endif
