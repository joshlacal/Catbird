import XCTest

/// Native feed rows place every post exactly where the hosted SwiftUI rows they replace do (ruling
/// R3), at every line spacing, and "Tight" shortens every post in both. Each measurement launches
/// the offline feed fixture once with native rows and once with `--native-feed-rows=off`, and reads
/// each post's top (relative to the first post's) and height, scrolling until enough posts are read.
@MainActor
final class NativeFeedRowParityUITests: XCTestCase {
  /// Accessibility frames are reported in single precision.
  private static let tolerance: CGFloat = 0.01
  private static let minimumSharedRows = 12
  /// Measured posts drawn by native cells. The mixed fixture hosts posts with embeds, replies and
  /// reposts in both modes, and draws 4 of the first 17 posts natively.
  private static let minimumNativeRows = 4
  /// The native cell's text view (`NativeFeedPostCell.textAccessibilityIdentifier`).
  private static let nativeTextIdentifier = "feedRow.native.text"
  /// Posts read per launch before the measurement stops scrolling.
  private static let postsToMeasure = 16
  private static let maximumScrolls = 30

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// Posts by identifier: their tops relative to the first post's top, their heights, and which
  /// of them a native cell draws.
  private struct RowFrames {
    var tops: [String: CGFloat] = [:]
    var heights: [String: CGFloat] = [:]
    var native: Set<String> = []
  }

  private func measure(lineSpacing: String, nativeRows: Bool, contentSize: String? = nil) throws -> RowFrames {
    let app = XCUIApplication()
    app.launchArguments = [
      "--feed-perf-fixture", "--feed-perf-content=mixed", "--feed-perf-count=40",
      "--feed-perf-line-spacing=\(lineSpacing)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    if !nativeRows { app.launchArguments.append("--native-feed-rows=off") }
    if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
    app.launch()
    defer { app.terminate() }

    let feed = app.collectionViews.firstMatch
    XCTAssertTrue(feed.waitForExistence(timeout: 60), "The feed fixture should load")
    let firstPost = feed.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'post.' AND identifier ENDSWITH '/perf0'")).firstMatch
    XCTAssertTrue(firstPost.waitForExistence(timeout: 30), "The first post should be shown")

    var frames = RowFrames()
    for pass in 0...Self.maximumScrolls {
      let snapshot = try feed.snapshot()
      var posts: [Post] = []
      Self.collectPosts(in: snapshot, into: &posts)
      // Tops are relative to the first post: on the first screen directly, after a scroll through
      // any post already measured.
      let offset: CGFloat?
      if pass == 0 {
        offset = posts.first { $0.identifier.hasSuffix("/perf0") }.map { -$0.frame.minY }
      } else {
        offset = posts.lazy.compactMap { post in frames.tops[post.identifier].map { $0 - post.frame.minY } }.first
      }
      let shift = try XCTUnwrap(
        offset, "pass \(pass) shares no post with the posts already measured; it shows \(Self.describe(posts))")
      for post in posts where frames.tops[post.identifier] == nil {
        frames.tops[post.identifier] = post.frame.minY + shift
        frames.heights[post.identifier] = post.frame.height
        if post.isNative { frames.native.insert(post.identifier) }
      }
      if frames.tops.count >= Self.postsToMeasure { break }
      // Half a screen at a time, held at the end so the feed does not coast: every screen
      // shares posts with the one before it.
      feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
        forDuration: 0.05, thenDragTo: feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
        withVelocity: .slow, thenHoldForDuration: 0.3)
    }
    return frames
  }

  private struct Post {
    let identifier: String
    let frame: CGRect
    /// Drawn by a native cell: its text is the native text view.
    let isNative: Bool
  }

  /// Elements identified `post.<uri>`: a native cell's content view, or a hosted `PostView` (also
  /// the parent and reply of a thread row, inset from the row's edges). The outermost element of
  /// each identifier is kept.
  private static func collectPosts(in snapshot: XCUIElementSnapshot, into posts: inout [Post]) {
    if snapshot.identifier.hasPrefix("post."), !posts.contains(where: { $0.identifier == snapshot.identifier }) {
      posts.append(Post(
        identifier: snapshot.identifier, frame: snapshot.frame,
        isNative: contains(nativeTextIdentifier, in: snapshot)))
    }
    for child in snapshot.children {
      collectPosts(in: child, into: &posts)
    }
  }

  private static func contains(_ identifier: String, in snapshot: XCUIElementSnapshot) -> Bool {
    snapshot.identifier == identifier || snapshot.children.contains { contains(identifier, in: $0) }
  }

