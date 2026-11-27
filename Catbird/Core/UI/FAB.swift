//
//  FAB.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/16/24.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum FABQuickAction: CaseIterable, Hashable, Identifiable {
  case newPost
  case browseDrafts
  case takePhoto
  case recordVideo

  static let productionMenuActions = allCases

  var id: Self { self }

  var localizedTitle: LocalizedStringResource {
    switch self {
    case .newPost:
      LocalizedStringResource("New Post", comment: "Floating action button menu item to start a new post.")
    case .browseDrafts:
      LocalizedStringResource("Browse Drafts", comment: "Floating action button menu item to view saved post drafts.")
    case .takePhoto:
      LocalizedStringResource("Take Photo", comment: "Floating action button menu item to capture a photo for a post.")
    case .recordVideo:
      LocalizedStringResource("Record Video", comment: "Floating action button menu item to record a video for a post.")
    }
  }

  var title: String {
    String(localized: localizedTitle)
  }

  var systemImage: String {
    switch self {
    case .newPost: "square.and.pencil"
    case .browseDrafts: "doc.on.doc"
    case .takePhoto: "camera"
    case .recordVideo: "video"
    }
  }
}

struct FAB: View {
  let composeAction: () -> Void
  let feedsAction: () -> Void
  let showFeedsButton: Bool
  let hasMinimizedComposer: Bool
  let newPostAction: () -> Void
  let showDraftsAction: () -> Void
  let takePhotoAction: () -> Void
  let recordVideoAction: () -> Void
  let clearDraftAction: (() -> Void)?

  @Environment(\.colorScheme) var colorScheme
  @Environment(\.catbirdTheme) private var theme
  // Namespace for matched zoom transitions to the composer (provided by ContentView)
  @Environment(\.composerTransitionNamespace) private var composerNamespace

  private let circleSize: CGFloat = 62

  init(
    composeAction: @escaping () -> Void,
    feedsAction: @escaping () -> Void,
    showFeedsButton: Bool,
    hasMinimizedComposer: Bool = false,
    newPostAction: @escaping () -> Void,
    showDraftsAction: @escaping () -> Void,
    takePhotoAction: @escaping () -> Void,
    recordVideoAction: @escaping () -> Void,
    clearDraftAction: (() -> Void)? = nil
  ) {
    self.composeAction = composeAction
    self.feedsAction = feedsAction
    self.showFeedsButton = showFeedsButton
    self.hasMinimizedComposer = hasMinimizedComposer
    self.newPostAction = newPostAction
    self.showDraftsAction = showDraftsAction
    self.takePhotoAction = takePhotoAction
    self.recordVideoAction = recordVideoAction
    self.clearDraftAction = clearDraftAction
  }

  var body: some View {
    VStack {
      Spacer()
      HStack(spacing: Space.md) {
        if showFeedsButton {
          feedsButton
            .accessibilityLabel("Feeds")
            .accessibilityHint("Browse and switch feeds")
        }
        Spacer()
        Menu {
          composeMenuItems
        } label: {
          // The zoom source must sit on the rendered label, not on the Menu wrapper,
          // so the composer sheet performs the Liquid Glass zoom transition.
          composeButtonLabel
            .modifier(FABComposerMatchedSourceModifier(namespace: composerNamespace))
        } primaryAction: {
          Self.triggerTapHaptic()
          self.composeAction()
        }
        .clipShape(Circle())
        .catbirdGlass(.clear, in: Circle(), interactive: true, tinted: true)
        .catbirdElevation(.floating)
        .accessibilityLabel(composeAccessibilityLabel)
        .accessibilityHint(composeAccessibilityHint)
        .accessibilityIdentifier("compose.fab")
      }
      .padding(buttonInsets)
    }
  }

  /// Shared with Messages: spacing inside the native tab-content boundary.
  /// Native bars and keyboards supply their own safe area; no extra inset is reserved.
  private var buttonInsets: EdgeInsets {
    #if os(iOS)
    EdgeInsets(top: 0, leading: Space.xl, bottom: Space.xl, trailing: Space.xl)
    #else
    EdgeInsets(top: 0, leading: Space.lg, bottom: Space.x3l, trailing: Space.lg)
    #endif
  }

