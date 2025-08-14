//
//  ChatFAB.swift
//  Catbird
//
//  Created by Claude on 5/10/25.
//

import SwiftUI

struct ChatFAB: View {
    let newMessageAction: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    private let circleSize: CGFloat = 60
    
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                newMessageButton
                    .adaptiveGlassEffect(style: .accentTinted, in: Circle(), interactive: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 0)
            }
        }
    }
    
    private var newMessageButton: some View {
        Button(action: newMessageAction) {
            Image(systemName: "plus")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(.white)
                .frame(width: circleSize, height: circleSize)
                .contentShape(Circle())
        }
    }
    
}
