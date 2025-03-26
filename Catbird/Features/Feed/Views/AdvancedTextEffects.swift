//
//  AdvancedTextEffects.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI

struct AdvancedTextEffects: View {
    @State private var animateWave = false
    @State private var showScaledText = false
    @State private var animateBlur = false
    @State private var colorCycle = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                // 1. Animated Wave Text
                waveText("WAVE ANIMATION")
                    .onTapGesture {
                        animateWave.toggle()
                    }
                
                // 2. Animated Opacity Reveal
                textReveal("Fade In Characters One By One", delay: 0.05)
                
                // 3. 3D Rotated Text
                Text("3D PERSPECTIVE")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .rotation3DEffect(
                        .degrees(showScaledText ? 0 : 15),
                        axis: (x: 1.0, y: 0.0, z: 0.0),
                        anchor: .center,
                        anchorZ: 0.0,
                        perspective: 1.0
                    )
                    .onTapGesture {
                        withAnimation(.spring()) {
                            showScaledText.toggle()
                        }
                    }
                
                // 4. Outlined Text
                Text("OUTLINED TEXT")
                    .font(.system(size: 36, weight: .black))
                    .foregroundColor(.clear)
                    .overlay(
                        Text("OUTLINED TEXT")
                            .font(.system(size: 36, weight: .black))
                            .foregroundColor(colorCycle ? .blue : .purple)
                            .opacity(0.8)
                    )
                    .background(
                        Text("OUTLINED TEXT")
                            .font(.system(size: 36, weight: .black))
                            .foregroundColor(.primary)
                            .offset(x: 2, y: 2)
                            .opacity(0.3)
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            colorCycle = true
                        }
                    }
                
                // 5. Dynamic Blur Text
                Text("Blurred Text")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.primary.opacity(0.8))
                    .blur(radius: animateBlur ? 0 : 5)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: animateBlur)
                    .onAppear {
                        animateBlur = true
                    }
                
                // 6. Masked Text with Image
                Text("IMAGE MASKED TEXT")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue, .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                // 7. Character by Character Highlight
                characterHighlight(text: "Tap to highlight each character", highlightColor: .blue)
                    .padding(.horizontal)
                
                // 8. Variable Font Weight Animation
                variableWeightText("VARIABLE WEIGHT")
                    .padding(.bottom, 20)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
    }
    
    // MARK: - Custom Text Effects
    
    @ViewBuilder
    private func waveText(_ text: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(.largeTitle, design: .rounded, weight: .black))
                    .foregroundColor(.primary)
                    .offset(y: animateWave ? -10 : 10)
                    .animation(
                        Animation.easeInOut(duration: 1)
                            .repeatForever()
                            .delay(Double(index) * 0.1),
                        value: animateWave
                    )
            }
        }
        .onAppear {
            animateWave = true
        }
    }
    
    @ViewBuilder
    private func textReveal(_ text: String, delay: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(.title2, design: .serif, weight: .medium))
                    .foregroundColor(.primary)
                    .opacity(showScaledText ? 1 : 0)
                    .animation(
                        Animation.easeIn(duration: 0.5).delay(Double(index) * delay),
                        value: showScaledText
                    )
            }
        }
        .onAppear {
            showScaledText = true
        }
    }
    
    @ViewBuilder
    private func variableWeightText(_ text: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(
                        size: 32,
                        weight: showScaledText ? .black : .ultraLight,
                        design: .default
                    ))
                    .animation(
                        Animation.easeInOut(duration: 2)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: showScaledText
                    )
            }
        }
        .onAppear {
            showScaledText = true
        }
    }
    
    @ViewBuilder
    private func characterHighlight(text: String, highlightColor: Color) -> some View {
        Text(text)
            .font(.system(.title3, design: .rounded, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .onTapGesture {
                highlightCharactersSequentially(text: text, color: highlightColor)
            }
    }
    
    private func highlightCharactersSequentially(text: String, color: Color) {
        // This would need custom implementation with UIViewRepresentable for actual use
        // In a real implementation, you would create a UILabel and use NSAttributedString
        // to animate the foreground color of each character
    }
}

// MARK: - Custom Animated Text View using UIKit

struct AnimatedLabelView: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor
    let animationStyle: AnimationStyle
    
    enum AnimationStyle {
        case typewriter, fadeIn, highlight
    }
    
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
    
    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.text = ""
        
        switch animationStyle {
        case .typewriter:
            animateTypewriter(label: uiView)
        case .fadeIn:
            animateFadeIn(label: uiView)
        case .highlight:
            animateHighlight(label: uiView)
        }
    }
    
    private func animateTypewriter(label: UILabel) {
        var charIndex = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if charIndex < text.count {
                let index = text.index(text.startIndex, offsetBy: charIndex)
                label.text = String(text[...index])
                charIndex += 1
            } else {
                timer.invalidate()
            }
        }
        timer.fire()
    }
    
    private func animateFadeIn(label: UILabel) {
        label.text = text
        label.alpha = 0
        
        UIView.animate(withDuration: 1.0) {
            label.alpha = 1
        }
    }
    
    private func animateHighlight(label: UILabel) {
        // This would use NSAttributedString with animated attributes
        // Simplified version just sets the text
        label.text = text
    }
}

// MARK: - Preview

#Preview {
    AdvancedTextEffects()
}
