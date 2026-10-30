#if os(iOS)
import Petrel
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Captures the actual production notice with local moderation fixtures. This
/// is a component fixture, not the full sheet or a process-wide isolation test.
@MainActor
final class CopilotImageModerationRenderingTests: XCTestCase {
  private typealias F = RenderingFixtures

  func testAdultOffLockedNoticeAtNormalAndLargeText() async throws {
    let snapshot = try makeSnapshot(policy: F.policy(adult: false))
    XCTAssertTrue(snapshot.rowVisible, "Text row is revealed independently of image permission")
    XCTAssertTrue(snapshot.imageUI.noOverride)
    let normal = try await capture(snapshot, name: "adult-off-locked-light")
    let large = try await capture(snapshot, name: "adult-off-locked-large-dark", largeText: true, dark: true)
    XCTAssertGreaterThan(large.height, normal.height, "Large text must expand the notice vertically")
  }

  func testWarningNoticeAtNormalAndLargeText() async throws {
    let snapshot = try makeSnapshot(policy: F.policy(labels: ["porn": "warn"]))
    XCTAssertTrue(snapshot.imageUI.blur)
    XCTAssertFalse(snapshot.imageUI.noOverride)
    let normal = try await capture(snapshot, name: "warning-light")
    let large = try await capture(snapshot, name: "warning-large-dark", largeText: true, dark: true)
    XCTAssertGreaterThan(large.height, normal.height, "Large text must expand the notice vertically")
  }

  func testRevealedWarningNotice() async throws {
    let snapshot = try makeSnapshot(policy: F.policy(labels: ["porn": "warn"]))
    var reveal = ModerationRevealState()
    reveal.show(snapshot.imageUI)
    XCTAssertTrue(snapshot.allows(reveal))
    _ = try await capture(snapshot, reveal: reveal, name: "warning-revealed-light")
  }

  private func makeSnapshot(policy: ModerationPolicy) throws -> CopilotImageModerationSnapshot {
    let post = try F.post(labels: [F.label("porn")], embed: F.imageEmbed)
    let context = CopilotContext.post(uri: post.uri.uriString(), cid: post.cid.string,
      authorDID: post.author.did.didString(), text: "Post text", evidence: CopilotPostEvidenceBuilder.build(post))
    let presentation = PostModerationPresentation.make(post: post, policy: policy)
    return try XCTUnwrap(CopilotImageModerationSnapshot.make(context: context,
      accountDID: F.viewerDID, accountRevision: 1, clientID: nil,
      post: post, policy: policy, revealedFilter: presentation.filterIdentity))
  }

  @discardableResult
  private func capture(_ snapshot: CopilotImageModerationSnapshot,
    reveal: ModerationRevealState = .init(), name: String,
    largeText: Bool = false, dark: Bool = false) async throws -> CGRect {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let measurement = NoticeMeasurement()
    let controller = UIHostingController(rootView: NoticeFixture(snapshot: snapshot,
      reveal: reveal, measurement: measurement)
      .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
      .preferredColorScheme(dark ? .dark : .light))
    controller.overrideUserInterfaceStyle = dark ? .dark : .light
    window.rootViewController = controller
    window.backgroundColor = .systemBackground
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    for _ in 0..<12 {
      window.setNeedsLayout()
      window.layoutIfNeeded()
      controller.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(25))
    }
    let frame = try XCTUnwrap(measurement.frame)
    let safeFrame = controller.view.convert(controller.view.safeAreaLayoutGuide.layoutFrame, to: window)
    XCTAssertGreaterThan(frame.height, 40)
    XCTAssertGreaterThan(frame.width, 100)
    XCTAssertGreaterThanOrEqual(frame.minX, safeFrame.minX - 1)
    XCTAssertLessThanOrEqual(frame.maxX, safeFrame.maxX + 1)
    XCTAssertGreaterThanOrEqual(frame.minY, safeFrame.minY - 1)
    XCTAssertLessThanOrEqual(frame.maxY, safeFrame.maxY + 1,
      "The full production notice must fit inside this fixture's visible safe area")

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    var drewHierarchy = false
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
      drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    XCTAssertTrue(drewHierarchy)
    let png = try XCTUnwrap(image.pngData())
    let receipt = """
    Native production CopilotImageModerationNotice component fixture: \(name)
    window=\(window.bounds); safeFrame=\(safeFrame); noticeFrame=\(frame); drawHierarchy=\(drewHierarchy)
    requestedDynamicType=\(largeText ? "accessibility3" : "large"); dark=\(dark)
    rowVisible=\(snapshot.rowVisible); blur=\(snapshot.imageUI.blur); noOverride=\(snapshot.imageUI.noOverride); allowsImages=\(snapshot.allows(reveal))
    Geometry assertions establish component bounds and vertical expansion, not individual text/button frames. Inspect PNG for wrapping, contrast, copy and control visibility.
    The revealed fixture starts with production reveal state; it does not claim a physical Show/Hide interaction, touch-target measurement, or VoiceOver pass. No AX hierarchy enumeration is used.
    Local RenderingFixtures feed the production snapshot and notice. No media fetch or model call is initiated by this fixture. Catbird.app hosts tests; account/bootstrap/network activity elsewhere in the process is outside this receipt. This is not a full-sheet layout capture.
    Observed settings: reduceMotion=\(UIAccessibility.isReduceMotionEnabled); reduceTransparency=\(UIAccessibility.isReduceTransparencyEnabled). Neither setting is forced or independently qualified here.
    """
    let screenshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    screenshot.name = "ask-catbird-moderation-\(name)"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let metadata = XCTAttachment(string: receipt)
    metadata.name = "ask-catbird-moderation-\(name)-geometry"
    metadata.lifetime = .keepAlways
    add(metadata)
    if let directory = ProcessInfo.processInfo.environment["ASK_CATBIRD_SNAPSHOT_DIR"] {
      let destination = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try png.write(to: destination.appendingPathComponent("ask-catbird-moderation-\(name).png"))
      try receipt.write(to: destination.appendingPathComponent("ask-catbird-moderation-\(name).txt"),
        atomically: true, encoding: .utf8)
    }
    return frame
  }
}

@MainActor @Observable
private final class NoticeMeasurement {
  var frame: CGRect?
}

private struct NoticeFixture: View {
  let snapshot: CopilotImageModerationSnapshot
  let reveal: ModerationRevealState
  let measurement: NoticeMeasurement

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 0) {
        CopilotImageModerationNotice(snapshot: snapshot, reveal: reveal, onReveal: {}, onHide: {})
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { measurement.frame = $0 }
        Spacer(minLength: 0)
      }
      .padding(.top, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.systemBackground))
      .navigationTitle("Ask Catbird")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}
#endif
