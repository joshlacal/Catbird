//
//  FeedRowStackBudgetTests.swift
//  CatbirdTests
//
//  Regression guards for the Debug-build main-thread stack overflow when a feed
//  row renders. Petrel models are large inline structs, and at -Onone every
//  @ViewBuilder step reserves a stack slot sized like the view or opaque body
//  it builds, so one reply row once used ~900 KB of a device's 1 MB main stack.
//  The simulator's main stack is 8 MB, so these tests measure instead of
//  waiting for a crash.
//

import Darwin
import Foundation
import Petrel
import SwiftUI
import Testing
@testable import Catbird

#if os(iOS)
import SwiftData
import UIKit
#endif

@Suite("Feed row view value sizes")
@MainActor
struct FeedRowViewSizeBudgetTests {
  private struct SizeBudget: Sendable {
    let name: String
    let size: Int
    /// `nil` rows are recorded for context only.
    let budget: Int?
  }

  private static func row<T>(_ name: String, _ type: T.Type, _ budget: Int?) -> SizeBudget {
    SizeBudget(name: name, size: MemoryLayout<T>.size, budget: budget)
  }

  @Test("Feed row view values stay small enough for -Onone stack temporaries")
  func viewValueSizesStayWithinBudget() {
    // Pre-fix Debug sizes: EnhancedFeedPost 7_737, EnhancedFeedPost.Body 20_352, PostView 8_136,
    // PostView.Body 22_473, FeedPostRow.Body 8_168, ProfileCachedPostsList.Body 400.
    // Post-fix (Oct 7, iOS 27.1 simulator): every struct below is at most 336 B and every
    // Body at most 2_936 B (ThreadViewMainPostView), so the budgets leave about 40% headroom.
    let viewBudget = 512  // any feed row view struct
    let bodyBudget = 4_096  // any feed row opaque body

    // -Onone gives each view value and opaque body its own stack slot per builder step, so these
    // sizes multiply into main-thread stack use (1 MB on a device).
    let budgets: [SizeBudget] = [
      // Self.row(report name, type, budget)
      Self.row("EnhancedFeedPost", EnhancedFeedPost.self, viewBudget),
      Self.row("EnhancedFeedPost.Body", EnhancedFeedPost.Body.self, bodyBudget),
      Self.row("PostView", PostView.self, viewBudget),
      Self.row("PostView.Body", PostView.Body.self, bodyBudget),
      Self.row("FeedPostRow.Body", FeedPostRow.Body.self, bodyBudget),
      Self.row("FeedPost", FeedPost.self, viewBudget),
      Self.row("FeedPost.Body", FeedPost.Body.self, bodyBudget),
      Self.row("BlockedContentCard", BlockedContentCard.self, viewBudget),
      Self.row("BlockedContentCard.Body", BlockedContentCard.Body.self, bodyBudget),
      Self.row("PostNotFoundView", PostNotFoundView.self, viewBudget),
      Self.row("PostNotFoundView.Body", PostNotFoundView.Body.self, bodyBudget),
      Self.row("ActionButtonsView", ActionButtonsView.self, viewBudget),
      Self.row("ActionButtonsView.Body", ActionButtonsView.Body.self, bodyBudget),
      Self.row("RepostHeaderView", RepostHeaderView.self, viewBudget),
      Self.row("ThreadRowView", ThreadRowView.self, viewBudget),
      Self.row("ThreadRowView.Body", ThreadRowView.Body.self, bodyBudget),
      Self.row("ThreadViewMainPostView", ThreadViewMainPostView.self, viewBudget),
      Self.row("ThreadViewMainPostView.Body", ThreadViewMainPostView.Body.self, bodyBudget),
      Self.row("ProfileCachedPostsList.Body", ProfileCachedPostsList.Body.self, bodyBudget),
      // The fix stores large models through this box, so it must stay one pointer wide.
      Self.row("EquatableBox<FeedViewPost>", EquatableBox<AppBskyFeedDefs.FeedViewPost>.self,
        MemoryLayout<UnsafeRawPointer>.size),
      // Generated Petrel payloads a view would otherwise copy inline.
      Self.row("AppBskyFeedDefs.FeedViewPost", AppBskyFeedDefs.FeedViewPost.self, nil),
      Self.row("AppBskyFeedDefs.PostView", AppBskyFeedDefs.PostView.self, nil),
      Self.row("AppBskyFeedDefs.ThreadViewPost", AppBskyFeedDefs.ThreadViewPost.self, nil),
      Self.row("AppBskyActorDefs.ProfileViewBasic", AppBskyActorDefs.ProfileViewBasic.self, nil),
      Self.row("ATProtocolURI", ATProtocolURI.self, nil),
    ]

    let report: String = budgets.map { entry -> String in
      let budget = entry.budget.map { String($0) } ?? "context"
      return "\(entry.name)=\(entry.size) budget=\(budget)"
    }.joined(separator: "\n")
    print("[FeedRowStackBudget] view sizes\n\(report)")
    Attachment.record(report, named: "feed-row-view-sizes.txt")

    for entry in budgets {
      guard let budget = entry.budget else { continue }
      #expect(entry.size <= budget, "\(entry.name) is \(entry.size) B; budget \(budget) B")
    }
  }
}

