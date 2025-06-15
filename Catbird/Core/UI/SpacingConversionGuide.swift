//
//  SpacingConversionGuide.swift
//  Catbird
//
//  Created by Claude Code on 1/26/25.
//

/*
# Spacing Conversion Guide

## Replace inconsistent spacing with design tokens:

### Common inconsistent values → Design tokens
```
.padding(2)     → .spacingXS()     // 3pt
.padding(4)     → .spacingSM()     // 6pt  
.padding(6)     → .spacingSM()     // 6pt
.padding(8)     → .spacingMD()     // 9pt
.padding(10)    → .spacingBase()   // 12pt
.padding(12)    → .spacingBase()   // 12pt
.padding(14)    → .spacingLG()     // 15pt
.padding(15)    → .spacingLG()     // 15pt
.padding(16)    → .spacingXL()     // 18pt
.padding(18)    → .spacingXL()     // 18pt
.padding(20)    → .spacingXXL()    // 21pt
.padding(24)    → .spacing(.section, DesignTokens.Spacing.section) // 24pt
```

### Stack spacing
```
VStack(spacing: 8)  → VStack(spacing: DesignTokens.Spacing.md)
VStack(spacing: 12) → VStack(spacing: DesignTokens.Spacing.base)  
VStack(spacing: 16) → VStack(spacing: DesignTokens.Spacing.xl)
HStack(spacing: 10) → HStack(spacing: DesignTokens.Spacing.base)
```

### Component sizes
```
.frame(width: 48, height: 48)     → .frame(width: DesignTokens.Size.avatarLG, height: DesignTokens.Size.avatarLG)
.frame(width: 36, height: 36)     → .frame(width: DesignTokens.Size.avatarMD, height: DesignTokens.Size.avatarMD)
.frame(height: 44)                → .frame(height: DesignTokens.Size.buttonMD)
.cornerRadius(8)                  → .cornerRadiusMD()
.cornerRadius(12)                 → .cornerRadiusLG()
```

### Typography
```
.font(.system(size: 17))                    → .tokenBody()
.font(.system(size: 24, weight: .semibold)) → .tokenHeadline()
.font(.system(size: 15, weight: .medium))   → .tokenSubheadline()
.font(.system(size: 12, weight: .medium))   → .tokenCaption()
```

## Quick fixes:

1. Search for: `\.padding\(\d+\)`
   Replace with appropriate `.spacing*()` modifiers

2. Search for: `spacing:\s*\d+`
   Replace with `DesignTokens.Spacing.*` values

3. Search for: `\.font\(\.system\(size:\s*\d+`
   Replace with `.token*()` or `.design*()` modifiers

4. Search for: `\.cornerRadius\(\d+\)`
   Replace with `.cornerRadius*()` modifiers
*/

import SwiftUI

// MARK: - Migration Helpers

extension View {
    
    /// Temporary migration helper - shows current spacing in debug
    func debugSpacing(_ value: CGFloat) -> some View {
        #if DEBUG
        self.overlay(
            Text("\(Int(value))pt")
                .font(.caption2)
                .foregroundColor(.red)
                .background(.white.opacity(0.8))
                .cornerRadius(2),
            alignment: .topTrailing
        )
        #else
        self
        #endif
    }
    
    /// Quick migration: replaces hardcoded padding with nearest design token
    func migratePadding(_ value: CGFloat) -> some View {
        let tokenValue: CGFloat
        
        switch value {
        case 0...2: tokenValue = DesignTokens.Spacing.xs     // 3pt
        case 3...5: tokenValue = DesignTokens.Spacing.sm     // 6pt
        case 6...8: tokenValue = DesignTokens.Spacing.md     // 9pt
        case 9...11: tokenValue = DesignTokens.Spacing.base  // 12pt
        case 12...14: tokenValue = DesignTokens.Spacing.lg   // 15pt
        case 15...17: tokenValue = DesignTokens.Spacing.xl   // 18pt
        case 18...20: tokenValue = DesignTokens.Spacing.xxl  // 21pt
        case 21...26: tokenValue = DesignTokens.Spacing.section // 24pt
        default: tokenValue = DesignTokens.Spacing.custom(value / DesignTokens.baseUnit)
        }
        
        return self.padding(tokenValue)
            .debugSpacing(tokenValue)
    }
    
    /// Quick migration: replaces hardcoded corner radius with nearest design token
    func migrateCornerRadius(_ value: CGFloat) -> some View {
        let tokenValue: CGFloat
        
        switch value {
        case 0...4: tokenValue = DesignTokens.Size.radiusSM   // 6pt
        case 5...7: tokenValue = DesignTokens.Size.radiusMD   // 9pt
        case 8...10: tokenValue = DesignTokens.Size.radiusLG  // 12pt
        case 11...13: tokenValue = DesignTokens.Size.radiusXL // 15pt
        default: tokenValue = DesignTokens.Size.radiusXXL     // 18pt
        }
        
        return self.cornerRadius(tokenValue)
    }
}
