//
//  DesignTokens.swift
//  Catbird
//
//  Created by Claude Code on 1/26/25.
//

import SwiftUI

// MARK: - Design Tokens

/// Comprehensive design token system enforcing 3pt grid consistency
/// Use these tokens for all spacing, sizing, and typography throughout the app
struct DesignTokens {
    
    // MARK: - Base Unit
    
    /// Base 3pt unit - all spacing should be multiples of this
    static let baseUnit: CGFloat = 3
    
    // MARK: - Spacing Scale (3pt Grid)
    
    enum Spacing {
        /// 0pt - No spacing
        static let none: CGFloat = 0
        
        /// 3pt - Minimal spacing (1 unit)
        static let xs: CGFloat = baseUnit * 1  // 3pt
        
        /// 6pt - Small spacing (2 units)
        static let sm: CGFloat = baseUnit * 2  // 6pt
        
        /// 9pt - Medium-small spacing (3 units)
        static let md: CGFloat = baseUnit * 3  // 9pt
        
        /// 12pt - Default spacing (4 units)
        static let base: CGFloat = baseUnit * 4  // 12pt
        
        /// 15pt - Medium-large spacing (5 units)
        static let lg: CGFloat = baseUnit * 5  // 15pt
        
        /// 18pt - Large spacing (6 units)
        static let xl: CGFloat = baseUnit * 6  // 18pt
        
        /// 21pt - Extra large spacing (7 units)
        static let xxl: CGFloat = baseUnit * 7  // 21pt
        
        /// 24pt - Section spacing (8 units)
        static let section: CGFloat = baseUnit * 8  // 24pt
        
        /// 30pt - Large section spacing (10 units)
        static let sectionLarge: CGFloat = baseUnit * 10  // 30pt
        
        /// 36pt - Page spacing (12 units)
        static let page: CGFloat = baseUnit * 12  // 36pt
        
        /// 48pt - Large page spacing (16 units)
        static let pageLarge: CGFloat = baseUnit * 16  // 48pt
        
        /// Get spacing value for a specific multiplier
        static func custom(_ multiplier: CGFloat) -> CGFloat {
            return baseUnit * multiplier
        }
    }
    
    // MARK: - Component Sizes (3pt Grid)
    
    enum Size {
        // Avatar sizes
        static let avatarXS: CGFloat = baseUnit * 8   // 24pt
        static let avatarSM: CGFloat = baseUnit * 10  // 30pt
        static let avatarMD: CGFloat = baseUnit * 12  // 36pt
        static let avatarLG: CGFloat = baseUnit * 16  // 48pt
        static let avatarXL: CGFloat = baseUnit * 20  // 60pt
        static let avatarXXL: CGFloat = baseUnit * 32 // 96pt
        
        // Button heights
        static let buttonSM: CGFloat = baseUnit * 10  // 30pt
        static let buttonMD: CGFloat = baseUnit * 12  // 36pt
        static let buttonLG: CGFloat = baseUnit * 14  // 42pt
        static let buttonXL: CGFloat = baseUnit * 16  // 48pt
        
        // Icon sizes
        static let iconXS: CGFloat = baseUnit * 4   // 12pt
        static let iconSM: CGFloat = baseUnit * 5   // 15pt
        static let iconMD: CGFloat = baseUnit * 6   // 18pt
        static let iconLG: CGFloat = baseUnit * 8   // 24pt
        static let iconXL: CGFloat = baseUnit * 10  // 30pt
        
        // Corner radius
        static let radiusXS: CGFloat = baseUnit * 1   // 3pt
        static let radiusSM: CGFloat = baseUnit * 2   // 6pt
        static let radiusMD: CGFloat = baseUnit * 3   // 9pt
        static let radiusLG: CGFloat = baseUnit * 4   // 12pt
        static let radiusXL: CGFloat = baseUnit * 5   // 15pt
        static let radiusXXL: CGFloat = baseUnit * 6  // 18pt
        
