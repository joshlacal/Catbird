//
//  PostOptionsMenuButton.swift
//  Catbird
//
//  The post header's options button, with a menu built only when it opens.
//
//  As a SwiftUI `Menu`, every feed row built a dozen buttons, labels and dividers
//  (and observed the state they read) for a menu that is rarely opened. This UIKit
//  button asks for its items when the menu is presented, so an idle row pays for
//  one view. Buttons are pooled across rows the same way as `FeedActionBar`.
//

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - SwiftUI bridge

struct PostOptionsMenuButton: UIViewRepresentable {
  let accessibilityLabel: String
  let accessibilityIdentifier: String?
  /// Called each time the menu opens, so items reflect the post's current state.
  let makeItems: () -> [UIMenuElement]

  func makeUIView(context: Context) -> PostOptionsMenuButtonView {
    PostOptionsMenuButtonView.dequeueReusable()
  }

  func updateUIView(_ view: PostOptionsMenuButtonView, context: Context) {
    view.makeItems = makeItems
    view.accessibilityLabel = accessibilityLabel
    view.accessibilityIdentifier = accessibilityIdentifier
  }

  static func dismantleUIView(_ view: PostOptionsMenuButtonView, coordinator: ()) {
    PostOptionsMenuButtonView.enqueueForReuse(view)
  }
}

// MARK: - View

/// A transparent button that fills its frame and presents a deferred menu. The visible
/// glyph is drawn by SwiftUI beneath it, so the header layout is unchanged.
final class PostOptionsMenuButtonView: UIButton {
  var makeItems: (() -> [UIMenuElement])?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isAccessibilityElement = true
    accessibilityTraits = .button
    showsMenuAsPrimaryAction = true
    menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.makeItems?() ?? [])
      }
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: Reuse

  private static var reusePool: [PostOptionsMenuButtonView] = []
  private static let reusePoolLimit = 24

  static func dequeueReusable() -> PostOptionsMenuButtonView {
    reusePool.popLast() ?? PostOptionsMenuButtonView()
  }

  static func enqueueForReuse(_ view: PostOptionsMenuButtonView) {
    view.removeFromSuperview()
    view.makeItems = nil
    guard reusePool.count < reusePoolLimit else { return }
    reusePool.append(view)
  }
}

// MARK: - Menu building

extension UIMenu {
  /// An inline section, drawn with separators around it like a SwiftUI `Divider`.
  static func inlineSection(_ children: [UIMenuElement]) -> UIMenu {
    UIMenu(options: .displayInline, children: children)
  }
}

extension UIAction {
  /// A menu action with an SF Symbol and an optional destructive style.
  static func postOption(
    _ title: String, systemImage: String, destructive: Bool = false,
    identifier: String? = nil, handler: @escaping () -> Void
  ) -> UIAction {
    let action = UIAction(
      title: title, image: UIImage(systemName: systemImage),
      attributes: destructive ? .destructive : []
    ) { _ in handler() }
    if let identifier { action.accessibilityIdentifier = identifier }
    return action
  }
}
#endif
