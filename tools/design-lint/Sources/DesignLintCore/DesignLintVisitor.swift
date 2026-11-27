import Foundation
import SwiftSyntax

public struct FileRuleExemptions: Sendable {
    public let exemptRules: Set<LintRuleID>

    public init(exemptRules: Set<LintRuleID> = []) {
        self.exemptRules = exemptRules
    }

    public static func forPath(_ relativePath: String) -> FileRuleExemptions {
        var exempt: Set<LintRuleID> = []
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")

        if normalized.hasSuffix("Core/State/FontManager.swift")
            || normalized.hasSuffix("Core/Services/FontManager.swift")
            || normalized.hasSuffix("Core/Extensions/Typography.swift")
            || normalized.hasSuffix("Core/UI/Typography.swift")
            || normalized.hasSuffix("Core/UI/AppUIFont.swift")
            || normalized.hasSuffix("Core/UI/NavigationFontConfig.swift")
        {
            exempt.insert(.rawFont)
        }

        if normalized.hasSuffix("Core/UI/ThemeColors.swift")
            || normalized.hasSuffix("Core/UI/ThemedViewModifiers.swift")
            || normalized.hasSuffix("Core/Extensions/PlatformColors.swift")
        {
            exempt.insert(.rawColor)
        }

        if normalized.hasSuffix("Core/UI/DesignTokens.swift") {
            exempt.insert(.legacyDesignTokens)
            exempt.insert(.rawCornerRadius)
            exempt.insert(.rawColor)
            exempt.insert(.rawFont)
        }

        return FileRuleExemptions(exemptRules: exempt)
    }
}

/// SwiftSyntax AST visitor enforcing Catbird's design-system invariants.
public final class DesignLintVisitor: SyntaxVisitor {
    public private(set) var violations: [Violation] = []

    private let file: String
    private let converter: SourceLocationConverter
    private let ignores: IgnoreDirectiveIndex
    private let exemptions: FileRuleExemptions

    private static let layoutStackTypes: Set<String> = [
        "VStack", "HStack", "LazyVStack", "LazyHStack", "VStackLayout", "HStackLayout", "Grid",
    ]

    private static let rawColorNames: Set<String> = [
        "blue", "white", "black", "gray", "red", "orange", "green",
        "yellow", "purple", "pink", "indigo", "teal", "cyan", "mint", "brown",
    ]

    private static let rawUIColorNames: Set<String> = [
        "systemBlue", "systemRed", "systemGreen", "systemOrange", "systemYellow",
        "systemPink", "systemPurple", "systemTeal", "systemIndigo", "systemMint",
        "systemCyan", "systemBrown", "systemGray", "systemGray2", "systemGray3",
        "systemGray4", "systemGray5", "systemGray6",
        "blue", "red", "green", "orange", "yellow", "purple", "brown",
        "white", "black", "gray", "darkGray", "lightGray", "cyan", "magenta",
    ]

    private static let colorBearingModifiers: Set<String> = [
        "foregroundStyle", "foregroundColor", "tint", "fill", "background",
        "stroke", "strokeBorder", "listRowBackground", "shadow", "accentColor",
    ]

    private static let legacyMaterials: Set<String> = [
        "ultraThinMaterial", "thinMaterial", "regularMaterial",
        "thickMaterial", "ultraThickMaterial",
    ]

    private static let legacyDesignHelpers: Set<String> = [
        "spacingXS", "spacingSM", "spacingMD", "spacingBase", "spacingLG", "spacingXL", "spacingXXL",
        "designFont", "designTitle1", "designTitle2", "designHeadline", "designBody",
        "designBodyLarge", "designCallout", "designCaption", "designFootnote",
        "shadowSubtle", "shadowSoft", "shadowMedium", "shadowStrong",
    ]

    private static let legacyCornerRadiusModifiers: Set<String> = [
        "cornerRadius", "cornerRadiusXS", "cornerRadiusSM", "cornerRadiusMD",
        "cornerRadiusLG", "cornerRadiusXL",
    ]

