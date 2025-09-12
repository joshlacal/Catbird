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
                if showFeedsButton {
                    if #available(iOS 26.0, *) {
                        feedsButton
                            .clipShape(Circle())
                            .glassEffect()
                    } else {
                        feedsButton
                    }
                }
                Spacer()
                if #available(iOS 26.0, *) {
                    composeButton
                        .clipShape(Circle())
                        .glassEffect(.regular.tint(.accentColor).interactive())
                } else {
                    composeButton
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
        if #available(iOS 26.0, *) {

        Button(action: feedsAction) {
            Image(systemName: "square.grid.3x3.square")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(.primary)
                .frame(width: circleSize, height: circleSize)
                .contentShape(Circle())
        }
        .buttonStyle(.glassProminent)
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
            if #available(iOS 26.0, *) {

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
            .buttonStyle(.glassProminent)
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
        .contextMenu {
            if hasMinimizedComposer && clearDraftAction != nil {
                Button("Clear Draft", role: .destructive) {
                    clearDraftAction?()
                }
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
            }
        }
    }
    
}