#if os(iOS)
/// Realizes reply rows in the profile's ScrollView + LazyVStack shape and measures how much
/// main-thread stack one synchronous layout pass uses, relative to a plain Text control row.
@Suite("Feed row stack budget", .serialized)
@MainActor
struct FeedRowStackBudgetTests {
  /// Reply rows may use this much more stack than the Text control row.
  private static let rowBudget = 256 * 1024
  /// Whole measured pass, including hosting and layout; a device main thread has 1 MB.
  private static let totalBudget = 384 * 1024
  /// Height of the stand-in profile header above the lazy rows.
  private static let headerHeight: CGFloat = 120
  /// A realized reply row (parent post plus reply) is far taller than this.
  private static let minimumRowsHeight: CGFloat = 40

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @Test("A reply row realized in ScrollView + LazyVStack stays within the main-thread stack budget")
  func replyRowInLazyStackStaysWithinStackBudget() async throws {
    try #require(pthread_main_np() == 1, "Stack budgets describe the main thread")
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let replies = try (0..<2).map(Self.makeReply)

    let control = try measureLayoutPass(fixture) { receipt in
      Text("Control row").frame(maxWidth: .infinity, minHeight: 120)
      RealizationProbe(receipt: receipt)
    }
    let reply = try measureLayoutPass(fixture) { receipt in
      ForEach(replies) { row in
        VStack(spacing: 0) {
          EnhancedFeedPost(feedViewPost: row, path: .constant(NavigationPath()))
          RealizationProbe(receipt: receipt)
          Divider()
        }
      }
    }
    recordMeasurements([("control", control), ("reply", reply)], named: "feed-row-stack-high-water.txt")

    #expect(control.realizedProbes > 0, "The control row must be realized inside the measured pass")
    #expect(reply.realizedProbes >= replies.count, "Every reply row must be realized inside the measured pass")
    for measurement in [control, reply] {
      #expect(measurement.stack.paintedBytes > 0, "The stack window could not be painted; see attachment")
      #expect(!measurement.stack.overflowedWindow, "Stack use reached the painted window's floor; see attachment")
    }
    let rowCost = reply.stack.usedBytes - control.stack.usedBytes
    #expect(rowCost < Self.rowBudget, "Reply rows used \(rowCost) B beyond the control row")
    #expect(reply.stack.usedBytes < Self.totalBudget, "Reply rows used \(reply.stack.usedBytes) B of main-thread stack")
  }

