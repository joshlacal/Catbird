import UIKit
import SwiftUI
import os

/// A 52pt-tall tab bar that:
/// - iOS 26+: embeds a SwiftUI GlassEffectContainer segmented control
/// - iOS <26: uses a UISegmentedControl with regularMaterial background
@available(iOS 18.0, *)
final class ProfileTabBar: UIView {

  // MARK: - Public State
  var selectedTab: ProfileTab = .posts {
    didSet {
      guard oldValue != selectedTab else { return }
      updateSelection()
    }
  }
  var onTabChange: ((ProfileTab) -> Void)?

  /// Set to true when the tab bar is stuck to the top — shows full material background.
  /// False = natural position, background is slightly more transparent.
  var isAtTop: Bool = false {
    didSet {
      UIView.animate(withDuration: 0.2) {
        self.materialView.alpha = self.isAtTop ? 1.0 : 0.85
      }
    }
  }

  // MARK: - Constants
  static let height: CGFloat = 52

  // MARK: - Private
  private var sections: [ProfileTab] = ProfileTab.userTabs
  private var materialView: UIVisualEffectView!
  private var segmentedControl: UISegmentedControl?
  private var glassHostingController: UIViewController?

  private let tabBarLogger = Logger(subsystem: "blue.catbird", category: "ProfileTabBar")

  // MARK: - Initialization
  init(isLabeler: Bool) {
    self.sections = isLabeler ? ProfileTab.labelerTabs : ProfileTab.userTabs
    super.init(frame: .zero)
    setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }

  // MARK: - Setup
  private func setupViews() {
    // Material background
      let effect = UIBlurEffect(style: .systemMaterial)
    materialView = UIVisualEffectView(effect: effect)
    materialView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(materialView)
    NSLayoutConstraint.activate([
      materialView.topAnchor.constraint(equalTo: topAnchor),
      materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
      materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
      materialView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])

    if #available(iOS 26, *) {
      setupGlassTabSelector()
    } else {
      setupSegmentedControl()
    }
  }

  @available(iOS 26, *)
  private func setupGlassTabSelector() {
    let glassView = GlassTabSelectorView(
      selectedTab: selectedTab,
      sections: sections,
      onSelect: { [weak self] tab in
        self?.handleTabSelection(tab)
      }
    )
    let hostingVC = UIHostingController(rootView: glassView)
    hostingVC.view.backgroundColor = .clear
    hostingVC.view.translatesAutoresizingMaskIntoConstraints = false
    materialView.contentView.addSubview(hostingVC.view)

    NSLayoutConstraint.activate([
      hostingVC.view.topAnchor.constraint(equalTo: materialView.contentView.topAnchor, constant: 6),
      hostingVC.view.bottomAnchor.constraint(equalTo: materialView.contentView.bottomAnchor, constant: -6),
      hostingVC.view.leadingAnchor.constraint(equalTo: materialView.contentView.leadingAnchor, constant: 16),
      hostingVC.view.trailingAnchor.constraint(equalTo: materialView.contentView.trailingAnchor, constant: -16)
    ])

    self.glassHostingController = hostingVC
  }

  private func setupSegmentedControl() {
    let items = sections.map { $0.title }
    let seg = UISegmentedControl(items: items)
    seg.translatesAutoresizingMaskIntoConstraints = false
    seg.selectedSegmentIndex = sections.firstIndex(of: selectedTab) ?? 0
    seg.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
    materialView.contentView.addSubview(seg)

    NSLayoutConstraint.activate([
      seg.centerYAnchor.constraint(equalTo: materialView.contentView.centerYAnchor),
      seg.leadingAnchor.constraint(equalTo: materialView.contentView.leadingAnchor, constant: 16),
      seg.trailingAnchor.constraint(equalTo: materialView.contentView.trailingAnchor, constant: -16)
    ])

    self.segmentedControl = seg
  }

  // MARK: - Tab Handling
  private func handleTabSelection(_ tab: ProfileTab) {
    guard tab != selectedTab else { return }
    selectedTab = tab
    onTabChange?(tab)
  }

  @objc private func segmentChanged(_ sender: UISegmentedControl) {
    let index = sender.selectedSegmentIndex
    guard index >= 0, index < sections.count else { return }
    handleTabSelection(sections[index])
  }

  private func updateSelection() {
    if #available(iOS 26, *) {
      guard let hostingVC = glassHostingController as? UIHostingController<GlassTabSelectorView> else { return }
      var updated = hostingVC.rootView
      updated.selectedTab = selectedTab
      hostingVC.rootView = updated
    } else {
      let idx = sections.firstIndex(of: selectedTab) ?? 0
      segmentedControl?.selectedSegmentIndex = idx
    }
  }

  // MARK: - Update Sections
  func updateSections(isLabeler: Bool) {
    sections = isLabeler ? ProfileTab.labelerTabs : ProfileTab.userTabs
    // Rebuild UI
    subviews.forEach { $0.removeFromSuperview() }
    setupViews()
  }
}

// MARK: - Glass Tab Selector (iOS 26+)
@available(iOS 26, *)
struct GlassTabSelectorView: View {
  var selectedTab: ProfileTab
  let sections: [ProfileTab]
  let onSelect: (ProfileTab) -> Void

  var body: some View {
    GlassEffectContainer(spacing: 4) {
      HStack(spacing: 4) {
        ForEach(sections, id: \.self) { tab in
          Button(tab.title) { onSelect(tab) }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(
              selectedTab == tab
                ? .regular.tint(Color.accentColor).interactive()
                : .regular.interactive(),
              in: .capsule
            )
        }
      }
    }
  }
}
