#if os(iOS)
import Foundation
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Hosted component tests: real Text wraps under the same width proposal used
/// for placement. No account, remote metadata, image request, or send is involved.
@MainActor
final class ChatBubbleWidthLayoutTests: XCTestCase {
  private let longText = "A shared article with enough words to wrap across several lines when the chat bubble has a concrete width. The final sentence must remain inside the rounded card."

  func testWidthCapEqualityUsesWrappedTextHeight() async throws {
    let fixture = try Fixture(text: longText)
    defer { fixture.close() }
    try await fixture.settle()

    let natural = try XCTUnwrap(fixture.probe.naturalMeasurements.last)
    let reference = try XCTUnwrap(fixture.probe.placedReference)
    XCTAssertEqual(natural.width, 280, accuracy: 0.5,
      "This fixture must exercise equality at the width cap, not the narrower branch")
    XCTAssertGreaterThan(reference.height, natural.height + 1,
      "Real Text must wrap more at the concrete width than with an unspecified proposal")
    try assertContained(fixture)
    attach(fixture, name: "equal-cap")
  }

  func testNarrowerWidthRemeasuresTheSameCard() async throws {
    let fixture = try Fixture(text: longText)
    defer { fixture.close() }
    try await fixture.settle()
    let wide = try XCTUnwrap(fixture.probe.frames["bubble"])
    fixture.model.width = 190
    try await fixture.settle()
    let narrow = try XCTUnwrap(fixture.probe.frames["bubble"])
    XCTAssertEqual(narrow.width, 190, accuracy: 0.5)
    XCTAssertGreaterThan(narrow.height, wide.height + 1)
    try assertContained(fixture)
    attach(fixture, name: "narrow-card")
  }

  func testShortTextKeepsItsHuggingWidth() async throws {
    let fixture = try Fixture(text: "Hi", card: false)
    defer { fixture.close() }
    try await fixture.settle()
    let bubble = try XCTUnwrap(fixture.probe.frames["bubble"])
    let text = try XCTUnwrap(fixture.probe.frames["text"])
    XCTAssertGreaterThan(bubble.width, 0)
    XCTAssertLessThan(bubble.width, 100, "Short text must not expand to the 280-point cap")
    XCTAssertEqual(bubble.width, text.width, accuracy: 0.5)
    try assertContained(fixture)
  }

  func testMountedCardGrowsAndShrinksWithoutReplacingContentIdentity() async throws {
    let fixture = try Fixture(text: "Shared post")
    defer { fixture.close() }
    try await fixture.settle()
    let first = try XCTUnwrap(fixture.probe.frames["bubble"])
    let identity = try XCTUnwrap(fixture.probe.appearanceIDs.first)

    // Change an observed value after mounting, as a completed metadata request
    // would. No host/rootView replacement or explicit layout invalidation seam.
    await Task.yield()
    fixture.model.text = longText
    try await fixture.settle()
    let grown = try XCTUnwrap(fixture.probe.frames["bubble"])
    XCTAssertGreaterThan(grown.height, first.height + 1)
    try assertContained(fixture)
    attach(fixture, name: "mounted-growth")

    await Task.yield()
    fixture.model.text = "Shared post"
    try await fixture.settle()
    let shrunk = try XCTUnwrap(fixture.probe.frames["bubble"])
    XCTAssertEqual(shrunk.height, first.height, accuracy: 0.5)
    try assertContained(fixture)
    XCTAssertEqual(fixture.probe.appearanceIDs, [identity],
      "Growth and shrink must update the existing content, not remount it")
    XCTAssertEqual(fixture.model.tapCount, 0)
  }

  func testDynamicTypeRemeasuresTheMountedCard() async throws {
    let fixture = try Fixture(text: longText)
    defer { fixture.close() }
    try await fixture.settle()
    let normal = try XCTUnwrap(fixture.probe.frames["bubble"])
    fixture.model.typeSize = .accessibility3
    try await fixture.settle()
    let enlarged = try XCTUnwrap(fixture.probe.frames["bubble"])
    XCTAssertGreaterThan(enlarged.height, normal.height + 1)
    try assertContained(fixture)
    attach(fixture, name: "accessibility3")
  }