        // Border widths
        static let borderThin: CGFloat = 0.5
        static let borderDefault: CGFloat = 1.0
        static let borderThick: CGFloat = 1.5
        static let borderBold: CGFloat = 2.0
    }
    
    // MARK: - Typography Scale
    
    enum FontSize {
        /// 10pt - Micro text
        static let micro: CGFloat = 10
        
        /// 11pt - Tiny text
        static let tiny: CGFloat = 11
        
        /// 12pt - Caption text
        static let caption: CGFloat = 12
        
        /// 13pt - Footnote text
        static let footnote: CGFloat = 13
        
        /// 14pt - Small body text
        static let small: CGFloat = 14
        
        /// 15pt - Subheadline text
        static let subheadline: CGFloat = 15
        
        /// 16pt - Callout text
        static let callout: CGFloat = 16
        
        /// 17pt - Body text (base)
        static let body: CGFloat = 17
        
        /// 18pt - Large body text
        static let bodyLarge: CGFloat = 18
        
        /// 20pt - Title 3
        static let title3: CGFloat = 20
        
        /// 22pt - Title 2
        static let title2: CGFloat = 22
        
        /// 24pt - Headline
        static let headline: CGFloat = 24
        
        /// 28pt - Title 1
        static let title1: CGFloat = 28
        
        /// 32pt - Large title
        static let largeTitle: CGFloat = 32
        
        /// 36pt - Display text
        static let display: CGFloat = 36
    }
    
    // MARK: - Line Heights
    
    enum LineHeight {
        /// 1.2 - Tight line height for headlines
        static let tight: CGFloat = 1.2
        
        /// 1.3 - Snug line height for subheadings
        static let snug: CGFloat = 1.3
        
        /// 1.4 - Normal line height for UI text
        static let normal: CGFloat = 1.4
        
        /// 1.5 - Relaxed line height for body text
        static let relaxed: CGFloat = 1.5
        
        /// 1.6 - Loose line height for reading
        static let loose: CGFloat = 1.6
    }
    
    // MARK: - Letter Spacing
    
    enum LetterSpacing {
        /// -0.5pt - Tighter letter spacing
        static let tighter: CGFloat = -0.5
        
        /// -0.25pt - Tight letter spacing
        static let tight: CGFloat = -0.25
        
        /// 0pt - Normal letter spacing
        static let normal: CGFloat = 0
        
        /// 0.25pt - Wide letter spacing
        static let wide: CGFloat = 0.25
        
        /// 0.5pt - Wider letter spacing
        static let wider: CGFloat = 0.5
        
        /// 0.75pt - Widest letter spacing
        static let widest: CGFloat = 0.75
    }
    
    // MARK: - Animation Durations
    
    enum Duration {
        /// 0.1s - Instant feedback
        static let instant: TimeInterval = 0.1
        
        /// 0.15s - Quick interactions
        static let quick: TimeInterval = 0.15
        
        /// 0.2s - Fast transitions
        static let fast: TimeInterval = 0.2
        
        /// 0.3s - Normal transitions
        static let normal: TimeInterval = 0.3
        
        /// 0.4s - Slow transitions
        static let slow: TimeInterval = 0.4
        
        /// 0.6s - Very slow transitions
        static let verySlow: TimeInterval = 0.6
    }
    
    // MARK: - Shadow System
    
    enum Shadow {
        static let subtle = (radius: CGFloat(1), y: CGFloat(1), opacity: 0.1)
        static let soft = (radius: CGFloat(2), y: CGFloat(2), opacity: 0.15)
        static let medium = (radius: CGFloat(4), y: CGFloat(4), opacity: 0.2)
        static let strong = (radius: CGFloat(8), y: CGFloat(8), opacity: 0.25)
        static let dramatic = (radius: CGFloat(16), y: CGFloat(16), opacity: 0.3)
    }
}

// MARK: - View Extensions for Design Tokens

extension View {
    
    // MARK: - Spacing Modifiers
    