    private static let uiFontFactories: Set<String> = [
        "systemFont", "boldSystemFont", "italicSystemFont",
        "monospacedSystemFont", "monospacedDigitSystemFont", "preferredFont",
    ]

    private static let interactiveRootTypes: Set<String> = [
        "Button", "Link", "Menu", "ShareLink", "EditButton", "PasteButton",
    ]

    public init(
        file: String,
        converter: SourceLocationConverter,
        ignores: IgnoreDirectiveIndex,
        exemptions: FileRuleExemptions
    ) {
        self.file = file
        self.converter = converter
        self.ignores = ignores
        self.exemptions = exemptions
        super.init(viewMode: .sourceAccurate)
        self.violations.append(contentsOf: ignores.unreasonedViolations)
    }

    private func record(_ rule: LintRuleID, at node: some SyntaxProtocol, message: String) {
        guard !exemptions.exemptRules.contains(rule) else { return }
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        if ignores.isSuppressed(rule: rule, line: loc.line) {
            return
        }
        violations.append(
            Violation(file: file, line: loc.line, column: loc.column, rule: rule, message: message)
        )
    }

    // MARK: - Function Calls

    public override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        checkCornerRadiusCall(node)
        checkSpacingAndPaddingCall(node)
        checkFontCall(node)
        checkColorCall(node)
        checkMaterialCall(node)
        checkAnimationCall(node)
        checkLegacyDesignHelpersCall(node)
        checkSmallTapTarget(node)
        return .visitChildren
    }

    // MARK: - Member Accesses

    public override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.declName.baseName.text
        let baseText = node.base?.trimmedDescription

        // Legacy DesignTokens.*
        if baseText == "DesignTokens" {
            record(
                .legacyDesignTokens,
                at: node,
                message: "Legacy DesignTokens.\(name) uses the retired 3pt grid; use CatbirdTokens (Space/Radius/ControlHeight/AvatarSize/Motion)."
            )
        }

        // Legacy Material.*
        if Self.legacyMaterials.contains(name) {
            record(
                .legacyMaterial,
                at: node,
                message: "Legacy material .\(name) breaks iOS 26 Liquid Glass and True Black parity; use .catbirdGlass(...) or themed surfaces."
            )
        } else if name == "bar", baseText == "Material" {
            record(
                .legacyMaterial,
                at: node,
                message: "Legacy Material.bar breaks iOS 26 Liquid Glass / True Black parity; use .catbirdGlass(...) or themed surfaces."
            )
        }

        // Raw Color.* and UIColor.*
        if baseText == "Color", Self.rawColorNames.contains(name) {
            record(
                .rawColor,
                at: node,
                message: "Raw Color.\(name) bypasses CatbirdTheme/semantic roles; use CatbirdTheme or Color.accentColor."
            )
        } else if baseText == "UIColor", Self.rawUIColorNames.contains(name) {
            record(
                .rawColor,
                at: node,
                message: "Raw UIColor.\(name) bypasses CatbirdTheme/semantic colors; use ThemeColors or CatbirdTheme."
            )
        }

        return .visitChildren
    }

    // MARK: - Assignments (UIKit .layer.cornerRadius =)

    public override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count >= 3 else { return .visitChildren }
        for i in 0..<(elements.count - 2) {
            guard elements[i + 1].is(AssignmentExprSyntax.self) else { continue }
            let lhs = elements[i]
            let rhsSlice = elements[(i + 2)...]
            if let member = lhs.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "cornerRadius",
               isLayerReference(member.base)
            {
                let rhsText = rhsSlice.map(\.trimmedDescription).joined(separator: " ")
                if rhsSlice.count == 1, let only = rhsSlice.first, let val = numericLiteralValue(only), val == 0 {
                    continue
                }
                if rhsText.contains("Radius.") || rhsText.contains("/ 2") || rhsText.contains("/2") || rhsText.contains("* 0.5") {
                    continue
                }
                record(
                    .rawCornerRadius,
                    at: lhs,
                    message: "UIKit .layer.cornerRadius = \(rhsText) must use Radius.<token>.value (with layer.cornerCurve = .continuous)."
                )
            }
        }
        return .visitChildren
    }

    public override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "colorLiteral" {
            record(
                .rawColor,
                at: node,
                message: "Raw #colorLiteral(...) hardcodes RGB values; use CatbirdTheme or CatbirdBrand tokens."
            )
        }
        return .visitChildren
    }

    private func isLayerReference(_ expr: ExprSyntax?) -> Bool {
        guard let expr else { return false }
        if let member = expr.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "layer" {
            return true
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self), ref.baseName.text == "layer" {
            return true
        }
        return false
    }

    // MARK: - Rule Checks

    private func checkCornerRadiusCall(_ node: FunctionCallExprSyntax) {
        if let ident = calleeIdentifier(node) {
            if ident == "RoundedRectangle" {
                let args = node.arguments
                if let crArg = argument(named: "cornerRadius", in: args) {
                    let exprText = crArg.expression.trimmedDescription
                    let isRadiusToken = exprText.contains("Radius.") || exprText.hasSuffix(".value")
                    let hasContinuous = argument(named: "style", in: args)?.expression.trimmedDescription.contains(".continuous") == true
                    if !isRadiusToken {
                        record(
                            .rawCornerRadius,
                            at: node,
                            message: "Use Radius.<token>.shape or .catbirdClip(.<token>) instead of RoundedRectangle(cornerRadius: \(exprText))."
                        )
                    } else if !hasContinuous {
                        record(
                            .rawCornerRadius,
                            at: node,
                            message: "RoundedRectangle must specify `style: .continuous` (or use `Radius.<token>.shape`)."
                        )
                    }
                } else if argument(named: "cornerSize", in: args) != nil {
                    record(
                        .rawCornerRadius,
                        at: node,
                        message: "Use Radius.<token>.shape or .catbirdClip(.<token>) instead of RoundedRectangle(cornerSize:)."
                    )
                }
            } else if ident == "UnevenRoundedRectangle" {
                let argsText = node.arguments.trimmedDescription
                if !argsText.contains("Radius.") {
                    record(
                        .rawCornerRadius,
                        at: node,
                        message: "Use Radius tokens for UnevenRoundedRectangle corner radii instead of raw literals."
                    )
                }
            }
        }

        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if Self.legacyCornerRadiusModifiers.contains(name) {
                record(
                    .rawCornerRadius,
                    at: node,
                    message: ".\(name)() is legacy/non-continuous; use .catbirdClip(.<token>) or .catbirdCard(...)."
                )
            } else if name == "rect", let crArg = argument(named: "cornerRadius", in: node.arguments) {
                let exprText = crArg.expression.trimmedDescription
                let isRadiusToken = exprText.contains("Radius.") || exprText.hasSuffix(".value")
                let hasContinuous = argument(named: "style", in: node.arguments)?.expression.trimmedDescription.contains(".continuous") == true
                if !isRadiusToken || !hasContinuous {
                    record(
                        .rawCornerRadius,
                        at: node,
                        message: "Use .catbirdClip(.<token>) / Radius.<token>.shape instead of .rect(cornerRadius: \(exprText))."
                    )
                }
            } else if name == "rect", argument(named: "topLeadingRadius", in: node.arguments) != nil || argument(named: "cornerRadii", in: node.arguments) != nil {
                if !node.arguments.trimmedDescription.contains("Radius.") {
                    record(
                        .rawCornerRadius,
                        at: node,
                        message: "Use Radius tokens instead of raw numeric radii in .rect(...)."
                    )
                }
            }
        }
    }

    private func checkSpacingAndPaddingCall(_ node: FunctionCallExprSyntax) {
        // 1. .padding(...)
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "padding"
        {
            for arg in node.arguments {
                if let val = numericLiteralValue(arg.expression) {
                    recordSpacingLiteral(val, at: arg.expression, context: ".padding(\(arg.expression.trimmedDescription))")
                }
            }
            return
        }

        // 2. VStack / HStack / LazyVStack / LazyHStack / Grid(spacing:)
        if let ident = calleeIdentifier(node), Self.layoutStackTypes.contains(ident) {
            for label in ["spacing", "horizontalSpacing", "verticalSpacing"] {
                if let spacingArg = argument(named: label, in: node.arguments),
                   let val = numericLiteralValue(spacingArg.expression)
                {
                    recordSpacingLiteral(val, at: spacingArg.expression, context: "\(ident)(\(label): \(spacingArg.expression.trimmedDescription))")
                }
            }
            return
        }

        // 3. EdgeInsets(top:leading:bottom:trailing:)
        if calleeIdentifier(node) == "EdgeInsets" {
            for arg in node.arguments {
                if let val = numericLiteralValue(arg.expression) {
                    let label = arg.label?.text ?? "edge"
                    recordSpacingLiteral(val, at: arg.expression, context: "EdgeInsets(\(label): \(arg.expression.trimmedDescription))")
                }
            }
        }
    }

    private func recordSpacingLiteral(_ rawValue: Double, at node: some SyntaxProtocol, context: String) {
        let value = abs(rawValue)
        if value == 0 { return }
        if isOnFourPointGrid(value) {
            record(
                .rawSpacing,
                at: node,
                message: "Raw spacing literal in \(context); use Space.<token> from CatbirdTokens."
            )
        } else {
            record(
                .offGridSpacing,
                at: node,
                message: "Off-4pt-grid spacing literal (\(formatNumber(rawValue))pt) in \(context); snap to Space.<token> (2/4/8/12/16/20/24/32/40/48/64)."
            )
        }
    }

    private func checkFontCall(_ node: FunctionCallExprSyntax) {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            let baseText = member.base?.trimmedDescription

            // View.font(...) — bypasses .appFont(AppTextRole.*)
            if name == "font", member.base != nil, node.arguments.count == 1 {
                let firstArg = node.arguments.first!
                let argText = firstArg.expression.trimmedDescription
                if firstArg.label == nil && argText != "nil" {
                    record(
                        .rawFont,
                        at: node,
                        message: "Raw .font(\(truncate(argText, max: 40))) bypasses user font preferences; use .appFont(AppTextRole.*)."
                    )
                }
                return
            }

            // Font.system(...) / Font.custom(...) / Font.customSystemFont(...)
            if baseText == "Font", ["system", "custom", "customSystemFont"].contains(name) {
                // Skip if directly inside a `.font(...)` argument already flagged above
                if !isDirectArgumentOfModifier(node, named: "font") {
                    record(
                        .rawFont,
                        at: node,
                        message: "Raw Font.\(name)(...) bypasses FontManager; use .appFont(AppTextRole.*)."
                    )
                }
                return
            }

            // UIFont.* factories
            if baseText == "UIFont", Self.uiFontFactories.contains(name) {
                record(
                    .rawFont,
                    at: node,
                    message: "Raw UIFont.\(name)(...) bypasses user font preferences; use AppUIFont.font(...)."
                )
                return
            }

            // .fontWeight(...) or .bold() without .appFont in the modifier chain
            if (name == "fontWeight" && member.base != nil)
                || (name == "bold" && member.base != nil && !isExplicitlyFalseBooleanArg(node.arguments))
            {
                if !modifierChainContainsAppFont(node) {
                    record(
                        .rawFont,
                        at: node,
                        message: ".\(name)() without .appFont(...) causes font/weight divergence; set weight via .appFont(AppTextRole.*.weight(...))."
                    )
                }
                return
            }
        }

        // UIFont(name: ..., size: ...)
        if calleeIdentifier(node) == "UIFont", argument(named: "name", in: node.arguments) != nil {
            record(
                .rawFont,
                at: node,
                message: "Raw UIFont(name:size:) bypasses AppUIFont; use AppUIFont.font(...)."
            )
        }
    }

    private func checkColorCall(_ node: FunctionCallExprSyntax) {
        // Color(red:/white:/hue:/hex:) and UIColor(red:/white:/hue:)
        if let ident = calleeIdentifier(node), ident == "Color" || ident == "UIColor" {
            let labels = Set(node.arguments.compactMap { $0.label?.text })
            if !labels.isDisjoint(with: ["red", "white", "hue", "hex"]) {
                record(
                    .rawColor,
                    at: node,
                    message: "Raw \(ident)(\(labels.sorted().joined(separator: ":"))) hardcodes RGB/hex values; use CatbirdTheme or CatbirdBrand tokens."
                )
            }
            return
        }

        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return }
        let name = member.declName.baseName.text

        // Color-taking modifiers with shorthand raw colors like `.foregroundStyle(.blue)` / `.fill(.red)`
        if Self.colorBearingModifiers.contains(name) {
            for arg in node.arguments {
                if name == "shadow", arg.label?.text != "color" { continue }
                if let argMember = arg.expression.as(MemberAccessExprSyntax.self),
                   argMember.base == nil,
                   Self.rawColorNames.contains(argMember.declName.baseName.text)
                {
                    let colorName = argMember.declName.baseName.text
                    record(
                        .rawColor,
                        at: arg.expression,
                        message: "Raw shorthand .\(colorName) in .\(name)(...); use CatbirdTheme semantic color or Color.accentColor."
                    )
                }
            }
        }

        // Arbitrary .opacity(x) magic literals (skip visibility toggles 0 / 1)
        if name == "opacity", member.base != nil, let first = node.arguments.first, first.label == nil {
            if let val = numericLiteralValue(first.expression), val > 0, val < 1 {
                record(
                    .rawColor,
                    at: node,
                    message: "Magic literal .opacity(\(formatNumber(val))); use CatbirdTheme semantic opacity/border/surface tokens."
                )
            }
        }
    }

    private func checkMaterialCall(_ node: FunctionCallExprSyntax) {
        if let ident = calleeIdentifier(node), ident == "UIBlurEffect" || ident == "UIVibrancyEffect" {
            record(
                .legacyMaterial,
                at: node,
                message: "Legacy \(ident) bypasses iOS 26 Liquid Glass / True Black parity; use .catbirdGlass(...) or themed surfaces."
            )
            return
        }

        // Catch shorthand `.bar` ONLY inside background/foregroundStyle/toolbarBackground material slots
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           ["background", "foregroundStyle", "toolbarBackground"].contains(member.declName.baseName.text)
        {
            for arg in node.arguments {
                if let argMember = arg.expression.as(MemberAccessExprSyntax.self),
                   argMember.base == nil,
                   argMember.declName.baseName.text == "bar"
                {
                    record(
                        .legacyMaterial,
                        at: arg.expression,
                        message: "Legacy .bar material in .\(member.declName.baseName.text)(...); use .catbirdGlass(...) or themed surfaces."
                    )
                }
            }
        }
    }

    private func checkAnimationCall(_ node: FunctionCallExprSyntax) {
        if let ident = calleeIdentifier(node), ident == "withAnimation" {
            if let first = node.arguments.first {
                let text = first.expression.trimmedDescription
                if text != "nil" && !text.contains("Motion.") {
                    record(
                        .rawAnimation,
                        at: node,
                        message: "Raw withAnimation(\(truncate(text, max: 40))) bypasses Motion tokens and Reduce Motion; use Motion.withAnimation(Motion.<intent>, reduceMotion:)."
                    )
                }
            } else {
                record(
                    .rawAnimation,
                    at: node,
                    message: "Bare withAnimation { ... } bypasses Motion tokens and Reduce Motion; use Motion.withAnimation(Motion.<intent>, reduceMotion:)."
                )
            }
            return
        }

        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return }
        let name = member.declName.baseName.text

        if name == "animation", member.base != nil, let first = node.arguments.first {
            let text = first.expression.trimmedDescription
            if text != "nil" && !text.contains("Motion.") {
                record(
                    .rawAnimation,
                    at: node,
                    message: "Raw .animation(\(truncate(text, max: 40)), ...) bypasses Motion tokens and Reduce Motion; use .catbirdAnimation(Motion.<intent>, value:)."
                )
            }
        } else if name == "animate", member.base?.trimmedDescription == "UIView" {
            record(
                .rawAnimation,
                at: node,
                message: "Raw UIView.animate(...) bypasses Motion tokens and Reduce Motion; respect UIAccessibility.isReduceMotionEnabled and Motion durations."
            )
        } else if name == "withAnimation", member.base?.trimmedDescription == "SwiftUI" {
            if let first = node.arguments.first {
                let text = first.expression.trimmedDescription
                if text != "nil" && !text.contains("Motion.") {
                    record(
                        .rawAnimation,
                        at: node,
                        message: "Raw SwiftUI.withAnimation(\(truncate(text, max: 40))) bypasses Motion tokens; use Motion.withAnimation(...)."
                    )
                }
            }
        }
    }

    private func checkLegacyDesignHelpersCall(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return }
        let name = member.declName.baseName.text

        if member.base != nil, Self.legacyDesignHelpers.contains(name) {
            record(
                .legacyDesignTokens,
                at: node,
                message: "Legacy DesignTokens helper .\(name)() is deprecated; use CatbirdTokens / .appFont(AppTextRole.*)."
            )
            return
        }

        if name == "buttonStyle", member.base != nil, let first = node.arguments.first {
            let text = first.expression.trimmedDescription
            if text == ".bordered" || text == ".borderedProminent"
                || text == "BorderedButtonStyle()" || text == "BorderedProminentButtonStyle()"
            {
                record(
                    .legacyDesignTokens,
                    at: node,
                    message: "Legacy .buttonStyle(\(text)) diverges from Catbird capsule buttons; use .buttonStyle(.catbird(...))."
                )
            }
        }
    }

    /// Flags interactive controls (`Button`, `Link`, `Menu`, or `.onTapGesture` chains)
    /// that clamp their own frame to `< 44pt` without compensating `minWidth`/`minHeight >= 44`,
    /// `ControlHeight.minHitTarget`, `.contentShape(...)`, or `.buttonStyle(.catbird(...))`.
    private func checkSmallTapTarget(_ node: FunctionCallExprSyntax) {
        // Only evaluate at the outermost call of a modifier chain to avoid duplicate diagnostics.
        guard !isBaseOfEnclosingModifierCall(node) else { return }

        let chain = extractModifierChain(from: node)
        let isInteractive = chain.isInteractiveRoot || chain.modifiers.contains { $0.name == "onTapGesture" }
        guard isInteractive else { return }

        // If chain adopts Catbird button style or explicitly expands hit target to >=44pt (or dynamic variable outer frame like ChatFAB's circleSize), it's safe.
        let hasOuterFrame = chain.modifiers.contains { $0.name == "frame" }
        let hasOuterPadding = chain.modifiers.contains { $0.name == "padding" }
        let hasSafeExpansion = chain.modifiers.contains { mod in
            if mod.name == "buttonStyle", mod.call.arguments.trimmedDescription.contains(".catbird") {
                return true
            }
            if mod.name == "frame" {
                let text = mod.call.arguments.trimmedDescription
                if text.contains("minHitTarget") { return true }
                let minW = argument(named: "minWidth", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
                let minH = argument(named: "minHeight", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
                if (minW ?? 0) >= 44 && (minH ?? 0) >= 44 { return true }
                if minW == nil, (minH ?? 0) >= 44 { return true }
                if minH == nil, (minW ?? 0) >= 44 { return true }
            }
            return false
        }
        if hasSafeExpansion { return }

        var flaggedOuter = false
        for mod in chain.modifiers where mod.name == "frame" {
            let w = argument(named: "width", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
            let h = argument(named: "height", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
            let smallW = w.map { $0 > 0 && $0 < 44 } ?? false
            let smallH = h.map { $0 > 0 && $0 < 44 } ?? false
            if smallW || smallH {
                flaggedOuter = true
                let dims = [
                    w.map { "width: \(formatNumber($0))" },
                    h.map { "height: \(formatNumber($0))" },
                ].compactMap { $0 }.joined(separator: ", ")
                record(
                    .smallTapTarget,
                    at: mod.call,
                    message: "Interactive control clamped below 44pt minimum tap target (.frame(\(dims))); add .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget) or use CatbirdIconButton."
                )
            }
        }

        // Also inspect a Button's label closure when the Button itself has no outer .frame() or .padding():
        // e.g. `Button { ... } label: { Image(...).frame(width: 40, height: 40) }`.
        if !flaggedOuter, !hasOuterFrame, !hasOuterPadding,
           let rootCall = chain.rootCall,
           calleeIdentifier(rootCall) == "Button",
           let labelClosure = buttonLabelClosure(rootCall),
           labelClosure.statements.count == 1,
           let singleExpr = labelClosure.statements.first?.item.as(ExprSyntax.self),
           let labelCall = singleExpr.as(FunctionCallExprSyntax.self)
        {
            let labelChain = extractModifierChain(from: labelCall)
            let labelHasSafeExpansion = labelChain.modifiers.contains { mod in
                guard mod.name == "frame" else { return false }
                let text = mod.call.arguments.trimmedDescription
                if text.contains("minHitTarget") { return true }
                let minW = argument(named: "minWidth", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
                let minH = argument(named: "minHeight", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
                return (minW ?? 0) >= 44 || (minH ?? 0) >= 44
            }
            if !labelHasSafeExpansion {
                for mod in labelChain.modifiers where mod.name == "frame" {
                    let w = argument(named: "width", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
                    let h = argument(named: "height", in: mod.call.arguments).flatMap { numericLiteralValue($0.expression) }
                    let smallW = w.map { $0 > 0 && $0 < 44 } ?? false
                    let smallH = h.map { $0 > 0 && $0 < 44 } ?? false
                    if smallW || smallH {
                        let dims = [
                            w.map { "width: \(formatNumber($0))" },
                            h.map { "height: \(formatNumber($0))" },
                        ].compactMap { $0 }.joined(separator: ", ")
                        record(
                            .smallTapTarget,
                            at: mod.call,
                            message: "Button label clamped below 44pt without outer hit-target expansion (.frame(\(dims))); expand to >=44pt or use CatbirdIconButton."
                        )
                    }
                }
            }
        }
    }

    private func buttonLabelClosure(_ buttonCall: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        if let labelTrailing = buttonCall.additionalTrailingClosures.first(where: { $0.label.text == "label" }) {
            return labelTrailing.closure
        }
        // `Button(action: ...) { <label> }` — single trailing closure is the label when `action:` is an argument
        if let trailing = buttonCall.trailingClosure,
           argument(named: "action", in: buttonCall.arguments) != nil
        {
            return trailing
        }
        return nil
    }

    // MARK: - AST Helpers

    private struct ModifierStep {
        let name: String
        let call: FunctionCallExprSyntax
    }

    private struct ModifierChain {
        let isInteractiveRoot: Bool
        let rootCall: FunctionCallExprSyntax?
        let modifiers: [ModifierStep]
    }

    private func isBaseOfEnclosingModifierCall(_ node: FunctionCallExprSyntax) -> Bool {
        guard let parentMember = node.parent?.as(MemberAccessExprSyntax.self),
              parentMember.base?.id == node.id,
              parentMember.parent?.is(FunctionCallExprSyntax.self) == true
        else {
            return false
        }
        return true
    }

    private func extractModifierChain(from outermost: FunctionCallExprSyntax) -> ModifierChain {
        var steps: [ModifierStep] = []
        var current: ExprSyntax = ExprSyntax(outermost)
        var isInteractiveRoot = false
        var rootCall: FunctionCallExprSyntax? = nil

        while let call = current.as(FunctionCallExprSyntax.self) {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               let base = member.base
            {
                steps.append(ModifierStep(name: member.declName.baseName.text, call: call))
                current = base
            } else {
                rootCall = call
                if let ident = calleeIdentifier(call), Self.interactiveRootTypes.contains(ident) {
                    isInteractiveRoot = true
                }
                break
            }
        }

        return ModifierChain(isInteractiveRoot: isInteractiveRoot, rootCall: rootCall, modifiers: steps)
    }

    private func modifierChainContainsAppFont(_ node: FunctionCallExprSyntax) -> Bool {
        // Walk inward (bases)
        var cur: ExprSyntax? = ExprSyntax(node)
        while let expr = cur, let call = expr.as(FunctionCallExprSyntax.self) {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                let name = member.declName.baseName.text
                if name == "appFont" || name.hasPrefix("app") && ["appBody", "appHeadline", "appTitle", "appCaption", "appSubheadline", "appFootnote", "appCallout"].contains(name) {
                    return true
                }
                cur = member.base
            } else {
                break
            }
        }

        // Walk outward (enclosing chained modifiers)
        var parent = node.parent
        while let p = parent {
            if let member = p.as(MemberAccessExprSyntax.self),
               let call = member.parent?.as(FunctionCallExprSyntax.self)
            {
                let name = member.declName.baseName.text
                if name == "appFont" || ["appBody", "appHeadline", "appTitle", "appCaption", "appSubheadline", "appFootnote", "appCallout"].contains(name) {
                    return true
                }
                parent = call.parent
            } else {
                break
            }
        }
        return false
    }

    private func isDirectArgumentOfModifier(_ node: FunctionCallExprSyntax, named modifierName: String) -> Bool {
        guard let labeled = node.parent?.as(LabeledExprSyntax.self),
              let argList = labeled.parent?.as(LabeledExprListSyntax.self),
              let call = argList.parent?.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self)
        else {
            return false
        }
        return member.declName.baseName.text == modifierName
    }

    private func isExplicitlyFalseBooleanArg(_ args: LabeledExprListSyntax) -> Bool {
        guard args.count == 1, let first = args.first else { return false }
        return first.expression.trimmedDescription == "false"
    }

    private func calleeIdentifier(_ node: FunctionCallExprSyntax) -> String? {
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let gen = node.calledExpression.as(GenericSpecializationExprSyntax.self),
           let ref = gen.expression.as(DeclReferenceExprSyntax.self)
        {
            return ref.baseName.text
        }
        return nil
    }

    private func argument(named label: String, in arguments: LabeledExprListSyntax) -> LabeledExprSyntax? {
        arguments.first { $0.label?.text == label }
    }

    private func numericLiteralValue(_ expr: ExprSyntax) -> Double? {
        if let intLit = expr.as(IntegerLiteralExprSyntax.self) {
            return Double(intLit.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        if let floatLit = expr.as(FloatLiteralExprSyntax.self) {
            return Double(floatLit.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            let op = prefix.operator.text
            if op == "-", let inner = numericLiteralValue(prefix.expression) {
                return -inner
            }
            if op == "+", let inner = numericLiteralValue(prefix.expression) {
                return inner
            }
        }
        return nil
    }

    private func isOnFourPointGrid(_ value: Double) -> Bool {
        if value == 0 || value == 2 { return true }
        let rem = value.truncatingRemainder(dividingBy: 4)
        return abs(rem) < 1e-9 || abs(rem - 4) < 1e-9
    }

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private func truncate(_ s: String, max: Int) -> String {
        let compact = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        if compact.count <= max { return compact }
        return String(compact.prefix(max)) + "…"
    }
}