  @Test("Cached reply rows in ProfileCachedPostsList stay within the main-thread stack budget")
  func cachedProfileListReplyStaysWithinStackBudget() async throws {
    try #require(pthread_main_np() == 1, "Stack budgets describe the main thread")
    let fixture = try await Fixture()
    defer { fixture.tearDown() }
    let container = try CatbirdSwiftDataStore.makeContainer(
      configuration: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    let feedKey = "stack-budget-profile-posts"
    for (order, reply) in try (0..<2).map(Self.makeReply).enumerated() {
      container.mainContext.insert(try #require(CachedFeedViewPost(from: reply, feedType: feedKey, feedOrder: order)))
    }
    try container.mainContext.save()

    // Mirrors UnifiedProfileContentView: the list sits directly in the LazyVStack and reads
    // the model context from the root. The probe below it can only sit lower than the header
    // if @Query delivered the cached rows during the measured pass.
    let cached = try measureLayoutPass(fixture, modelContainer: container) { receipt in
      ProfileCachedPostsList(
        feedKey: feedKey, contentMaxWidth: 600, isLoadingMore: false, hasMore: false,
        loadMore: {}, path: .constant(NavigationPath()))
      RealizationProbe(receipt: receipt)
    }
    recordMeasurements([("cached", cached)], named: "profile-list-stack-high-water.txt")

    #expect(cached.realizedProbes > 0, "The probe below the cached rows must be realized inside the measured pass")
    #expect(cached.probeOffset > Self.headerHeight + Self.minimumRowsHeight,
      "Cached rows must occupy the space above the probe (probe at \(cached.probeOffset) pt)")
    #expect(cached.stack.paintedBytes > 0, "The stack window could not be painted; see attachment")
    #expect(!cached.stack.overflowedWindow, "Stack use reached the painted window's floor; see attachment")
    #expect(cached.stack.usedBytes < Self.totalBudget, "Profile list used \(cached.stack.usedBytes) B of main-thread stack")
  }

  // MARK: - Harness

  @MainActor
  private struct Fixture {
    let appState: AppState
    let sceneContext: SceneNavigationContext
    let scene: UIWindowScene

    init() async throws {
      let client = await ATProtoClient(baseURL: try #require(URL(string: "http://127.0.0.1:9")))
      appState = AppState(userDID: "did:plc:stackbudgetviewer", client: client, regulatoryChecker: NoAgePrompt())
      sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
      scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }

    func tearDown() {
      sceneContext.invalidate()
      appState.cleanup()
    }
  }

  private struct LayoutMeasurement {
    let stack: StackHighWaterMark.Result
    let realizedProbes: Int
    let probeOffset: CGFloat
  }

  /// Hosts `rows` below a stand-in header and measures the stack used while the window is built
  /// and laid out once. Everything is read before the run loop turns, so only that pass counts.
  private func measureLayoutPass<Rows: View>(
    _ fixture: Fixture,
    modelContainer: ModelContainer? = nil,
    @ViewBuilder rows: (LayoutReceipt) -> Rows
  ) throws -> LayoutMeasurement {
    let receipt = LayoutReceipt()
    let previousKeyWindow = fixture.scene.windows.first(where: \.isKeyWindow)
    var window: UIWindow?
    let stack = StackHighWaterMark.measure {
      let root = ScrollView {
        VStack(spacing: 0) {
          Color.clear.frame(height: Self.headerHeight)
          LazyVStack(spacing: 0) { rows(receipt) }
        }
        .coordinateSpace(.named(stackBudgetCoordinateSpace))
      }
      .applyAppStateEnvironment(fixture.appState)
      .environment(fixture.sceneContext)
      let controller: UIViewController
      if let modelContainer {
        controller = UIHostingController(rootView: root.modelContainer(modelContainer))
      } else {
        controller = UIHostingController(rootView: root)
      }
      let host = UIWindow(windowScene: fixture.scene)
      // Taller than a phone so every fixture row is realized in this one pass. Rows are
      // realized one after another, so the viewport height does not change the peak depth.
      host.frame = CGRect(x: 0, y: 0, width: 402, height: 1_600)
      host.rootViewController = controller
      host.isHidden = false
      controller.view.frame = host.bounds
      controller.view.layoutIfNeeded()
      window = host
    }
    let measurement = LayoutMeasurement(
      stack: stack, realizedProbes: receipt.realizedProbes, probeOffset: receipt.probeOffset)

    let host = try #require(window)
    let becameKey = host.isKeyWindow
    host.isHidden = true
    host.rootViewController = nil
    if becameKey { previousKeyWindow?.makeKey() }
    return measurement
  }

  private func recordMeasurements(_ measurements: [(name: String, value: LayoutMeasurement)], named fileName: String) {
    var lines: [String] = measurements.map { name, value -> String in
      "\(name): used=\(value.stack.usedBytes) painted=\(value.stack.paintedBytes) "
        + "overflowedWindow=\(value.stack.overflowedWindow) realizedProbes=\(value.realizedProbes) "
        + "probeOffset=\(value.probeOffset)"
    }
    if let first = measurements.first?.value.stack {
      lines.insert("main-thread stack size=\(first.stackSize) available below test frame=\(first.availableBytes)", at: 0)
    }
    if measurements.count == 2 {
      lines.append("\(measurements[1].name) - \(measurements[0].name)="
        + "\(measurements[1].value.stack.usedBytes - measurements[0].value.stack.usedBytes)")
    }
    let report: String = lines.joined(separator: "\n")
    print("[FeedRowStackBudget] \(fileName)\n\(report)")
    Attachment.record(report, named: fileName)
  }

  private static func makeReply(_ index: Int) throws -> AppBskyFeedDefs.FeedViewPost {
    let did = try DID(didString: "did:plc:stackbudgetauthor")
    func post(_ rkey: String, _ text: String) throws -> AppBskyFeedDefs.PostView {
      PublicPostTestFixtures.makePostView(
        uri: try ATProtocolURI(uriString: "at://did:plc:stackbudgetauthor/app.bsky.feed.post/\(rkey)"),
        authorDID: did,
        text: text
      )
    }
    let root = try post("root-\(index)", "Thread root \(index)")
    let parent = try post("parent-\(index)", "Parent post \(index) that the reply answers.")
    let child = try post("child-\(index)", "Reply \(index) rendered beneath its parent.")
    // reason == nil and parent == .postView select standardThreadContent -> parentPostContent.
    return AppBskyFeedDefs.FeedViewPost(
      post: child,
      reply: AppBskyFeedDefs.ReplyRef(
        root: .appBskyFeedDefsPostView(root),
        parent: .appBskyFeedDefsPostView(parent),
        grandparentAuthor: root.author
      ),
      reason: nil,
      feedContext: nil,
      reqId: nil
    )
  }
}

private let stackBudgetCoordinateSpace = "feed-row-stack-budget"

@MainActor
private final class LayoutReceipt {
  var realizedProbes = 0
  /// Largest probe minY seen (the lowest on screen), in the scroll content's coordinate space.
  var probeOffset: CGFloat = 0

  func recordOffset(_ offset: CGFloat) {
    probeOffset = max(probeOffset, offset)
  }
}

/// Counts its body evaluations and records where it was placed, so a test can prove that the
/// rows above it were realized inside the measured layout pass rather than on a later update.
private struct RealizationProbe: View {
  let receipt: LayoutReceipt

  var body: some View {
    receipt.realizedProbes += 1
    return GeometryReader { proxy in
      let _ = receipt.recordOffset(proxy.frame(in: .named(stackBudgetCoordinateSpace)).minY)
      Color.clear
    }
    .frame(height: 1)
  }
}
#endif

/// Stack high-water mark for the calling thread: paints a canary below the caller's frame,
/// runs `body`, then finds the lowest overwritten word. The painted window stays inside this
/// thread's mapped stack: it starts `frameMargin` below the current frame and ends at least
/// `guardMargin` above the guard page, so it never exceeds the available stack minus 64 KB
/// (a device main thread has only 1 MB). It under-reports by at most the deepest leaf frame's
/// unwritten slack, and use shallower than `frameMargin` reads as roughly `frameMargin`.
private enum StackHighWaterMark {
  struct Result: Sendable {
    /// Bytes from the measuring frame down to the deepest write.
    let usedBytes: Int
    /// Size of the canary window; 0 when the stack was too shallow to measure.
    let paintedBytes: Int
    let stackSize: Int
    /// Stack left below the measuring frame before painting.
    let availableBytes: Int
    /// The lowest painted word was overwritten, so real use is at least `usedBytes`.
    let overflowedWindow: Bool
  }

  private static let canary: UInt64 = 0x5A17_C0DE_5A17_C0DE
  private static let guardMargin = 64 * 1024
  private static let frameMargin = 32 * 1024
  private static let maximumWindow = 2 * 1024 * 1024

  @inline(never)
  private static func frameAddress() -> UInt {
    var marker: UInt8 = 0
    return withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
  }

  @inline(never)
  static func measure(_ body: () -> Void) -> Result {
    let thread = pthread_self()
    let stackTop = UInt(bitPattern: pthread_get_stackaddr_np(thread))
    let stackSize = pthread_get_stacksize_np(thread)
    let base = frameAddress()
    guard stackSize > 0, stackTop > UInt(stackSize), base < stackTop, base > stackTop - UInt(stackSize) else {
      body()
      return Result(usedBytes: 0, paintedBytes: 0, stackSize: stackSize, availableBytes: 0, overflowedWindow: false)
    }
    let stackBottom = stackTop - UInt(stackSize)
    let available = Int(base - stackBottom)
    let windowBytes = min(maximumWindow, available - guardMargin - frameMargin) & ~15
    guard windowBytes >= 4 * 1024 else {
      body()
      return Result(usedBytes: 0, paintedBytes: 0, stackSize: stackSize, availableBytes: available, overflowedWindow: false)
    }
    let high = (base - UInt(frameMargin)) & ~UInt(15)
    let low = high - UInt(windowBytes)
    var pattern = canary
    memset_pattern8(UnsafeMutableRawPointer(bitPattern: low), &pattern, windowBytes)
    body()
    let words = UnsafePointer<UInt64>(bitPattern: low)!
    let count = windowBytes / 8
    var index = 0
    while index < count, words[index] == canary { index += 1 }
    let deepest = low + UInt(index * 8)
    return Result(
      usedBytes: Int(base - deepest),
      paintedBytes: windowBytes,
      stackSize: stackSize,
      availableBytes: available,
      overflowedWindow: index == 0
    )
  }
}