  private static func describe(_ posts: [Post]) -> [String] {
    posts.map { "\(name($0.identifier)) \($0.frame)" }
  }

  /// Native cells draw enough of the measured posts with native rows on, and none with them off,
  /// so the comparison is between the two renderers.
  private func expectRenderers(native: RowFrames, hosted: RowFrames, label: String) {
    print("RENDERERS \(label) native rows \(native.native.count) of \(native.tops.count): \(native.native.map(Self.name).sorted())")
    XCTAssertGreaterThanOrEqual(native.native.count, Self.minimumNativeRows, "\(label): too few native rows measured")
    XCTAssertTrue(hosted.native.isEmpty, "\(label): native rows drawn with native rows off: \(hosted.native.sorted())")
  }

  private static func name(_ identifier: String) -> String {
    identifier.split(separator: "/").last.map(String.init) ?? identifier
  }

  private func expectParity(lineSpacing: String, contentSize: String? = nil) throws {
    let native = try measure(lineSpacing: lineSpacing, nativeRows: true, contentSize: contentSize)
    let hosted = try measure(lineSpacing: lineSpacing, nativeRows: false, contentSize: contentSize)
    let shared = native.tops.keys.filter { hosted.tops[$0] != nil }.sorted { native.tops[$0]! < native.tops[$1]! }
    let label = contentSize.map { "\(lineSpacing) \($0)" } ?? lineSpacing
    expectRenderers(native: native, hosted: hosted, label: label)
    var mismatches: [String] = []
    for identifier in shared {
      let top = (native: native.tops[identifier]!, hosted: hosted.tops[identifier]!)
      let height = (native: native.heights[identifier]!, hosted: hosted.heights[identifier]!)
      print("PARITY \(label) \(Self.name(identifier)) top native \(top.native) hosted \(top.hosted) delta \(top.native - top.hosted) height native \(height.native) hosted \(height.hosted)")
      if abs(top.native - top.hosted) >= Self.tolerance || abs(height.native - height.hosted) >= Self.tolerance {
        mismatches.append("\(Self.name(identifier)) top \(top.native - top.hosted) height \(height.native - height.hosted)")
      }
    }
    XCTAssertGreaterThanOrEqual(shared.count, Self.minimumSharedRows, "\(label): too few posts measured in both modes")
    XCTAssertTrue(mismatches.isEmpty, "\(label): \(mismatches.count) posts differ, native - hosted: \(mismatches)")
  }

  func testRowTopsMatchHostedRowsAtTight() throws {
    try expectParity(lineSpacing: "tight")
  }

  func testRowTopsMatchHostedRowsAtNormal() throws {
    try expectParity(lineSpacing: "normal")
  }

  func testRowTopsMatchHostedRowsAtRelaxed() throws {
    try expectParity(lineSpacing: "relaxed")
  }

  func testRowTopsMatchHostedRowsAtTightWithLargeText() throws {
    try expectParity(lineSpacing: "tight", contentSize: "UICTContentSizeCategoryXXXL")
    try expectParity(lineSpacing: "tight", contentSize: "UICTContentSizeCategoryAccessibilityL")
  }

  func testTightShortensEveryPost() throws {
    guard #available(iOS 26.0, *) else {
      throw XCTSkip("Tight line spacing is offered from iOS 26; earlier systems draw it as Normal")
    }
    for nativeRows in [true, false] {
      let tight = try measure(lineSpacing: "tight", nativeRows: nativeRows)
      let normal = try measure(lineSpacing: "normal", nativeRows: nativeRows)
      let shared = tight.heights.keys.filter { normal.heights[$0] != nil }
      let mode = nativeRows ? "native" : "hosted"
      if nativeRows {
        XCTAssertGreaterThanOrEqual(tight.native.count, Self.minimumNativeRows, "too few native rows measured at Tight")
        XCTAssertGreaterThanOrEqual(normal.native.count, Self.minimumNativeRows, "too few native rows measured at Normal")
      }
      var unchanged: [String] = []
      for identifier in shared.sorted() {
        let tightHeight = tight.heights[identifier]!
        let normalHeight = normal.heights[identifier]!
        print("TIGHTENS \(mode) \(Self.name(identifier)) tight \(tightHeight) normal \(normalHeight)")
        if tightHeight >= normalHeight { unchanged.append(Self.name(identifier)) }
      }
      XCTAssertGreaterThanOrEqual(shared.count, Self.minimumSharedRows, "\(mode): too few posts measured at both spacings")
      XCTAssertTrue(unchanged.isEmpty, "\(mode): \(unchanged.count) posts are not shorter at Tight: \(unchanged)")
    }
  }
}
