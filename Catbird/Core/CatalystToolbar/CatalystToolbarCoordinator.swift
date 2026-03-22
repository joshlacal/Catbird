#if targetEnvironment(macCatalyst)
import UIKit
import SwiftUI

final class CatalystToolbarCoordinator: NSObject {
  // MARK: - Toolbar Item Identifiers

  static let feedSelectorID = NSToolbarItem.Identifier("feedSelector")
  static let tabSwitcherID = NSToolbarItem.Identifier("tabSwitcher")
  static let composeID = NSToolbarItem.Identifier("compose")
  static let contextualActionID = NSToolbarItem.Identifier("contextualAction")
  static let settingsAvatarID = NSToolbarItem.Identifier("settingsAvatar")

  // MARK: - Action Closures

  var onTabSelected: ((Int) -> Void)?
  var onComposeTapped: (() -> Void)?
  var onNewMessageTapped: (() -> Void)?
  var onSettingsTapped: (() -> Void)?
  var onRefreshTapped: (() -> Void)?
  var onFeedSelectorTapped: (() -> Void)?
  var onMarkAllReadTapped: (() -> Void)?
  var onSearchFilterTapped: (() -> Void)?
  var onMessageRequestsTapped: (() -> Void)?

  // MARK: - State

  private(set) var currentTab: Int = 0
  private let toolbar: NSToolbar

  // MARK: - Item Views

  private lazy var segmentedControl: BadgedSegmentedControl = {
    let titles = ["Home", "Search", "Notifications", "Profile", "Messages"]
    let images = ["house", "magnifyingglass", "bell", "person", "envelope"]
    let sc = BadgedSegmentedControl(frame: .zero)
    for (i, title) in titles.enumerated() {
      sc.insertSegment(action: UIAction(title: title, image: UIImage(systemName: images[i])) { [weak self] _ in
        self?.handleSegmentChange(index: i)
      }, at: i, animated: false)
    }
    sc.selectedSegmentIndex = 0
    sc.sizeToFit()
    sc.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
    return sc
  }()

  private var feedSelectorItem: NSToolbarItem?
  private var contextualItem: NSToolbarItem?
  private var composeItem: NSToolbarItem?

  // MARK: - Avatar View

  private var avatarHostingController: UIHostingController<AnyView>?

  var avatarHostingView: UIView? {
    didSet {
      if let item = settingsAvatarItem, let view = avatarHostingView {
        setCustomView(view, on: item)
      }
    }
  }

  func setAvatarView<V: View>(_ view: V) {
    let hc = UIHostingController(rootView: AnyView(view))
    hc.view.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
    hc.view.backgroundColor = .clear
    avatarHostingController = hc
    avatarHostingView = hc.view
  }

  private var settingsAvatarItem: NSToolbarItem?

  // MARK: - Init

  init(identifier: NSToolbar.Identifier = NSToolbar.Identifier("CatbirdMainToolbar")) {
    toolbar = NSToolbar(identifier: identifier)
    super.init()
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
  }

  var nsToolbar: NSToolbar { toolbar }

  // MARK: - Public API

  func selectTab(_ tab: Int) {
    guard tab != segmentedControl.selectedSegmentIndex else { return }
    segmentedControl.selectedSegmentIndex = tab
    currentTab = tab
    updateContextualItems(for: tab)
    updateComposeTooltip(for: tab)
  }

  func updateBadges(notifications: Int, messages: Int) {
    segmentedControl.setBadge(notifications, forSegment: 2)
    segmentedControl.setBadge(messages, forSegment: 4)
  }

  func setFeedSelectorEnabled(_ enabled: Bool) {
    feedSelectorItem?.isEnabled = enabled
  }

  // MARK: - Private

  private func handleSegmentChange(index: Int) {
    currentTab = index
    onTabSelected?(index)
    updateContextualItems(for: index)
    updateComposeTooltip(for: index)
  }

  private func updateComposeTooltip(for tab: Int) {
    if tab == 4 {
      composeItem?.toolTip = "New Message"
      composeItem?.label = "New Message"
    } else {
      composeItem?.toolTip = "New Post"
      composeItem?.label = "New Post"
    }
  }

