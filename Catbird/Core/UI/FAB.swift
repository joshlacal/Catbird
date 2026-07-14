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

enum FABQuickAction: CaseIterable {
    case newPost
    case browseDrafts
    case takePhoto
    case recordVideo

    var title: String {
        switch self {
        case .newPost: "New Post"
        case .browseDrafts: "Browse Drafts"
        case .takePhoto: "Take Photo"
        case .recordVideo: "Record Video"
        }
    }
}

struct FAB: View {
    let composeAction: () -> Void
    let feedsAction: () -> Void
    let showFeedsButton: Bool
    let hasMinimizedComposer: Bool
    let clearDraftAction: (() -> Void)?
    let newPostAction: (() -> Void)?
    let showDraftsAction: (() -> Void)?
    let takePhotoAction: (() -> Void)?
    let recordVideoAction: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.toastManager) private var toastManager
    // Namespace for matched zoom transitions to the composer (provided by ContentView)
    @Environment(\.composerTransitionNamespace) private var composerNamespace

    private let circleSize: CGFloat = 62
    
    init(
        composeAction: @escaping () -> Void,
        feedsAction: @escaping () -> Void,
        showFeedsButton: Bool,
        hasMinimizedComposer: Bool = false,
        clearDraftAction: (() -> Void)? = nil,
        newPostAction: (() -> Void)? = nil,
        showDraftsAction: (() -> Void)? = nil,
        takePhotoAction: (() -> Void)? = nil,
        recordVideoAction: (() -> Void)? = nil
    ) {
        self.composeAction = composeAction
        self.feedsAction = feedsAction
        self.showFeedsButton = showFeedsButton
        self.hasMinimizedComposer = hasMinimizedComposer
        self.clearDraftAction = clearDraftAction
        self.newPostAction = newPostAction
        self.showDraftsAction = showDraftsAction
        self.takePhotoAction = takePhotoAction
        self.recordVideoAction = recordVideoAction
    }
    
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                // Toast on the left
                if let toast = toastManager.currentToast {
                    ToastView(toast: toast) {
                        toastManager.dismiss()
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                
                if showFeedsButton {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        feedsButton
                            .clipShape(Circle())
                            .glassEffect()
                            .accessibilityLabel("Feeds")
                            .accessibilityHint("Browse and switch feeds")
                    } else {
                        feedsButton
                            .accessibilityLabel("Feeds")
                            .accessibilityHint("Browse and switch feeds")
                    }
                }
                Spacer()
                if #available(iOS 26.0, macOS 26.0, *) {
                    Menu {
                        composeMenuItems
                    } label: {
                        composeButtonLabel
                    } primaryAction: {
                        composeAction()
                    }
                        .buttonStyle(.glassProminent)
                        .clipShape(Circle())
                        .composerMatchedSource(namespace: composerNamespace)
                        .accessibilityLabel(composeAccessibilityLabel)
                        .accessibilityHint(composeAccessibilityHint)
                } else {
                    Menu {
                        composeMenuItems
                    } label: {
                        composeButtonLabel
                    } primaryAction: {
                        composeAction()
                    }
                        .accessibilityLabel(composeAccessibilityLabel)
                        .accessibilityHint(composeAccessibilityHint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
#if os(iOS)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 0)
            }
#elseif os(macOS)
            .padding(.bottom, 16)
#endif
        }
    }
    
    @ViewBuilder
    private var feedsButton: some View {
        if #available(iOS 26.0, macOS 26.0, *) {

        Button(action: feedsAction) {
            Image(systemName: "square.grid.3x3.square")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(.primary)
                .frame(width: circleSize, height: circleSize)
                .contentShape(Circle())
        }
        .buttonStyle(.glassProminent) // requires iOS 26+ / macOS 26+
        } else {
            Button(action: feedsAction) {
                Image(systemName: "square.grid.3x3.square")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.primary)
                    .frame(width: circleSize, height: circleSize)
                    .contentShape(Circle())
            }
        }
    }
    
    private var composeButtonLabel: some View {
        ZStack {
            symbolWithBadge
                .foregroundStyle(.white)
        }
        .frame(width: circleSize, height: circleSize)
        .contentShape(Circle())
    }

    @ViewBuilder
    private var composeMenuItems: some View {
        if let newPostAction {
            Button(action: newPostAction) {
                Label(FABQuickAction.newPost.title, systemImage: "square.and.pencil")
            }
        }
        if let showDraftsAction {
            Button(action: showDraftsAction) {
                Label(FABQuickAction.browseDrafts.title, systemImage: "doc.on.doc")
            }
        }
        #if os(iOS)
        if let takePhotoAction {
            Button(action: takePhotoAction) {
                Label(FABQuickAction.takePhoto.title, systemImage: "camera")
            }
        }
        if let recordVideoAction {
            Button(action: recordVideoAction) {
                Label(FABQuickAction.recordVideo.title, systemImage: "video")
            }
        }
        #endif

        if hasMinimizedComposer, let clearDraftAction {
            Divider()
            Button(role: .destructive, action: clearDraftAction) {
                Label("Clear Draft", systemImage: "trash")
            }
        }
    }

    // Builds the symbol and, when needed, a small badge anchored to the
    // symbol's top‑right corner so it plays nicely with Liquid Glass.
    private var symbolWithBadge: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: hasMinimizedComposer ? "doc.text" : "pencil")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            if hasMinimizedComposer {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 1.5)
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
        hasMinimizedComposer ? "Resume draft" : "Compose post"
    }

    private var composeAccessibilityHint: String {
        hasMinimizedComposer
            ? "Opens the post composer with your saved draft"
            : "Opens the post composer"
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
      clearDraftAction: nil,
      newPostAction: {},
      showDraftsAction: {},
      takePhotoAction: {},
      recordVideoAction: {}
    )
  }
}