  private func assertContained(_ fixture: Fixture,
    file: StaticString = #filePath, line: UInt = #line) throws {
    let bubble = try XCTUnwrap(fixture.probe.frames["bubble"], file: file, line: line)
    let text = try XCTUnwrap(fixture.probe.frames["text"], file: file, line: line)
    let reference = try XCTUnwrap(fixture.probe.placedReference, file: file, line: line)
    XCTAssertGreaterThan(bubble.height, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(bubble.height + 0.5, reference.height,
      "Limiter must reserve the actual child's height measured at its placed width", file: file, line: line)
    XCTAssertGreaterThanOrEqual(text.minY, bubble.minY - 0.5, file: file, line: line)
    XCTAssertLessThanOrEqual(text.maxY, bubble.maxY + 0.5,
      "The last rendered line must fit inside the rounded bubble", file: file, line: line)
    XCTAssertGreaterThanOrEqual(text.minX, bubble.minX - 0.5, file: file, line: line)
    XCTAssertLessThanOrEqual(text.maxX, bubble.maxX + 0.5, file: file, line: line)
    XCTAssertEqual(fixture.model.tapCount, 0, file: file, line: line)
  }

  private func attach(_ fixture: Fixture, name: String) {
    let receipt = XCTAttachment(string: "natural=\(fixture.probe.naturalMeasurements)\nplacedReference=\(String(describing: fixture.probe.placedReference))\nframes=\(fixture.probe.frames)\nappearances=\(fixture.probe.appearanceIDs)\ntaps=\(fixture.model.tapCount)")
    receipt.name = "chat-bubble-\(name)-geometry"
    receipt.lifetime = .keepAlways
    add(receipt)
    let renderer = UIGraphicsImageRenderer(bounds: fixture.window.bounds)
    let rendered = renderer.image { _ in
      fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
    }
    let screenshot = XCTAttachment(image: rendered)
    screenshot.name = "chat-bubble-\(name)-rendered"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  @Observable
  fileprivate final class Model {
    var text: String
    var width: CGFloat = 280
    var typeSize: DynamicTypeSize = .large
    var tapCount = 0
    let card: Bool
    init(text: String, card: Bool) { self.text = text; self.card = card }
  }

  private struct Screen: View {
    let model: Model
    let probe: Probe
    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        BubbleWidthLimiter(maxWidth: 280) {
          MeasuringContent(probe: probe) {
            Card(model: model, probe: probe)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
          probe.record(frame: $0, name: "bubble")
        }
      }
      .frame(width: model.width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .dynamicTypeSize(model.typeSize)
    }
  }

  private struct Card: View {
    let model: Model
    let probe: Probe
    @State private var identity = UUID()
    var body: some View {
      Group {
        if model.card {
          VStack(alignment: .leading, spacing: 8) {
            Text("Article").font(.caption)
            measuredText
          }
          .padding(12)
          // Match the cap around UnifiedEmbedView without making width fixed.
          .frame(maxWidth: 280, alignment: .leading)
          .feedEmbedCardStyle()
        } else {
          measuredText
        }
      }
      .onAppear { probe.record(appearance: identity) }
      .onTapGesture { model.tapCount += 1 }
    }
    private var measuredText: some View {
      Text(model.text)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
          probe.record(frame: $0, name: "text")
        }
    }
  }

  /// A transparent pass-through probe, not a replacement sizing algorithm.
  /// Its reference is the real child's answer at the actual placement width.
  private struct MeasuringContent: Layout {
    let probe: Probe
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      guard let child = subviews.first else { return .zero }
      let measured = child.sizeThatFits(proposal)
      if proposal.width == nil { probe.record(natural: measured) }
      return measured
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
      guard let child = subviews.first else { return }
      let placedProposal = ProposedViewSize(width: bounds.width, height: nil)
      probe.record(reference: child.sizeThatFits(placedProposal))
      child.place(at: bounds.origin, anchor: .topLeading, proposal: placedProposal)
    }
  }

  /// Layout is Sendable; guard all recorder access rather than publishing view
  /// state during measurement. Recording never invalidates the view hierarchy.
  private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var natural: [CGSize] = []
    private var reference: CGSize?
    private var recordedFrames: [String: CGRect] = [:]
    private var appearances: [UUID] = []
    var naturalMeasurements: [CGSize] { lock.withLock { natural } }
    var placedReference: CGSize? { lock.withLock { reference } }
    var frames: [String: CGRect] { lock.withLock { recordedFrames } }
    var appearanceIDs: [UUID] { lock.withLock { appearances } }
    func record(natural size: CGSize) { lock.withLock { natural.append(size) } }
    func record(reference size: CGSize) { lock.withLock { reference = size } }
    func record(frame: CGRect, name: String) { lock.withLock { recordedFrames[name] = frame } }
    func record(appearance id: UUID) { lock.withLock { appearances.append(id) } }
  }

  @MainActor
  private final class Fixture {
    let model: Model
    let probe = Probe()
    let window: UIWindow
    let host: UIHostingController<Screen>
    init(text: String, card: Bool = true) throws {
      model = Model(text: text, card: card)
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 1600)
      host = UIHostingController(rootView: Screen(model: model, probe: probe))
      host.safeAreaRegions = []
      window.rootViewController = host
      window.isHidden = false
    }
    func settle() async throws {
      for _ in 0..<8 {
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    func close() { window.isHidden = true; window.rootViewController = nil }
  }
}
#endif
