//
//  GlassEffectModifiers.swift
//  Catbird
//
//  Created by Claude Code on 8/13/25.
//

import SwiftUI

// Available on all iOS versions for testing glass effects
public struct GlassEffectPreviewContainer<Content: View>: View {
    private let content: Content
    
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [.blue.opacity(0.3), .purple.opacity(0.3), .pink.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(0..<10, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.regularMaterial)
                            .frame(height: 100)
                            .overlay {
                                Text("Background Content")
                                    .font(.headline)
                            }
                    }
                }
                .padding()
            }
            
            content
        }
    }
}
