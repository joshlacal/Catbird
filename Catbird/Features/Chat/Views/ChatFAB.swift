//
//  ChatFAB.swift
//  Catbird
//
//  Created by Claude on 5/10/25.
//

import SwiftUI

#if os(iOS)

struct ChatFAB: View {
    let newMessageAction: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    private let circleSize: CGFloat = 60
    
    var body: some View {
        Button(action: newMessageAction) {
            Circle()
                .fill(.blue.gradient)
                .frame(width: circleSize, height: circleSize)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.white)
                        .frame(width: circleSize, height: circleSize)
                        .contentShape(Circle())
                }
        }
    }
    
}

#endif