  func updateContextualItems(for tab: Int) {
    guard let item = contextualItem else { return }

    switch tab {
    case 0:
      item.image = UIImage(systemName: "arrow.clockwise")
      item.toolTip = "Refresh Feed"
      item.label = "Refresh"
      item.target = self
      item.action = #selector(refreshAction)
      item.isEnabled = true
      feedSelectorItem?.isEnabled = true

    case 1:
      item.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
      item.toolTip = "Search Filters"
      item.label = "Filter"
      item.target = self
      item.action = #selector(searchFilterAction)
      item.isEnabled = true
      feedSelectorItem?.isEnabled = false

    case 2:
      item.image = UIImage(systemName: "checkmark.circle")
      item.toolTip = "Mark All as Read"
      item.label = "Mark Read"
      item.target = self
      item.action = #selector(markAllReadAction)
      item.isEnabled = true
      feedSelectorItem?.isEnabled = false

    case 3:
      item.image = nil
      item.isEnabled = false
      feedSelectorItem?.isEnabled = false

    case 4:
      item.image = UIImage(systemName: "tray.and.arrow.down")
      item.toolTip = "Message Requests"
      item.label = "Requests"
      item.target = self
      item.action = #selector(messageRequestsAction)
      item.isEnabled = true
      feedSelectorItem?.isEnabled = false

    default:
      item.image = nil
      item.isEnabled = false
      feedSelectorItem?.isEnabled = false
    }
  }

  // MARK: - Custom View Helper

  /// Sets a UIView as the custom view on an NSToolbarItem using KVC.
  /// In Mac Catalyst, NSToolbarItem.view is unavailable at compile time
  /// but the underlying property exists at runtime.
  private func setCustomView(_ view: UIView, on item: NSToolbarItem) {
    item.setValue(view, forKey: "view")
  }

  // MARK: - Actions

  @objc private func composeAction() {
    if currentTab == 4 {
      onNewMessageTapped?()
    } else {
      onComposeTapped?()
    }
  }

  @objc private func feedSelectorAction() { onFeedSelectorTapped?() }
  @objc private func settingsAction() { onSettingsTapped?() }
  @objc private func refreshAction() { onRefreshTapped?() }
  @objc private func searchFilterAction() { onSearchFilterTapped?() }
  @objc private func markAllReadAction() { onMarkAllReadTapped?() }
  @objc private func messageRequestsAction() { onMessageRequestsTapped?() }
}

// MARK: - NSToolbarDelegate

extension CatalystToolbarCoordinator: NSToolbarDelegate {
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      Self.feedSelectorID,
      .flexibleSpace,
      Self.tabSwitcherID,
      .flexibleSpace,
      Self.composeID,
      Self.contextualActionID,
      Self.settingsAvatarID
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case Self.feedSelectorID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = UIImage(systemName: "square.grid.3x3.fill")
      item.label = "Feeds"
      item.toolTip = "Feed Selector"
      item.target = self
      item.action = #selector(feedSelectorAction)
      item.isBordered = true
      feedSelectorItem = item
      return item

    case Self.tabSwitcherID:
      let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
      setCustomView(segmentedControl, on: group)
      group.label = "Tabs"
      return group

    case Self.composeID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = UIImage(systemName: "square.and.pencil")
      item.label = "New Post"
      item.toolTip = "New Post"
      item.target = self
      item.action = #selector(composeAction)
      item.isBordered = true
      composeItem = item
      return item

    case Self.contextualActionID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Action"
      item.isBordered = true
      contextualItem = item
      updateContextualItems(for: 0)
      return item

    case Self.settingsAvatarID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Settings"
      item.toolTip = "Profile & Settings"
      item.target = self
      item.action = #selector(settingsAction)
      if let view = avatarHostingView {
        setCustomView(view, on: item)
      }
      settingsAvatarItem = item
      return item

    default:
      return nil
    }
  }
}
#endif
