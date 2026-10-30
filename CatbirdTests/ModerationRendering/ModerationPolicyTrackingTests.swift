#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit

@testable import Catbird

// A `UIHostingConfiguration` closure runs once, when the cell is configured,
// so an environment value set inside it is a snapshot. The feed and thread
// cells wrap their content in `ModerationPolicyTracking`, which reads the
// policy in a SwiftUI body and therefore follows the observable source.

@MainActor
@Suite("Moderation rendering: hosted policy tracking", .serialized)
struct ModerationPolicyTrackingTests {
  private typealias F = RenderingFixtures

  /// The policy the hosted content read last, as the gates would.
  @MainActor
  private final class Seen {
    var policy: ModerationPolicy?
  }

  private struct Probe: View {
    @Environment(\.moderationPolicy) private var policy
    let seen: Seen

    var body: some View {
      Color.clear
        .frame(width: 10, height: 10)
        .onAppear { seen.policy = policy }
        .onChange(of: policy) { _, newValue in seen.policy = newValue }
    }
  }

  @Test("Content hosted through a UIHostingConfiguration follows a policy change when it tracks the source")
  func trackedPolicyUpdatesHostedContent() async throws {
    let box = PolicySource(F.policy(labels: ["nudity": "ignore"]))
    let seen = Seen()
    let configuration = UIHostingConfiguration {
      ModerationPolicyTracking(source: { box.policy }, content: Probe(seen: seen))
    }
    let window = host(configuration.makeContentView())
    defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { seen.policy == box.policy }

    let warned = F.policy(labels: ["nudity": "warn"])
    box.policy = warned
    try await eventually { seen.policy == warned }
    let post = try F.post(labels: [try F.label("nudity")], embed: F.imageEmbed)
    let presentation = PostModerationPresentation.make(post: post, policy: try #require(seen.policy))
    #expect(presentation.concealsMedia, "the row's media gate appears under the new policy")
  }

  @Test("Positive control: a policy set directly inside the configuration closure stays a snapshot")
  func untrackedPolicyStaysSnapshot() async throws {
    let box = PolicySource(F.policy(labels: ["nudity": "ignore"]))
    let seen = Seen()
    let configuration = UIHostingConfiguration {
      Probe(seen: seen).environment(\.moderationPolicy, box.policy)
    }
    let window = host(configuration.makeContentView())
    defer { window.isHidden = true; window.rootViewController = nil }
    let initial = box.policy
    try await eventually { seen.policy == initial }

    box.policy = F.policy(labels: ["nudity": "warn"])
    await settle(window)
    #expect(seen.policy == initial, "nothing re-runs the configuration closure")
  }

  private func host(_ view: UIView) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let controller = UIViewController()
    view.frame = CGRect(x: 0, y: 0, width: 390, height: 100)
    controller.view.addSubview(view)
    window.rootViewController = controller
    window.isHidden = false
    window.layoutIfNeeded()
    return window
  }

  private func settle(_ window: UIWindow) async {
    for _ in 0..<12 {
      window.setNeedsLayout()
      window.layoutIfNeeded()
      await Task.yield()
    }
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("The hosted content did not reach the expected state")
    throw TrackingFixtureError.timeout
  }
}

private enum TrackingFixtureError: Error { case timeout }

/// The observable source the hosted content reads, changed from the test like
/// a preference refresh changes `AppState.moderationPolicy`.
@MainActor
@Observable
private final class PolicySource {
  var policy: ModerationPolicy
  init(_ policy: ModerationPolicy) { self.policy = policy }
}
#endif
