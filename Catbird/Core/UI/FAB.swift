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
    @Environment(\.colorScheme) var colorScheme
    @Namespace private var glassNamespace

    private let circleSize: CGFloat = 60
    
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                if showFeedsButton {
                    if #available(macOS 26.0, *) {
                        feedsButton
                            .adaptiveGlassEffect(in: Circle())
                    } else {
                        feedsButton
                    }
                }
                Spacer()
                if #available(macOS 26.0, *) {
                    
                    composeButton
                        .adaptiveGlassEffect(style: .accentTinted, in: Circle(), interactive: true)
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
    
    private var feedsButton: some View {
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
    
    private var composeButton: some View {
        Button(action: composeAction) {
            Image(systemName: "pencil")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(.white)
                .frame(width: circleSize, height: circleSize)
                .background(.blue, in: Circle()) // Ensure visibility
                .contentShape(Circle())
        }
    }
    
}
