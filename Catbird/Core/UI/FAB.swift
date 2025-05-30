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

    private let circleSize: CGFloat = 60
    
    var body: some View {
        VStack {
            Spacer()
            HStack {
                if showFeedsButton {
                    feedsButton
                }
                Spacer()
                composeButton
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
            fabButtonContent(
                "square.grid.3x3.square", 
                color: .primary,
                backgroundColor: Color(UIColor.systemBackground)
            )
        }
    }
    
    private var composeButton: some View {
        Button(action: composeAction) {
            fabButtonContent(
                "pencil", 
                color: colorScheme == .dark ? .black : .white,
                backgroundColor: .accentColor
            )
        }
    }
    
    private func fabButtonContent(_ iconName: String, color: Color, backgroundColor: Color) -> some View {
        Image(systemName: iconName)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .foregroundStyle(color)
            .frame(width: circleSize, height: circleSize)
            .background(
                ZStack {
                    Circle()
                        .fill(backgroundColor)
                    
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.2),
                                    Color.clear,
                                    Color.black.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Circle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            )
            .contentShape(Circle())
    }
}