    /// Apply 3pt-grid spacing
    func spacing(_ spacing: CGFloat) -> some View {
        self.padding(spacing)
    }
    
    /// Apply specific edge spacing using design tokens
    func spacing(_ edges: Edge.Set = .all, _ amount: CGFloat) -> some View {
        self.padding(edges, amount)
    }
    
    /// Quick spacing helpers
    func spacingXS(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, DesignTokens.Spacing.xs)
    }
    
    func spacingSM(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, DesignTokens.Spacing.sm)
    }
    
    func spacingMD(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, DesignTokens.Spacing.md)
    }
    
    func spacingBase(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, DesignTokens.Spacing.base)
    }
    
    func spacingLG(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, DesignTokens.Spacing.lg)
    }
    
    func spacingXL(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, DesignTokens.Spacing.xl)
    }
    
    func spacingXXL(_ edges: Edge.Set = .all) -> some View {
        self.padding(edges, DesignTokens.Spacing.xxl)
    }
    
    // MARK: - Size Modifiers
    
    /// Apply consistent corner radius
    func cornerRadius(_ radius: CGFloat) -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: radius))
    }
    
    /// Quick corner radius helpers
    func cornerRadiusXS() -> some View {
        self.cornerRadius(DesignTokens.Size.radiusXS)
    }
    
    func cornerRadiusSM() -> some View {
        self.cornerRadius(DesignTokens.Size.radiusSM)
    }
    
    func cornerRadiusMD() -> some View {
        self.cornerRadius(DesignTokens.Size.radiusMD)
    }
    
    func cornerRadiusLG() -> some View {
        self.cornerRadius(DesignTokens.Size.radiusLG)
    }
    
    func cornerRadiusXL() -> some View {
        self.cornerRadius(DesignTokens.Size.radiusXL)
    }
    
    // MARK: - Typography Modifiers
    
    /// Apply consistent font with proper line height
    func designFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        lineHeight: CGFloat = DesignTokens.LineHeight.normal,
        letterSpacing: CGFloat = DesignTokens.LetterSpacing.normal
    ) -> some View {
        self
            .font(.system(size: size, weight: weight))
            .lineSpacing((lineHeight - 1.0) * size)
            .tracking(letterSpacing)
    }
    
    /// Quick typography helpers
    func designTitle1() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.title1,
            weight: .bold,
            lineHeight: DesignTokens.LineHeight.tight,
            letterSpacing: DesignTokens.LetterSpacing.tight
        )
    }
    
    func designTitle2() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.title2,
            weight: .semibold,
            lineHeight: DesignTokens.LineHeight.snug,
            letterSpacing: DesignTokens.LetterSpacing.tight
        )
    }
    
    func designHeadline() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.headline,
            weight: .semibold,
            lineHeight: DesignTokens.LineHeight.snug
        )
    }
    
    func designBody() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.body,
            weight: .regular,
            lineHeight: DesignTokens.LineHeight.relaxed
        )
    }
    
    func designBodyLarge() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.bodyLarge,
            weight: .regular,
            lineHeight: DesignTokens.LineHeight.relaxed
        )
    }
    
    func designCallout() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.callout,
            weight: .medium,
            lineHeight: DesignTokens.LineHeight.normal
        )
    }
    
    func designCaption() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.caption,
            weight: .medium,
            lineHeight: DesignTokens.LineHeight.normal,
            letterSpacing: DesignTokens.LetterSpacing.wide
        )
    }
    
    func designFootnote() -> some View {
        self.designFont(
            size: DesignTokens.FontSize.footnote,
            weight: .regular,
            lineHeight: DesignTokens.LineHeight.normal
        )
    }
    
    // MARK: - Shadow Modifiers
    
    func designShadow(_ shadow: (radius: CGFloat, y: CGFloat, opacity: Double)) -> some View {
        self.shadow(
            color: .black.opacity(shadow.opacity),
            radius: shadow.radius,
            x: 0,
            y: shadow.y
        )
    }
    
    func shadowSubtle() -> some View {
        self.designShadow(DesignTokens.Shadow.subtle)
    }
    
    func shadowSoft() -> some View {
        self.designShadow(DesignTokens.Shadow.soft)
    }
    
    func shadowMedium() -> some View {
        self.designShadow(DesignTokens.Shadow.medium)
    }
    
    func shadowStrong() -> some View {
        self.designShadow(DesignTokens.Shadow.strong)
    }
}

