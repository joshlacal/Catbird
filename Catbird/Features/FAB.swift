//
//  FAB.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/16/24.
//


// FAB.swift - Updated with better positioning
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
            .padding(.bottom, 16) // Add padding to lift above tab bar
            .safeAreaInset(edge: .bottom) { // Add this
                Color.clear.frame(height: 0)
            }

        }
    }
    
    private var feedsButton: some View {
        Button(action: feedsAction) {
            fabButtonContent("square.grid.3x3.square", color: .primary, backgroundColor: colorScheme == .dark ? Color(.systemGray6) : .white)
        }
    }
    
    private var composeButton: some View {
        Button(action: composeAction) {
            fabButtonContent("pencil", color: colorScheme == .dark ? .black : .white, backgroundColor: .accentColor)
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
                backgroundColor
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)
            )
            .contentShape(Circle())
    }
}
