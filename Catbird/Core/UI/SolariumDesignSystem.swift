//
//  SolariumDesignSystem.swift
//  Catbird
//
//  Created by Claude Code on 1/26/25.
//

import SwiftUI

// MARK: - Solarium Design System

/// Comprehensive glassmorphism design system inspired by iOS 19 Solarium
/// Provides consistent glass effects, depth, and premium visual hierarchy
struct SolariumDesignSystem {
    
    // MARK: - Glass Intensity Levels
    
    enum GlassIntensity: CaseIterable {
        case whisper      // Barely perceptible glass
        case subtle       // Gentle glass effect  
        case medium       // Standard glass treatment
        case strong       // Bold glass presence
        case dramatic     // Maximum glass impact
        
        var material: Material {
            switch self {
            case .whisper: return .ultraThinMaterial
            case .subtle: return .ultraThinMaterial
            case .medium: return .thinMaterial
            case .strong: return .regularMaterial
            case .dramatic: return .thickMaterial
            }
        }
        
        var backgroundOpacity: Double {
            switch self {
            case .whisper: return 0.05
            case .subtle: return 0.1
            case .medium: return 0.15
            case .strong: return 0.25
            case .dramatic: return 0.4
            }
        }
        
        var borderOpacity: Double {
            switch self {
            case .whisper: return 0.1
            case .subtle: return 0.2
            case .medium: return 0.3
            case .strong: return 0.4
            case .dramatic: return 0.6
            }
        }
        
        var shadowRadius: CGFloat {
            switch self {
            case .whisper: return 2
            case .subtle: return 5
            case .medium: return 10
            case .strong: return 15
            case .dramatic: return 25
            }
        }
    }
    
    // MARK: - Glass Styles
    
    enum GlassStyle {
        case card           // Content cards with subtle depth
        case button         // Interactive elements
        case overlay        // Floating panels and modals
        case navigation     // Top bars and navigation chrome
        case floating       // FABs and prominent interactive elements
        case sheet          // Bottom sheets and full overlays
        
        var defaultIntensity: GlassIntensity {
            switch self {
            case .card: return .subtle
            case .button: return .medium
            case .overlay: return .strong
            case .navigation: return .medium
            case .floating: return .dramatic
            case .sheet: return .strong
            }
        }
        
        var cornerRadius: CGFloat {
            switch self {
            case .card: return 16
            case .button: return 12
            case .overlay: return 20
            case .navigation: return 0
            case .floating: return 30
            case .sheet: return 24
            }
        }
    }
    
    // MARK: - Depth Levels
    
    enum DepthLevel {
        case surface        // Base level, minimal elevation
        case raised         // Slightly elevated 
        case floating       // Clearly above surface
        case modal          // High elevation for important content
        case alert          // Maximum elevation for critical content
        
        var shadowOffsetY: CGFloat {
            switch self {
            case .surface: return 1
            case .raised: return 3
            case .floating: return 8
            case .modal: return 15
            case .alert: return 25
            }
        }
        
        var shadowBlur: CGFloat {
            switch self {
            case .surface: return 2
            case .raised: return 6
            case .floating: return 12
            case .modal: return 20
            case .alert: return 30
            }
        }
        
        var shadowOpacity: Double {
            switch self {
            case .surface: return 0.1
            case .raised: return 0.15
            case .floating: return 0.2
            case .modal: return 0.3
            case .alert: return 0.4
            }
        }
    }
    
    // MARK: - Glass Colors
    
