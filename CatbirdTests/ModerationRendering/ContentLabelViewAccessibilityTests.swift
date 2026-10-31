#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit

@testable import Catbird

/// The post label summary is one control: VoiceOver reads its label names, and activating it opens
/// the details sheet, as a tap does.
@MainActor
@Suite("Moderation rendering: post label summary accessibility", .serialized)
struct ContentLabelViewAccessibilityTests {
  private func cause(_ value: String) throws -> ModerationCause {
    let definition = try #require(ModerationLabelDefinition.builtins[value])
    let label = try RenderingFixtures.label(value)
    return ModerationCause(
      label: label, labelerDID: label.src.didString(), definition: definition, target: .content,
      setting: .warn, behavior: definition.behaviors[.content] ?? .noop, noOverride: false, priority: 7,
      source: .labeler(did: label.src.didString()))
  }

  @Test("Activating the post label summary opens its details, as a tap does")
  func activationOpensDetails() async throws {
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    let causes = [try cause("porn"), try cause("graphic-media")]
    // The reserved invalid domain keeps the details sheet's labeler lookup off the network.
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://label-summary.invalid")))
    let state = AppState(userDID: "did:plc:labelsummaryviewer", client: client)
    defer { state.cleanup() }

    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
    let host = UIHostingController(rootView: ContentLabelView(causes: causes).environment(state))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true; previousKeyWindow?.makeKey() }

    var summary: AppAccessibility.Element?
    for _ in 0..<40 where summary == nil {
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(25))
      summary = AppAccessibility.elements(in: host.view).first { $0.identifier == "postLabelSummary" }
    }
    let element = try #require(summary, "VoiceOver must reach the post label summary")
    let names = causes.map { ModerationPresentation.title(for: $0) }
    #expect(element.label == "Post labels: \(names.joined(separator: ", "))")
    #expect(element.traits.contains(.button), "VoiceOver must announce the summary as a button")
    #expect(element.object.accessibilityActivate())
    for _ in 0..<40 where host.presentedViewController == nil {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(host.presentedViewController != nil, "Activation must present the label details sheet")
    host.presentedViewController?.dismiss(animated: false)
  }
}
#endif
