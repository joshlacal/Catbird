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
            .adaptiveGlassContainer(spacing: 12) {
                HStack {
                    if showFeedsButton {
                        feedsButton
                            .adaptiveGlassEffect(
                                style: .tinted(.secondary),
                                in: Circle(),
                                interactive: true
                            )
                            .catbirdGlassMorphing(id: "feeds", namespace: glassNamespace)
                    }
                    Spacer()
                    composeButton
                        .adaptiveGlassEffect(
                            style: .tinted(.accentColor), 
                            in: Circle(),
                            interactive: true
                        )
                        .catbirdGlassMorphing(id: "compose", namespace: glassNamespace)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 0)
            }
        }
    }
    
    private var feedsButton: some View {
        Button(action: feedsAction) {
            Image(systemName: "square.grid.3x3.square")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
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
                .frame(width: 24, height: 24)
                .foregroundStyle(.white)
                .frame(width: circleSize, height: circleSize)
                .background(.blue, in: Circle()) // Ensure visibility
                .contentShape(Circle())
        }
    }
    
}