    struct GlassColors {
        static func borderGradient(intensity: GlassIntensity, colorScheme: ColorScheme) -> LinearGradient {
            let baseOpacity = intensity.borderOpacity
            let lightOpacity = colorScheme == .dark ? baseOpacity * 0.8 : baseOpacity * 1.2
            
            return LinearGradient(
                colors: [
                    Color.white.opacity(lightOpacity),
                    Color.white.opacity(baseOpacity * 0.3),
                    Color.clear,
                    Color.black.opacity(baseOpacity * 0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        
        static func backgroundGradient(intensity: GlassIntensity, colorScheme: ColorScheme) -> LinearGradient {
            let baseOpacity = intensity.backgroundOpacity
            
            if colorScheme == .dark {
                return LinearGradient(
                    colors: [
                        Color.white.opacity(baseOpacity * 0.15),
                        Color.white.opacity(baseOpacity * 0.05),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                return LinearGradient(
                    colors: [
                        Color.white.opacity(baseOpacity * 0.8),
                        Color.white.opacity(baseOpacity * 0.3),
                        Color.white.opacity(baseOpacity * 0.1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        
        static func innerShadowGradient(colorScheme: ColorScheme) -> LinearGradient {
            if colorScheme == .dark {
                return LinearGradient(
                    colors: [
                        Color.black.opacity(0.3),
                        Color.clear,
                        Color.white.opacity(0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                return LinearGradient(
                    colors: [
                        Color.black.opacity(0.15),
                        Color.clear,
                        Color.white.opacity(0.3)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

// MARK: - Glass Modifiers

extension View {
    
    /// Applies sophisticated glassmorphism effects with customizable intensity
    func solariumGlass(
        style: SolariumDesignSystem.GlassStyle,
        intensity: SolariumDesignSystem.GlassIntensity? = nil,
        depth: SolariumDesignSystem.DepthLevel = .raised
    ) -> some View {
        self.modifier(
            SolariumGlassModifier(
                style: style,
                intensity: intensity ?? style.defaultIntensity,
                depth: depth
            )
        )
    }
    
    /// Applies premium glass card treatment (most common use case)
    func solariumCard(
        intensity: SolariumDesignSystem.GlassIntensity = .subtle
    ) -> some View {
        self.solariumGlass(style: .card, intensity: intensity, depth: .raised)
    }
    
    /// Applies floating glass button treatment
    func solariumButton(
        intensity: SolariumDesignSystem.GlassIntensity = .medium
    ) -> some View {
        self.solariumGlass(style: .button, intensity: intensity, depth: .floating)
    }
    
    /// Applies overlay glass treatment for modals and sheets
    func solariumOverlay(
        intensity: SolariumDesignSystem.GlassIntensity = .strong
    ) -> some View {
        self.solariumGlass(style: .overlay, intensity: intensity, depth: .modal)
    }
    
    /// Applies navigation glass treatment
    func solariumNavigation(
        intensity: SolariumDesignSystem.GlassIntensity = .medium
    ) -> some View {
        self.solariumGlass(style: .navigation, intensity: intensity, depth: .raised)
    }
    
    /// Applies dramatic floating glass treatment (for FABs)
    func solariumFloating(
        intensity: SolariumDesignSystem.GlassIntensity = .dramatic
    ) -> some View {
        self.solariumGlass(style: .floating, intensity: intensity, depth: .floating)
    }
    
    /// Applies enhanced typography for glass backgrounds
    func solariumText(
        intensity: SolariumDesignSystem.GlassIntensity = .medium,
        enhanceContrast: Bool = true
    ) -> some View {
        self.modifier(SolariumTextModifier(intensity: intensity, enhanceContrast: enhanceContrast))
    }
}

// MARK: - Core Glass Modifier

struct SolariumGlassModifier: ViewModifier {
    let style: SolariumDesignSystem.GlassStyle
    let intensity: SolariumDesignSystem.GlassIntensity
    let depth: SolariumDesignSystem.DepthLevel
    
    @Environment(\.colorScheme) private var colorScheme
    
    func body(content: Content) -> some View {
        content
            .background(glassBackground)
            .overlay(borderOverlay)
            .shadow(
                color: .black.opacity(depth.shadowOpacity),
                radius: depth.shadowBlur,
                x: 0,
                y: depth.shadowOffsetY
            )
            .shadow(
                color: colorScheme == .dark ? 
                    .white.opacity(0.05) : .white.opacity(0.3),
                radius: depth.shadowBlur * 0.5,
                x: 0,
                y: -depth.shadowOffsetY * 0.3
            )
    }
    
    private var glassBackground: some View {
        ZStack {
            // Base material
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(intensity.material)
            
            // Enhanced gradient overlay
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(SolariumDesignSystem.GlassColors.backgroundGradient(
                    intensity: intensity,
                    colorScheme: colorScheme
                ))
            
            // Inner shadow for depth
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .stroke(
                    SolariumDesignSystem.GlassColors.innerShadowGradient(
                        colorScheme: colorScheme
                    ),
                    lineWidth: 1
                )
                .blur(radius: 1)
        }
    }
    
    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: style.cornerRadius)
            .stroke(
                SolariumDesignSystem.GlassColors.borderGradient(
                    intensity: intensity,
                    colorScheme: colorScheme
                ),
                lineWidth: intensity == .dramatic ? 1.5 : 0.8
            )
    }
}

// MARK: - Typography Enhancement for Glass

struct SolariumTextModifier: ViewModifier {
    let intensity: SolariumDesignSystem.GlassIntensity
    let enhanceContrast: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    
    func body(content: Content) -> some View {
        content
            .fontWeight(enhancedWeight)
            .foregroundStyle(enhancedColor)
            .shadow(
                color: textShadowColor,
                radius: textShadowRadius,
                x: 0,
                y: textShadowOffset
            )
    }
    
    private var enhancedWeight: Font.Weight {
        guard enhanceContrast else { return .regular }
        
        switch intensity {
        case .whisper, .subtle: return .medium
        case .medium: return .semibold
        case .strong, .dramatic: return .bold
        }
    }
    
    private var enhancedColor: Color {
        guard enhanceContrast else { return .primary }
        
        switch intensity {
        case .whisper, .subtle: return .primary
        case .medium: return colorScheme == .dark ? .white : .black
        case .strong, .dramatic: return colorScheme == .dark ? .white : .black
        }
    }
    
    private var textShadowColor: Color {
        guard enhanceContrast else { return .clear }
        
        if colorScheme == .dark {
            return .black.opacity(0.8)
        } else {
            return .white.opacity(0.8)
        }
    }
    
    private var textShadowRadius: CGFloat {
        guard enhanceContrast else { return 0 }
        return intensity.shadowRadius * 0.1
    }
    
    private var textShadowOffset: CGFloat {
        guard enhanceContrast else { return 0 }
        return intensity == .dramatic ? 1 : 0.5
    }
}

// MARK: - Animated Glass Effects

extension View {
    
    /// Adds interactive glass effects that respond to user interaction
    func interactiveGlass(
        pressedIntensity: SolariumDesignSystem.GlassIntensity? = nil
    ) -> some View {
        self.modifier(InteractiveGlassModifier(pressedIntensity: pressedIntensity))
    }
    
    /// Adds subtle shimmer effect for premium feel
    func solariumShimmer(
        intensity: Double = 0.3,
        angle: Double = 45
    ) -> some View {
        self.modifier(SolariumShimmerModifier(intensity: intensity, angle: angle))
    }
}

struct InteractiveGlassModifier: ViewModifier {
    let pressedIntensity: SolariumDesignSystem.GlassIntensity?
    @State private var isPressed = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .opacity(isPressed ? 0.95 : 1.0)
            .animation(.spring(duration: 0.15), value: isPressed)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) { pressing in
                isPressed = pressing
            } perform: { }
    }
}

struct SolariumShimmerModifier: ViewModifier {
    let intensity: Double
    let angle: Double
    @State private var shimmerOffset: CGFloat = -1
    
    func body(content: Content) -> some View {
        content
            .overlay(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(intensity),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .rotationEffect(.degrees(angle))
                    .offset(x: shimmerOffset * PlatformScreenInfo.width)
                    .animation(
                        .easeInOut(duration: 2)
                        .repeatForever(autoreverses: false),
                        value: shimmerOffset
                    )
                    .onAppear {
                        shimmerOffset = 1
                    }
                    .allowsHitTesting(false)
            )
            .clipped()
    }
}

// MARK: - Preview Support

#Preview("Solarium Design System Showcase") {
    ScrollView {
        VStack(spacing: 24) {
            // Glass intensity demonstration
            VStack(spacing: 16) {
                Text("Glass Intensity Levels")
                    .appFont(AppTextRole.headline)
                    .solariumText(intensity: .medium)
                
                ForEach(SolariumDesignSystem.GlassIntensity.allCases, id: \.self) { intensity in
                    Text("\(String(describing: intensity).capitalized) Glass")
                                            .appFont(AppTextRole.body)
                        .solariumText(intensity: intensity)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .solariumGlass(style: .card, intensity: intensity)
                }
            }
            .padding()
            
            // Interactive buttons
            VStack(spacing: 16) {
                Text("Interactive Elements")
                    .appFont(AppTextRole.headline)
                    .solariumText(intensity: .medium)
                
                Button("Primary Glass Button") {
                    // Action
                }
                .buttonStyle(.plain)
                .padding()
                .solariumButton()
                .interactiveGlass()
                
                Button("Floating Action") {
                    // Action
                }
                .buttonStyle(.plain)
                .padding()
                .solariumFloating()
                .interactiveGlass()
                .solariumShimmer()
            }
            .padding()
        }
    }
    .background(
        LinearGradient(
            colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    )
}
