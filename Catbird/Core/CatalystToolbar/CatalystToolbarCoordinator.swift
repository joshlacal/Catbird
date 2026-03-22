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

  // Tab subitem identifiers
  static let tabIDs: [NSToolbarItem.Identifier] = (0..<5).map {
    NSToolbarItem.Identifier("tab_\($0)")
  }

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

  // MARK: - Items

  private var feedSelectorItem: NSToolbarItem?
  private var contextualItem: NSToolbarItem?
  private var composeItem: NSToolbarItem?
  private var tabGroup: NSToolbarItemGroup?
  private var settingsAvatarItem: NSToolbarItem?

  // MARK: - Init

  init(identifier: NSToolbar.Identifier = NSToolbar.Identifier("CatbirdMainToolbar")) {
    toolbar = NSToolbar(identifier: identifier)
    super.init()
    toolbar.delegate = self
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
  }

  var nsToolbar: NSToolbar { toolbar }

  // MARK: - Public API

  func selectTab(_ tab: Int) {
    guard tab != currentTab, tab >= 0, tab < 5 else { return }
    currentTab = tab
    tabGroup?.selectedIndex = tab
    updateContextualItems(for: tab)
    updateComposeTooltip(for: tab)
  }

  func updateBadges(notifications: Int, messages: Int) {
    // Badges on NSToolbarItemGroup subitems — update the label to include count
    guard let group = tabGroup else { return }
    let titles = ["Home", "Search", "Notifications", "Profile", "Messages"]
    for (i, title) in titles.enumerated() {
      let subitem = group.subitems[i]
      if i == 2 && notifications > 0 {
        subitem.label = "\(title) (\(notifications))"
      } else if i == 4 && messages > 0 {
        subitem.label = "\(title) (\(messages))"
      } else {
        subitem.label = title
      }
    }
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

  @objc private func tabAction(_ sender: Any?) {
    guard let group = tabGroup else { return }
    let index = group.selectedIndex
    guard index >= 0, index < 5 else { return }
    handleSegmentChange(index: index)
  }
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
      feedSelectorItem = item
      return item

    case Self.tabSwitcherID:
      let titles = ["Home", "Search", "Notifications", "Profile", "Messages"]
      let images = ["house", "magnifyingglass", "bell", "person", "envelope"]

      // Create individual subitems for each tab
      let subitems: [NSToolbarItem] = (0..<5).map { i in
        let subitem = NSToolbarItem(itemIdentifier: Self.tabIDs[i])
        subitem.image = UIImage(systemName: images[i])
        subitem.label = titles[i]
        subitem.target = self
        subitem.action = #selector(tabAction(_:))
        return subitem
      }

      let group = NSToolbarItemGroup(
        itemIdentifier: itemIdentifier,
        titles: titles,
        selectionMode: .selectOne,
        labels: titles,
        target: self,
        action: #selector(tabAction(_:))
      )
      group.setSelected(true, at: 0)
      group.label = "Tabs"
      tabGroup = group
      return group

    case Self.composeID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = UIImage(systemName: "square.and.pencil")
      item.label = "New Post"
      item.toolTip = "New Post"
      item.target = self
      item.action = #selector(composeAction)
      composeItem = item
      return item

    case Self.contextualActionID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Action"
      contextualItem = item
      updateContextualItems(for: 0)
      return item

    case Self.settingsAvatarID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = UIImage(systemName: "person.circle")
      item.label = "Settings"
      item.toolTip = "Profile & Settings"
      item.target = self
      item.action = #selector(settingsAction)
      settingsAvatarItem = item
      return item

    default:
      return nil
    }
  }
}
#endif
