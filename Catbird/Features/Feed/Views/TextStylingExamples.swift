//
//  TextStylingExamples.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI

/// A collection of advanced text styling examples for reference
struct TextStylingExamples: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animateText = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                basicTypographySection
                advancedTypographySection  
                interactiveTypographySection
                
                // Section: Custom Text Modifiers
                sectionHeader("Custom Text Modifiers")
                Group {
                    // Headline style
                    Text("Custom Headline Style")
                        .headlineStyle(size: 24, weight: .bold, color: .primary)
                    
                    // Body text style
                    Text("Custom body text style with optimized line height and proper text sizing for maximum readability across different devices and screen sizes.")
                        .bodyStyle(size: Typography.Size.body, weight: .regular, lineHeight: Typography.LineHeight.relaxed)
                    
                    // Caption style
                    Text("Custom Caption Style")
                        .captionStyle(color: .secondary)
                }
                .padding(.horizontal)
                
                // Section: Font OpenType Features
                sectionHeader("OpenType Features (iOS 18+)")
                Group {
                    // Note: Some of these features require custom font implementation
                    Text("Stylistic Alternates")
                        .appFont(size: 20, weight: .medium)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    
                    Text("Oldstyle Numerals: 1234567890")
                        .appFont(size: 18, weight: .regular)
                    
                    Text("Fractions: 1/2 3/4 7/8")
                        .appFont(size: 18, weight: .regular)
                }
                .padding(.horizontal)
                
                // Section: Accessibility Typography
                sectionHeader("Accessibility Typography")
                Group {
                    Text("Dynamic Type Support")
                        .customScaledFont(relativeTo: .headline)
                    
                    Text("High Legibility Weight")
                        .appFont(size: 18, weight: .regular)
                        .environment(\.legibilityWeight, .bold)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("Typography Examples")
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - Section Views
    
    @ViewBuilder
    private var basicTypographySection: some View {
        sectionHeader("Basic Typography")
        Group {
            // SF Pro Text styles for smaller sizes
            Text("SF Pro Text")
                .appFont(Font.sfProText(size: 17, weight: .medium))
            
            // SF Pro Display for headlines
            Text("SF Pro Display Headline")
                .appFont(Font.sfProDisplay(size: 28, weight: .bold))
            
            // SF Pro Rounded
            Text("SF Pro Rounded")
                .appFont(Font.sfProRounded(size: 17, weight: .medium))
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var advancedTypographySection: some View {
        sectionHeader("Advanced Typography")
        Group {
            // Gradient Text
            Text("Gradient Text Effect")
                .appFont(size: 26, weight: .bold)
                .gradientText(colors: [.blue, .purple, .pink])
            
            // Text with 3D effect
            Text("3D Depth Effect")
                .appFont(size: 24, weight: .black)
                .textDepth(radius: 0.8, y: 1.0, opacity: 0.5)
            
            // Text with glow effect
            Text("Glow Effect")
                .appFont(size: 22, weight: .bold)
                .textGlow(color: .blue.opacity(0.7), radius: 5)
            
            // Variable width text
            Text("Variable Width Typography")
                .customScaledFont(size: 20, weight: .bold, width: 62)
            
            // Custom letter spacing
            Text("EXPANDED LETTER SPACING")
                .appFont(size: 16, weight: .medium)
                .tracking(0.8)
                .textCase(.uppercase)
            
            // Condensed letter spacing
            Text("Condensed spacing")
                .appFont(size: 18, weight: .semibold)
                .tracking(-0.5)
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var interactiveTypographySection: some View {
        sectionHeader("Interactive Typography")
        Group {
            // Animated text scale
            Text("Tap to Animate")
                .appFont(size: animateText ? 22 : 18, weight: .bold)
                .foregroundColor(animateText ? .blue : .primary)
                .scaleEffect(animateText ? 1.1 : 1.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: animateText)
                .onTapGesture {
                    animateText.toggle()
                }
            
            // Text with multiple styles inline
            Text("Mix ") + 
            Text("and ").italic() + 
            Text("match ").bold() + 
            Text("styles").foregroundColor(.blue)
            
            // Text with background highlight
            Text("Highlighted Important Text")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.yellow.opacity(0.3))
                )
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .customScaledFont(size: Typography.Size.title3, weight: .bold)
            .padding(.vertical, 10)
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
    }
}

// MARK: - Advanced Text Effects

struct AnimatedLettersView: View {
    let text: String
    @State private var animatingIndices = Set<Int>()
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .appFont(size: 24, weight: .bold)
                    .foregroundColor(animatingIndices.contains(index) ? .blue : .primary)
                    .scaleEffect(animatingIndices.contains(index) ? 1.5 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: animatingIndices.contains(index))
            }
        }
        .onAppear {
            animateSequentially()
        }
    }
    
    private func animateSequentially() {
        for index in 0..<text.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                animatingIndices.insert(index)
                
                // Remove after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    animatingIndices.remove(index)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TextStylingExamples()
    }
}