  private var feedsButton: some View {
    Button {
      Self.triggerTapHaptic()
      self.feedsAction()
    } label: {
      Image(systemName: "square.grid.3x3.square")
        .resizable()
        .scaledToFit()
        .frame(width: 30, height: 30)
        .foregroundStyle(theme.text(.primary))
        .frame(width: circleSize, height: circleSize)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .clipShape(Circle())
    .catbirdGlass(.regular, in: Circle(), interactive: true, tinted: false)
    .catbirdElevation(.floating)
  }

  private var composeButtonLabel: some View {
    ZStack {
      symbolWithBadge
        .foregroundStyle(theme.onAccent)
    }
    .frame(width: circleSize, height: circleSize)
    .contentShape(Circle())
  }

  @ViewBuilder
  private var composeMenuItems: some View {
    ForEach(availableQuickActions) { quickAction in
      Button {
        self.perform(quickAction)
      } label: {
        Label(quickAction.localizedTitle, systemImage: quickAction.systemImage)
      }
    }

    // Only offered while a working draft exists. Destructive, so it sits
    // below a divider, away from the creation actions.
    if hasMinimizedComposer, let clearDraftAction {
      Divider()
      Button(role: .destructive) {
        clearDraftAction()
      } label: {
        Label {
          Text("Clear Draft", comment: "Destructive floating action button menu item to discard current minimized post draft.")
        } icon: {
          Image(systemName: "trash")
        }
      }
    }
  }

  /// Camera capture is iOS-only and unavailable on the Simulator, so those
  /// actions are hidden rather than offered as dead menu items.
  private var availableQuickActions: [FABQuickAction] {
    FABQuickAction.productionMenuActions.filter { quickAction in
      switch quickAction {
      case .newPost, .browseDrafts:
        return true
      case .takePhoto, .recordVideo:
        #if os(iOS)
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        return false
        #endif
      }
    }
  }

  private func perform(_ quickAction: FABQuickAction) {
    switch quickAction {
    case .newPost: newPostAction()
    case .browseDrafts: showDraftsAction()
    case .takePhoto: takePhotoAction()
    case .recordVideo: recordVideoAction()
    }
  }

  // Builds the symbol and, when needed, a small badge anchored to the
  // symbol's top-right corner so it plays nicely with Liquid Glass.
  private var symbolWithBadge: some View {
    ZStack(alignment: .topTrailing) {
      Image(systemName: hasMinimizedComposer ? "doc.text" : "pencil")
        .resizable()
        .scaledToFit()
        .frame(width: 30, height: 30)

      if hasMinimizedComposer {
        Circle()
          .fill(theme.accentChrome)
          .frame(width: 10, height: 10)
          .overlay(
            Circle()
              .stroke(theme.onAccent, lineWidth: 1.5)
          )
          // Nudge inward slightly to sit over the symbol's corner
          .offset(x: -1.5, y: 1.5)
          .allowsHitTesting(false)
          // Decorative: the draft state is announced via the button's
          // accessibility label, so the dot itself is hidden from VoiceOver.
          .accessibilityHidden(true)
      }
    }
  }

  // MARK: - Accessibility

  private var composeAccessibilityLabel: String {
    hasMinimizedComposer
      ? String(localized: "Resume draft", comment: "Accessibility label on compose floating button when a minimized draft is waiting.")
      : String(localized: "Compose post", comment: "Accessibility label on compose floating button.")
  }

  private var composeAccessibilityHint: String {
    hasMinimizedComposer
      ? String(localized: "Opens the post composer with your saved draft", comment: "Accessibility hint on compose floating button when a draft exists.")
      : String(localized: "Opens the post composer", comment: "Accessibility hint on compose floating button.")
  }

  private static func triggerTapHaptic() {
    #if os(iOS)
    PlatformHaptics.light()
    #endif
  }
}

private struct FABComposerMatchedSourceModifier: ViewModifier {
  let namespace: Namespace.ID?

  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.composerMatchedSource(namespace: namespace)
    } else {
      content
    }
  }
}

#Preview("FAB") {
  ZStack {
    Color.systemGroupedBackground.ignoresSafeArea()
    FAB(
      composeAction: {},
      feedsAction: {},
      showFeedsButton: true,
      hasMinimizedComposer: false,
      newPostAction: {},
      showDraftsAction: {},
      takePhotoAction: {},
      recordVideoAction: {}
    )
  }
}
