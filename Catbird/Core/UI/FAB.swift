//
//  FAB.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/16/24.
//

import SwiftUI

struct FAB: View {
    let composeAction: () -> Void
    let feedsAction: () -> Void
    let showFeedsButton: Bool
    let hasMinimizedComposer: Bool
    let clearDraftAction: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.toastManager) private var toastManager
    // When the user enables Reduce Transparency, the translucent Liquid Glass
    // material is swapped for an opaque accent fill so the white glyph stays legible.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // Namespace for matched zoom transitions to the composer (provided by ContentView)
    @Environment(\.composerTransitionNamespace) private var composerNamespace

    private let circleSize: CGFloat = 62
    
    init(composeAction: @escaping () -> Void, feedsAction: @escaping () -> Void, showFeedsButton: Bool, hasMinimizedComposer: Bool = false, clearDraftAction: (() -> Void)? = nil) {
        self.composeAction = composeAction
        self.feedsAction = feedsAction
        self.showFeedsButton = showFeedsButton
        self.hasMinimizedComposer = hasMinimizedComposer
        self.clearDraftAction = clearDraftAction
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
                    composeButton
                        .clipShape(Circle())
                        .composeGlass(reduceTransparency: reduceTransparency)
                        .composerContextMenu(
                          hasMinimizedComposer: hasMinimizedComposer,
                          clearDraftAction: clearDraftAction
                        )
                        .accessibilityLabel(composeAccessibilityLabel)
                        .accessibilityHint(composeAccessibilityHint)
                } else {
                    composeButton
                        .composerContextMenu(
                          hasMinimizedComposer: hasMinimizedComposer,
                          clearDraftAction: clearDraftAction
                        )
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
    
    private var composeButton: some View {
        Button(action: composeAction) {
            if #available(iOS 26.0, macOS 26.0, *) {

            // Center the SF Symbol at 30x30, then place the badge
            // relative to the symbol's bounds (not the full 62pt circle).
            ZStack {
                    symbolWithBadge
                        .foregroundStyle(.white)
                }
            .frame(width: circleSize, height: circleSize)

//            .background(
//
//                (hasMinimizedComposer ? Color.accentColor.opacity(0.5) : Color.accentColor.opacity(0.8))
//
//            )
            .contentShape(Circle())
            .buttonStyle(.glassProminent) // requires iOS 26+ / macOS 26+
            // Mark the actual compose button as the matched transition source
            // instead of tagging the entire FAB container from the outside.
            .composerMatchedSource(namespace: composerNamespace)
            } else {
                ZStack {
                    symbolWithBadge
                        .foregroundStyle(.white)
                }
                .frame(width: circleSize, height: circleSize)
                
                //            .background(
                //
                //                (hasMinimizedComposer ? Color.accentColor.opacity(0.5) : Color.accentColor.opacity(0.8))
                //
                //            )
                .contentShape(Circle())
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

@available(iOS 26.0, macOS 26.0, *)
private extension View {
    /// Applies the compose FAB's Liquid Glass styling.
    ///
    /// The accent-tinted `.clear` glass keeps the button subtle over the feed
    /// while letting content show through. When Reduce Transparency is enabled,
    /// it falls back to the opaque `.regular` material so the white glyph never
    /// loses contrast against bright content scrolling underneath.
    @ViewBuilder
    func composeGlass(reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            self.glassEffect(.regular.tint(.accentColor).interactive())
        } else {
            self.glassEffect(.clear.tint(.accentColor).interactive())
        }
    }
}

private extension View {
    @ViewBuilder
    func composerContextMenu(
        hasMinimizedComposer: Bool,
        clearDraftAction: (() -> Void)?
    ) -> some View {
        if hasMinimizedComposer, let clearDraftAction {
            self.contextMenu {
                Button("Clear Draft", role: .destructive, action: clearDraftAction)
            }
        } else {
            self
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
      clearDraftAction: nil
    )
  }
}
