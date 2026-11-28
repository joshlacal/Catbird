import DesignLintCore
import Foundation
import Testing

@Suite("DesignLintCore AST Rules & Monotonic Ratchet")
struct DesignLintTests {
    private let linter = DesignLinter()

    // MARK: - a) raw_corner_radius

    @Test("Catches multiline RoundedRectangle, variable cornerRadius, .rect(cornerRadius:), UnevenRoundedRectangle, and UIKit layer.cornerRadius")
    func rawCornerRadiusCatchesAllVariants() {
        let src = """
        import SwiftUI
        import UIKit
        struct S: View {
          let r: CGFloat = 10
          var body: some View {
            VStack {
              RoundedRectangle(
                cornerRadius: 12
              )
              RoundedRectangle(cornerRadius: r, style: .continuous)
              RoundedRectangle(cornerRadius: Radius.md.value)
              UnevenRoundedRectangle(topLeadingRadius: 8, bottomTrailingRadius: 8)
              Text("hi")
                .clipShape(.rect(cornerRadius: 12))
                .cornerRadius(8)
                .cornerRadiusMD()
            }
          }
          func styleUIKit(_ v: UIView) {
            v.layer.cornerRadius = 8
            layer.cornerRadius = 6
            v.layer.cornerRadius = 0
            v.layer.cornerRadius = Radius.md.value
            v.layer.cornerRadius = v.bounds.height / 2
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let radiusViolations = violations.filter { $0.rule == LintRuleID.rawCornerRadius.rawValue }
        #expect(radiusViolations.count == 9)
    }

    @Test("Allows Radius.md.shape, .catbirdClip(.md), and continuous Radius token RoundedRectangle")
    func allowsCompliantRadii() {
        let src = """
        import SwiftUI
        struct S: View {
          var body: some View {
            Text("ok")
              .catbirdClip(.md)
              .overlay(Radius.md.shape.strokeBorder(Color.accentColor, lineWidth: 1))
              .clipShape(RoundedRectangle(cornerRadius: Radius.lg.value, style: .continuous))
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        #expect(violations.filter { $0.rule == LintRuleID.rawCornerRadius.rawValue }.isEmpty)
    }

    // MARK: - b) raw_spacing vs off_grid_spacing

    @Test("Splits on-4pt-grid raw_spacing from strictly off_grid_spacing across padding, stacks, and EdgeInsets")
    func spacingGridClassification() {
        let src = """
        import SwiftUI
        struct S: View {
          var body: some View {
            VStack(spacing: 10) {
              HStack(spacing: 8) {
                LazyVStack(spacing: 0) {
                  Text("a")
                    .padding(12)
                    .padding(.horizontal, 6)
                    .padding()
                    .padding(Space.md)
                    .padding(EdgeInsets(top: 4, leading: 14, bottom: 0, trailing: 2))
                }
              }
            }
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let offGrid = violations.filter { $0.rule == LintRuleID.offGridSpacing.rawValue }
        let onGridRaw = violations.filter { $0.rule == LintRuleID.rawSpacing.rawValue }
        // Off-grid: 10, 6, 14 (3)
        #expect(offGrid.count == 3)
        // On-grid raw literals (non-zero): 8, 12, 4, 2 (4)
        #expect(onGridRaw.count == 4)
    }

    // MARK: - c) raw_font

    @Test("Catches raw .font, multiline .font, .font(.system(.style)), .fontWeight/.bold without .appFont, and UIFont.*")
    func rawFontCatchesBypasses() {
        let src = """
        import SwiftUI
        import UIKit
        struct S: View {
          var body: some View {
            VStack {
              Text("a").font(.headline)
              Text("b").font(.system(.caption, design: .monospaced))
              Text("c")
                .font(
                  Font.customSystemFont(size: 24, weight: .bold)
                )
              Text("d").fontWeight(.semibold)
              Text("e").bold()
              Text("ok1").appFont(AppTextRole.body).fontWeight(.semibold)
              Text("ok2").appFont(AppTextRole.caption).bold()
              Text("ok3").font(nil)
            }
          }
          func ui() -> UIFont {
            UIFont.systemFont(ofSize: 15, weight: .medium)
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let fontViolations = violations.filter { $0.rule == LintRuleID.rawFont.rawValue }
        // .font(.headline), .font(.system(.caption...)), multiline .font(Font.customSystemFont), .fontWeight (no appFont), .bold (no appFont), UIFont.systemFont
        #expect(fontViolations.count == 6)
    }

    // MARK: - d) raw_color

    @Test("Catches Color(red:/hex:), Color.blue/red, shorthand .foregroundStyle(.blue), UIColor.systemBlue, and magic .opacity while allowing 0/1 opacity & non-color enums")
    func rawColorRules() {
        let src = """
        import SwiftUI
        import UIKit
        enum Status { case green, red }
        struct S: View {
          let status: Status = .green
          var body: some View {
            VStack {
              Text("a")
                .foregroundStyle(.blue)
                .background(Color.white)
                .tint(Color(red: 0.1, green: 0.2, blue: 0.3))
                .opacity(0.35)
                .opacity(0)
                .opacity(1)
            }
          }
          let u = UIColor.systemBlue
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let colorViolations = violations.filter { $0.rule == LintRuleID.rawColor.rawValue }
        // .foregroundStyle(.blue), Color.white, Color(red:...), .opacity(0.35), UIColor.systemBlue
        #expect(colorViolations.count == 5)
    }

    // MARK: - e) legacy_material

    @Test("Catches legacy SwiftUI materials, .bar in background, and UIBlurEffect")
    func legacyMaterialRules() {
        let src = """
        import SwiftUI
        import UIKit
        enum ChartKind { case bar }
        struct S: View {
          let kind: ChartKind = .bar
          var body: some View {
            Text("a")
              .background(.ultraThinMaterial)
              .background(.bar)
          }
          let blur = UIBlurEffect(style: .systemMaterial)
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let matViolations = violations.filter { $0.rule == LintRuleID.legacyMaterial.rawValue }
        #expect(matViolations.count == 3)
    }

    // MARK: - f) raw_animation

    @Test("Catches raw .animation, withAnimation, and UIView.animate while allowing Motion.* and nil")
    func rawAnimationRules() {
        let src = """
        import SwiftUI
        import UIKit
        struct S: View {
          @State var flag = false
          var body: some View {
            Text("a")
              .animation(.spring(response: 0.3), value: flag)
              .animation(Motion.enter, value: flag)
              .animation(nil, value: flag)
              .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { flag.toggle() }
                withAnimation { flag.toggle() }
                Motion.withAnimation(Motion.enter, reduceMotion: false) { flag.toggle() }
              }
          }
          func ui() {
            UIView.animate(withDuration: 0.25) {}
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let animViolations = violations.filter { $0.rule == LintRuleID.rawAnimation.rawValue }
        // .animation(.spring), withAnimation(.easeInOut), bare withAnimation, UIView.animate
        #expect(animViolations.count == 4)
    }

    // MARK: - g) legacy_design_tokens

    @Test("Catches DesignTokens.*, legacy spacing/design helpers, and .buttonStyle(.bordered/.borderedProminent)")
    func legacyDesignTokensRules() {
        let src = """
        import SwiftUI
        struct S: View {
          var body: some View {
            Button("Go") {}
              .buttonStyle(.borderedProminent)
              .padding(DesignTokens.Spacing.md)
              .spacingBase()
              .designBody()
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let legacyViolations = violations.filter { $0.rule == LintRuleID.legacyDesignTokens.rawValue }
        #expect(legacyViolations.count == 4)
    }

    // MARK: - h) small_tap_target

    @Test("Flags <44pt interactive buttons while allowing inner glyphs inside >=44pt buttons and .buttonStyle(.catbird)")
    func smallTapTargetRules() {
        let src = """
        import SwiftUI
        struct S: View {
          var body: some View {
            VStack {
              // Bad: 32x32 interactive Button
              Button(action: {}) { Image(systemName: "play") }
                .frame(width: 32, height: 32)

              // Bad: 40x40 Button label with no outer hit-target expansion (FeedProductPageView pattern)
              Button {} label: {
                Image(systemName: "heart")
                  .frame(width: 40, height: 40)
              }
              .buttonStyle(.plain)

              // Good: small inner glyph inside 62x62 Button (ChatFAB pattern)
              Button(action: {}) {
                Image(systemName: "plus")
                  .frame(width: 30, height: 30)
              }
              .frame(width: circleSize, height: circleSize)

              // Good: compensated with minHitTarget
              Button(action: {}) { Image(systemName: "xmark") }
                .frame(width: 24, height: 24)
                .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget)

              // Good: CatbirdButtonStyle enforces 44pt hit target
              Button("Follow") {}
                .frame(height: 32)
                .buttonStyle(.catbird(.primary, size: .sm))
            }
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let tapViolations = violations.filter { $0.rule == LintRuleID.smallTapTarget.rawValue }
        #expect(tapViolations.count == 2)
    }

    // MARK: - i) unreasoned_lint_disable & reasoned suppression

    @Test("Rejects unreasoned swiftlint:disable / design-lint:ignore and honors reasoned suppression with ref")
    func ignoreDirectiveEnforcement() {
        let src = """
        import SwiftUI
        struct S: View {
          var body: some View {
            VStack {
              // swiftlint:disable no_hardcoded_blue
              Text("a").foregroundStyle(Color.blue) // design-lint:ignore raw_color
              // design-lint:ignore:next raw_color -- reason: Brand swatch preview (#123)
              Text("b").foregroundStyle(Color.red)
            }
          }
        }
        """
        let violations = linter.lint(source: src, relativePath: "Catbird/Features/Test/Sample.swift")
        let unreasoned = violations.filter { $0.rule == LintRuleID.unreasonedLintDisable.rawValue }
        let rawColor = violations.filter { $0.rule == LintRuleID.rawColor.rawValue }
        #expect(unreasoned.count == 2)
        // Line with Color.blue was NOT suppressed (unreasoned); line with Color.red WAS suppressed!
        #expect(rawColor.count == 1)
    }

    // MARK: - Exclusions

    @Test("Excludes Core/UI/Kit and _trash files cleanly")
    func exclusionsWork() {
        let src = "import SwiftUI\nlet c = Color.blue"
        #expect(linter.lint(source: src, relativePath: "Catbird/Core/UI/Kit/CatbirdCard.swift").isEmpty)
        #expect(linter.lint(source: src, relativePath: "_trash/Old.swift").isEmpty)
        #expect(!linter.lint(source: src, relativePath: "CatbirdFeedWidget/Widget.swift").isEmpty)
    }

    // MARK: - Monotonic Budget Ratchet

    @Test("Ratchet passes on exact match, fails on regression, fails on new-file violation, and fails on unratcheted drop")
    func monotonicRatchetBehavior() {
        let baseline = DesignLintBudget(files: [
            "Catbird/Features/Feed/A.swift": ["raw_font": 3, "raw_color": 1],
            "Catbird/Features/Feed/B.swift": ["raw_spacing": 2],
        ])

        // 1. Exact match -> PASS
        let exactViolations = [
            Violation(file: "Catbird/Features/Feed/A.swift", line: 1, column: 1, rule: .rawFont, message: ""),
            Violation(file: "Catbird/Features/Feed/A.swift", line: 2, column: 1, rule: .rawFont, message: ""),
            Violation(file: "Catbird/Features/Feed/A.swift", line: 3, column: 1, rule: .rawFont, message: ""),
            Violation(file: "Catbird/Features/Feed/A.swift", line: 4, column: 1, rule: .rawColor, message: ""),
            Violation(file: "Catbird/Features/Feed/B.swift", line: 1, column: 1, rule: .rawSpacing, message: ""),
            Violation(file: "Catbird/Features/Feed/B.swift", line: 2, column: 1, rule: .rawSpacing, message: ""),
        ]
        let exactEval = BudgetRatchet.evaluate(budget: baseline, violations: exactViolations, enforceShrink: true)
        #expect(exactEval.passed)
        #expect(exactEval.issues.isEmpty)

        // 2. Regression (+1 in existing file) -> FAIL
        let regressed = exactViolations + [
            Violation(file: "Catbird/Features/Feed/A.swift", line: 5, column: 1, rule: .rawFont, message: ""),
        ]
        let regEval = BudgetRatchet.evaluate(budget: baseline, violations: regressed, enforceShrink: true)
        #expect(!regEval.passed)
        #expect(regEval.issues.contains { $0.kind == .regression && $0.file == "Catbird/Features/Feed/A.swift" && $0.rule == "raw_font" })

        // 3. New file with >0 violations -> FAIL
        let newFile = exactViolations + [
            Violation(file: "Catbird/Features/Feed/BrandNew.swift", line: 10, column: 1, rule: .offGridSpacing, message: ""),
        ]
        let newEval = BudgetRatchet.evaluate(budget: baseline, violations: newFile, enforceShrink: true)
        #expect(!newEval.passed)
        #expect(newEval.issues.contains { $0.kind == .newFileViolation && $0.file == "Catbird/Features/Feed/BrandNew.swift" })

        // 4. Unratcheted drop (fixed 1 violation in A.swift without updating budget) -> FAIL under enforceShrink
        let dropped = Array(exactViolations.dropFirst())
        let dropEval = BudgetRatchet.evaluate(budget: baseline, violations: dropped, enforceShrink: true)
        #expect(!dropEval.passed)
        #expect(dropEval.issues.contains { $0.kind == .unratchetedDrop && $0.file == "Catbird/Features/Feed/A.swift" })

        // 5. Scoped single-file check does not fail on untouched B.swift
        let scopedEval = BudgetRatchet.evaluate(
            budget: baseline,
            violations: exactViolations.filter { $0.file.hasSuffix("A.swift") },
            scopedFiles: ["Catbird/Features/Feed/A.swift"],
            enforceShrink: false
        )
        #expect(scopedEval.passed)

        // 6. Budget diff detects ceiling increases
        let bumpedBudget = DesignLintBudget(files: [
            "Catbird/Features/Feed/A.swift": ["raw_font": 4, "raw_color": 1],
            "Catbird/Features/Feed/B.swift": ["raw_spacing": 2],
        ])
        let increases = BudgetRatchet.budgetIncreases(from: baseline, to: bumpedBudget)
        #expect(increases.count == 1)
        #expect(increases.first?.file == "Catbird/Features/Feed/A.swift")
    }

    @Test("Ingests SwiftLint JSON violations with swiftlint. prefix")
    func swiftLintJSONIngestion() throws {
        let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
        let json = """
        [
          {
            "file": "/tmp/repo/Catbird/Features/Feed/Post.swift",
            "line": 42,
            "character": 9,
            "rule_id": "no_hardcoded_blue",
            "reason": "Use Color.accentColor"
          },
          {
            "file": "/tmp/repo/Catbird/Core/UI/Kit/CatbirdCard.swift",
            "line": 10,
            "character": 1,
            "rule_id": "no_hardcoded_blue",
            "reason": "Excluded"
          }
        ]
        """
        let parsed = try linter.parseSwiftLintJSON(Data(json.utf8), root: root)
        #expect(parsed.count == 1)
        #expect(parsed[0].file == "Catbird/Features/Feed/Post.swift")
        #expect(parsed[0].rule == "swiftlint.no_hardcoded_blue")
        #expect(parsed[0].line == 42)
    }
}
