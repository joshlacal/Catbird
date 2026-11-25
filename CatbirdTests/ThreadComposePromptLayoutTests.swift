import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Thread compose prompt layout")
@MainActor
struct ThreadComposePromptLayoutTests {
  @Test("Quick reply host uses its intrinsic content height")
  func quickReplyHostUsesIntrinsicContentHeight() {
    let hostingController = ThreadViewController.makeComposePromptHostingController(
      rootView: AnyView(Text("Write your reply"))
    )

    #expect(hostingController.sizingOptions.contains(.intrinsicContentSize))
    #expect(hostingController.view.contentHuggingPriority(for: .vertical) == .required)
    #expect(hostingController.view.contentCompressionResistancePriority(for: .vertical) == .required)
    #expect(hostingController.safeAreaRegions.isEmpty)
  }

  /// The prompt only opens the composer sheet, so it must not follow the keyboard:
  /// the composer's keyboard, dismissed together with its sheet, can leave
  /// `keyboardLayoutGuide` resting above the tab bar and float the capsule over a gap.
  @Test("Prompt is pinned to the bottom safe area, not the keyboard guide")
  func promptPinsToSafeAreaNotKeyboard() {
    let view = UIView()
    let container = UIView()
    view.addSubview(container)
    let constraint = ThreadViewController.makeComposePromptBottomConstraint(container: container, in: view)
    #expect(constraint.firstItem === container)
    #expect(constraint.firstAttribute == .bottom)
    #expect(constraint.secondItem === view.safeAreaLayoutGuide)
    #expect(constraint.secondAttribute == .bottom)
    #expect(constraint.secondItem !== view.keyboardLayoutGuide)
    #expect(constraint.relation == .equal)
    #expect(constraint.constant == 0)
  }

  @Test("Reply content resists a full-screen vertical proposal and still wraps")
  func promptKeepsNaturalHeight() {
    let host = ThreadViewController.makeComposePromptHostingController(
      rootView: AnyView(
        Text("Write your reply with enough text to wrap at a narrow width")
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      )
    )
    let wide = host.sizeThatFits(in: CGSize(width: 390, height: 800))
    let narrow = host.sizeThatFits(in: CGSize(width: 180, height: 800))
    #expect(wide.height < 200)
    #expect(narrow.height > wide.height)
    #expect(narrow.height < 400)
  }

  /// The thread controller pins the prompt container to the bottom safe area,
  /// which already sits above the tab bar and home indicator. When the bottom safe
  /// area grows (tab bar settling after a push, minimised tab bar expanding), the
  /// host's old frame briefly overlaps the new safe area. The host must not turn
  /// that transient overlap into extra height, or the capsule floats above an empty
  /// band until another layout happens to shrink it again.
  @Test("Prompt stays on the tab bar edge when the bottom safe area grows")
  func promptIgnoresBottomSafeAreaGrowth() async throws {
    let scene = try #require(UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    let parent = UIViewController()
    window.rootViewController = parent
    window.isHidden = false
    defer { window.isHidden = true }

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    parent.view.addSubview(container)
    let host = ThreadViewController.makeComposePromptHostingController(
      rootView: AnyView(
        Text("Write your reply")
          .padding(.vertical, 8)
          .frame(minHeight: 44)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      )
    )
    host.view.translatesAutoresizingMaskIntoConstraints = false
    host.view.backgroundColor = .clear
    parent.addChild(host)
    container.addSubview(host.view)
    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.trailingAnchor),
      ThreadViewController.makeComposePromptBottomConstraint(container: container, in: parent.view),
      host.view.topAnchor.constraint(equalTo: container.topAnchor),
      host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    host.didMove(toParent: parent)

    func settle() async {
      for _ in 0..<6 {
        parent.view.setNeedsLayout()
        parent.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(16))
      }
    }

    await settle()
    let restingHeight = host.view.frame.height
    #expect(restingHeight > 0 && restingHeight < 120)

    for bottom in [CGFloat(49), 100, 0, 100] {
      parent.additionalSafeAreaInsets.bottom = bottom
      parent.view.layoutIfNeeded()
      // The first pass after the change is where a stale overlap would be absorbed.
      #expect(abs(host.view.frame.height - restingHeight) < 0.5,
              "bottom=\(bottom) first-pass height \(host.view.frame.height) vs \(restingHeight)")
      await settle()
      let safeBottom = parent.view.safeAreaLayoutGuide.layoutFrame.maxY
      let hostBottom = host.view.convert(host.view.bounds, to: parent.view).maxY
      #expect(abs(host.view.frame.height - restingHeight) < 0.5,
              "bottom=\(bottom) settled height \(host.view.frame.height) vs \(restingHeight)")
      #expect(abs(hostBottom - safeBottom) < 0.5)
    }
  }

  /// Positioning is UIKit's job: the controller pins the prompt container to the
  /// bottom safe area, which already clears the tab bar and home indicator. If the
  /// hosted SwiftUI view also honours safe-area insets, any layout in which the
  /// host overlaps the bottom inset (a frame computed before the inset settled, a
  /// tab-bar or window geometry change, an interrupted transition) adds that inset
  /// a second time as empty space under the capsule.
  @Test("Prompt height does not depend on overlapping the bottom safe area")
  func promptHeightIgnoresSafeAreaOverlap() async throws {
    let scene = try #require(UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    let parent = UIViewController()
    parent.additionalSafeAreaInsets.bottom = 83
    window.rootViewController = parent
    window.isHidden = false
    defer { window.isHidden = true }

    let host = ThreadViewController.makeComposePromptHostingController(
      rootView: AnyView(Text("Write your reply").padding(.vertical, 8).frame(minHeight: 44)
        .frame(maxWidth: .infinity).padding(.vertical, 8))
    )
    host.view.translatesAutoresizingMaskIntoConstraints = false
    parent.addChild(host)
    parent.view.addSubview(host.view)
    let clear = host.view.bottomAnchor.constraint(equalTo: parent.view.safeAreaLayoutGuide.bottomAnchor)
    let overlapping = host.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
      clear
    ])
    host.didMove(toParent: parent)

    func settle() async {
      for _ in 0..<4 {
        parent.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
    await settle()
    let natural = host.view.frame.height

    clear.isActive = false
    overlapping.isActive = true
    await settle()
    #expect(abs(host.view.frame.height - natural) < 0.5,
            "overlapping host grew from \(natural) to \(host.view.frame.height)")

    overlapping.isActive = false
    clear.isActive = true
    await settle()
    #expect(abs(host.view.frame.height - natural) < 0.5)
  }
}