// MARK: - VStack and HStack Extensions

extension VStack {
    /// Create VStack with design token spacing
    static func withSpacing(_ spacing: CGFloat, alignment: HorizontalAlignment = .center, @ViewBuilder content: () -> Content) -> VStack<Content> {
        VStack(alignment: alignment, spacing: spacing, content: content)
    }
}

extension HStack {
    /// Create HStack with design token spacing
    static func withSpacing(_ spacing: CGFloat, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) -> HStack<Content> {
        HStack(alignment: alignment, spacing: spacing, content: content)
    }
}

// MARK: - Preview

#Preview("Design Tokens Showcase") {
    ScrollView {
        VStack(spacing: DesignTokens.Spacing.section) {
            // Spacing examples
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
                Text("Spacing Scale (3pt Grid)")
                    .designHeadline()
                
                VStack(spacing: DesignTokens.Spacing.xs) {
                    HStack {
                        Text("XS (3pt)")
                            .designCaption()
                        Spacer()
                        Rectangle()
                            .fill(.blue)
                            .frame(width: DesignTokens.Spacing.xs, height: 20)
                    }
                    
                    HStack {
                        Text("Base (12pt)")
                            .designCaption()
                        Spacer()
                        Rectangle()
                            .fill(.blue)
                            .frame(width: DesignTokens.Spacing.base, height: 20)
                    }
                    
                    HStack {
                        Text("XL (18pt)")
                            .designCaption()
                        Spacer()
                        Rectangle()
                            .fill(.blue)
                            .frame(width: DesignTokens.Spacing.xl, height: 20)
                    }
                }
            }
            .spacingBase()
            .background(.gray.opacity(0.1))
            .cornerRadiusMD()
            
            // Typography examples
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
                Text("Typography Scale")
                    .designHeadline()
                
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("Title 1")
                        .designTitle1()
                    
                    Text("Title 2")
                        .designTitle2()
                    
                    Text("Headline")
                        .designHeadline()
                    
                    Text("Body text with proper line height and spacing for readability")
                        .designBody()
                    
                    Text("Callout text")
                        .designCallout()
                    
                    Text("Caption text")
                        .designCaption()
                }
            }
            .spacingBase()
            .background(.gray.opacity(0.1))
            .cornerRadiusMD()
            
            // Component examples
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
                Text("Component Examples")
                    .designHeadline()
                
                HStack(spacing: DesignTokens.Spacing.base) {
                    // Button examples
                    Button("Primary") {}
                        .buttonStyle(.borderedProminent)
                        .frame(height: DesignTokens.Size.buttonMD)
                    
                    Button("Secondary") {}
                        .buttonStyle(.bordered)
                        .frame(height: DesignTokens.Size.buttonMD)
                }
                
                // Avatar examples
                HStack(spacing: DesignTokens.Spacing.base) {
                    Circle()
                        .fill(.blue)
                        .frame(width: DesignTokens.Size.avatarSM, height: DesignTokens.Size.avatarSM)
                    
                    Circle()
                        .fill(.green)
                        .frame(width: DesignTokens.Size.avatarMD, height: DesignTokens.Size.avatarMD)
                    
                    Circle()
                        .fill(.orange)
                        .frame(width: DesignTokens.Size.avatarLG, height: DesignTokens.Size.avatarLG)
                }
            }
            .spacingBase()
            .background(.gray.opacity(0.1))
            .cornerRadiusMD()
        }
        .spacingBase()
    }
    .background(.gray.opacity(0.05))
}