//
//  AdvancedTextEffects.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AdvancedTextEffects: View {
    @State private var animateWave = false
    @State private var showScaledText = false
    @State private var animateBlur = false
    @State private var colorCycle = false
    
    private var backgroundColor: Color {
        #if os(iOS)
        return Color(platformColor: PlatformColor.platformSystemBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
    
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
                    .appFont(size: 32, weight: .black)
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
                    .appFont(size: 36, weight: .black)
                    .foregroundColor(.clear)
                    .overlay(
                        Text("OUTLINED TEXT")
                            .appFont(size: 36, weight: .black)
                            .foregroundColor(colorCycle ? .blue : .purple)
                            .opacity(0.8)
                    )
                    .background(
                        Text("OUTLINED TEXT")
                            .appFont(size: 36, weight: .black)
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
                    .appFont(size: 32, weight: .bold)
                    .foregroundColor(.primary.opacity(0.8))
                    .blur(radius: animateBlur ? 0 : 5)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: animateBlur)
                    .onAppear {
                        animateBlur = true
                    }
                
                // 6. Masked Text with Image
                Text("IMAGE MASKED TEXT")
                    .appFont(size: 38, weight: .bold)
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
                
                // 9. Cross-Platform Animated Text
                VStack(spacing: 16) {
                    Text("Cross-Platform Animations")
                        .appFont(AppTextRole.from(.title2))
                        .foregroundColor(.primary)
                    
                    CrossPlatformAnimatedText(
                        text: "Typewriter Effect",
                        animationStyle: .typewriter,
                        size: 18
                    )
                    .frame(height: 30)
                    
                    CrossPlatformAnimatedText(
                        text: "Fade In Effect",
                        animationStyle: .fadeIn,
                        size: 18
                    )
                    .frame(height: 30)
                    
                    CrossPlatformAnimatedText(
                        text: "Highlight Effect",
                        animationStyle: .highlight,
                        size: 18
                    )
                    .frame(height: 30)
                }
                .padding()
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(backgroundColor)
    }
    
    // MARK: - Custom Text Effects
    
    @ViewBuilder
    private func waveText(_ text: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .appFont(AppTextRole.from(.largeTitle))
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
                    .appFont(AppTextRole.from(.title2))
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
                    .appFont(
                        size: 32,
                        weight: showScaledText ? .black : .ultraLight
                    )
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
            .appFont(AppTextRole.from(.title3))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .onTapGesture {
                highlightCharactersSequentially(text: text, color: highlightColor)
            }
    }
    
    private func highlightCharactersSequentially(text: String, color: Color) {
        // Character highlighting animation - platform-specific implementation handled in AnimatedLabelView
        withAnimation(.easeInOut(duration: 1.0)) {
            colorCycle.toggle()
        }
    }
}

// MARK: - Animation Style Definition

enum AnimationStyle {
    case typewriter, fadeIn, highlight
}

// MARK: - Custom Animated Text View

#if os(iOS)
struct AnimatedLabelView: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor
    let animationStyle: AnimationStyle
    
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

#elseif os(macOS)

struct AnimatedLabelView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    let animationStyle: AnimationStyle
    
    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.font = font
        textField.textColor = color
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBezeled = false
        textField.backgroundColor = .clear
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        return textField
    }
    
    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = ""
        
        switch animationStyle {
        case .typewriter:
            animateTypewriter(textField: nsView)
        case .fadeIn:
            animateFadeIn(textField: nsView)
        case .highlight:
            animateHighlight(textField: nsView)
        }
    }
    
    private func animateTypewriter(textField: NSTextField) {
        var charIndex = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if charIndex < text.count {
                let index = text.index(text.startIndex, offsetBy: charIndex)
                textField.stringValue = String(text[...index])
                charIndex += 1
            } else {
                timer.invalidate()
            }
        }
        timer.fire()
    }
    
    private func animateFadeIn(textField: NSTextField) {
        textField.stringValue = text
        textField.alphaValue = 0
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.0
            textField.animator().alphaValue = 1.0
        }
    }
    
    private func animateHighlight(textField: NSTextField) {
        // Simplified version just sets the text
        textField.stringValue = text
    }
}

#endif

// MARK: - Cross-Platform Animated Text Wrapper

struct CrossPlatformAnimatedText: View {
    let text: String
    let animationStyle: AnimationStyle
    let size: CGFloat
    
    var body: some View {
        #if os(iOS)
        AnimatedLabelView(
            text: text,
            font: UIFont.systemFont(ofSize: size, weight: UIFont.Weight.medium),
            color: UIColor.label,
            animationStyle: animationStyle
        )
        #elseif os(macOS)
        AnimatedLabelView(
            text: text,
            font: NSFont.systemFont(ofSize: size, weight: NSFont.Weight.medium),
            color: NSColor.labelColor,
            animationStyle: animationStyle
        )
        #endif
    }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
    AdvancedTextEffects()
}
