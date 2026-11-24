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
    toolbar.displayMode = .iconOnly
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

  private static var localizedTabTitles: [String] {
    [
      String(localized: "Home", comment: "Toolbar tab title for the Home timeline."),
      String(localized: "Search", comment: "Toolbar tab title for Search."),
      String(localized: "Notifications", comment: "Toolbar tab title for Notifications."),
      String(localized: "Profile", comment: "Toolbar tab title for Profile."),
      String(localized: "Messages", comment: "Toolbar tab title for Messages.")
    ]
  }

  func updateBadges(notifications: Int, messages: Int) {
    // Badges on NSToolbarItemGroup subitems — update the label to include count
    guard let group = tabGroup else { return }
    let titles = Self.localizedTabTitles
    for (i, title) in titles.enumerated() {
      let subitem = group.subitems[i]
      if i == 2 && notifications > 0 {
        subitem.label = String(
          localized: "\(title) (\(notifications))",
          comment: "Toolbar tab label with unread count — first variable is tab name, second is unread count."
        )
      } else if i == 4 && messages > 0 {
        subitem.label = String(
          localized: "\(title) (\(messages))",
          comment: "Toolbar tab label with unread count — first variable is tab name, second is unread count."
        )
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
      let newMessage = String(localized: "New Message", comment: "Toolbar button label and tooltip to start a new chat message.")
      composeItem?.toolTip = newMessage
      composeItem?.label = newMessage
    } else {
      let newPost = String(localized: "New Post", comment: "Toolbar button label and tooltip to compose a new post.")
      composeItem?.toolTip = newPost
      composeItem?.label = newPost
    }
  }

  func updateContextualItems(for tab: Int) {
    guard let item = contextualItem else { return }

    // Feed selector only visible on Home tab
    feedSelectorItem?.isHidden = (tab != 0)

    switch tab {
    case 0:
      item.image = UIImage(systemName: "arrow.clockwise")
      item.toolTip = String(localized: "Refresh Feed", comment: "Toolbar tooltip to refresh the current feed.")
      item.label = String(localized: "Refresh", comment: "Toolbar button label to refresh the current feed.")
      item.target = self
      item.action = #selector(refreshAction)
      item.isEnabled = true

    case 1:
      item.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
      item.toolTip = String(localized: "Search Filters", comment: "Toolbar tooltip to open search filters.")
      item.label = String(localized: "Filter", comment: "Toolbar button label to filter search results.")
      item.target = self
      item.action = #selector(searchFilterAction)
      item.isEnabled = true

    case 2:
      item.image = UIImage(systemName: "checkmark.circle")
      item.toolTip = String(localized: "Mark All as Read", comment: "Toolbar tooltip to mark all notifications as read.")
      item.label = String(localized: "Mark Read", comment: "Toolbar button label to mark notifications as read.")
      item.target = self
      item.action = #selector(markAllReadAction)
      item.isEnabled = true

    case 3:
      item.image = nil
      item.isEnabled = false

    case 4:
      item.image = UIImage(systemName: "tray.and.arrow.down")
      item.toolTip = String(localized: "Message Requests", comment: "Toolbar tooltip to view chat message requests.")
      item.label = String(localized: "Requests", comment: "Toolbar button label for chat message requests.")
      item.target = self
      item.action = #selector(messageRequestsAction)
      item.isEnabled = true

    default:
      item.image = nil
      item.isEnabled = false
    }
  }

  // MARK: - Avatar

  func updateAvatarImage(_ image: UIImage?) {
    guard let image = image else { return }
    let size = CGSize(width: 24, height: 24)
    UIGraphicsBeginImageContextWithOptions(size, false, 0)
    let rect = CGRect(origin: .zero, size: size)
    UIBezierPath(ovalIn: rect).addClip()
    image.draw(in: rect)
    let circularImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    settingsAvatarItem?.image = circularImage
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
      item.label = String(localized: "Feeds", comment: "Toolbar button label for opening the feeds selector.")
      item.toolTip = String(localized: "Feed Selector", comment: "Toolbar tooltip for opening the feeds selector.")
      item.target = self
      item.action = #selector(feedSelectorAction)
      feedSelectorItem = item
      return item

    case Self.tabSwitcherID:
      let titles = Self.localizedTabTitles
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
      group.label = String(localized: "Tabs", comment: "Toolbar item group label for the main navigation tabs.")
      tabGroup = group
      return group

    case Self.composeID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = UIImage(systemName: "square.and.pencil")
      let newPost = String(localized: "New Post", comment: "Toolbar button label and tooltip to compose a new post.")
      item.label = newPost
      item.toolTip = newPost
      item.target = self
      item.action = #selector(composeAction)
      composeItem = item
      return item

    case Self.contextualActionID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = String(localized: "Action", comment: "Generic toolbar item label for contextual tab actions.")
      contextualItem = item
      updateContextualItems(for: 0)
      return item

    case Self.settingsAvatarID:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = UIImage(systemName: "person.circle")
      item.label = String(localized: "Settings", comment: "Toolbar button label for opening Settings.")
      item.toolTip = String(localized: "Profile & Settings", comment: "Toolbar tooltip for opening Profile and Settings.")
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
