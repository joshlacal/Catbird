//
//  CatbirdDesignInspectorOverlay.swift
//  Catbird
//
//  DEBUG-only live wireframe & floating HUD overlay backed by `CatbirdDesignInspector`.
//  Usage: `.catbirdDesignInspector(enabled: config.inspectorEnabled)`
//

#if DEBUG
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Public View Hook

extension View {
  /// Attaches the DEBUG-only live Design Inspector HUD and wireframe callouts.
  /// When `enabled` is false, renders `self` without extra chrome unless toggled via
  /// `Notification.Name.catbirdToggleDesignInspector`.
  func catbirdDesignInspector(
    enabled: Bool,
    surface: String = "screen",
    profile: String? = nil,
    fontStyle: String? = nil,
    accentColor: String? = nil,
    reduceTransparency: Bool? = nil
  ) -> some View {
    modifier(
      CatbirdDesignInspectorOverlayModifier(
        initialEnabled: enabled,
        surface: surface,
        profileOverride: profile,
        fontStyleOverride: fontStyle,
        accentColorOverride: accentColor,
        reduceTransparencyOverride: reduceTransparency
      )
    )
  }
}

// MARK: - Overlay Modifier

private struct CatbirdDesignInspectorOverlayModifier: ViewModifier {
  let initialEnabled: Bool
  let surface: String
  let profileOverride: String?
  let fontStyleOverride: String?
  let accentColorOverride: String?
  let reduceTransparencyOverride: Bool?

  @State private var isEnabled: Bool
  @State private var isExpanded = false
  @State private var showWireframes = true
  @State private var showGrid = false
  @State private var report: CatbirdDesignAuditReport?

  @Environment(\.catbirdTheme) private var catbirdTheme
  @Environment(\.themeManager) private var themeManager
  @Environment(\.fontManager) private var fontManager
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
  @Environment(\.accessibilityReduceMotion) private var envReduceMotion
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  #if os(iOS)
  @State private var hostWindow: UIWindow?
  #endif

  init(
    initialEnabled: Bool,
    surface: String,
    profileOverride: String?,
    fontStyleOverride: String?,
    accentColorOverride: String?,
    reduceTransparencyOverride: Bool?
  ) {
    self.initialEnabled = initialEnabled
    self.surface = surface
    self.profileOverride = profileOverride
    self.fontStyleOverride = fontStyleOverride
    self.accentColorOverride = accentColorOverride
    self.reduceTransparencyOverride = reduceTransparencyOverride
    self._isEnabled = State(initialValue: initialEnabled)
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: initialEnabled) { _, newValue in
        isEnabled = newValue
      }
      .onReceive(NotificationCenter.default.publisher(for: .catbirdToggleDesignInspector)) { _ in
        isEnabled.toggle()
        if isEnabled {
          runAudit()
        }
      }
      .overlay {
        inspectorLayer
      }
  }

  @ViewBuilder
  private var inspectorLayer: some View {
    #if os(iOS)
    if isEnabled {
      ZStack(alignment: .topTrailing) {
        InspectorWindowAnchor { window in
          if self.hostWindow !== window {
            self.hostWindow = window
            self.runAudit()
          }
        }
        .allowsHitTesting(false)

        if showGrid {
          FourPointGridOverlay(lineColor: catbirdTheme.border(.subtle))
            .allowsHitTesting(false)
        }

        if showWireframes, let report {
          WireframeCalloutOverlay(violations: report.violations, theme: catbirdTheme)
            .allowsHitTesting(false)
        }

        InspectorHUDPanel(
          report: report,
          theme: catbirdTheme,
          reduceMotion: envReduceMotion,
          isExpanded: $isExpanded,
          showWireframes: $showWireframes,
          showGrid: $showGrid,
          onRescan: { self.runAudit() },
          onCopyJSON: { self.copyReportJSON() }
        )
      }
      .background(InspectorExclusionTagger())
      .task(id: auditTriggerKey) {
        try? await Task.sleep(for: .milliseconds(250))
        runAudit()
      }
    }
    #endif
  }

  private var auditTriggerKey: String {
    "\(surface)-\(resolvedProfile)-\(resolvedFontStyle)-\(resolvedAccent)-\(resolvedReduceTransparency)-\(colorScheme)"
  }

  private var resolvedProfile: String {
    if let profileOverride { return profileOverride }
    if let arg = argumentValue(flag: "-CatbirdProfile") { return arg }
    return "baseline-light"
  }

  private var resolvedFontStyle: String {
    if let fontStyleOverride { return fontStyleOverride }
    if let arg = argumentValue(flag: "-CatbirdFont") { return arg }
    return fontManager.fontStyle
  }

  private var resolvedAccent: String {
    if let accentColorOverride { return accentColorOverride }
    if let arg = argumentValue(flag: "-CatbirdAccent") { return arg }
    return themeManager?.currentAccentColor.rawValue ?? "default"
  }

  private var resolvedTheme: String {
    if let arg = argumentValue(flag: "-CatbirdTheme") { return arg }
    if colorScheme == .dark {
      return (themeManager?.isUsingTrueBlack ?? false) ? "black" : "dim"
    }
    return "light"
  }

  private var resolvedReduceTransparency: Bool {
    if let reduceTransparencyOverride { return reduceTransparencyOverride }
    if let arg = argumentValue(flag: "-CatbirdReduceTransparency") {
      return arg == "1" || arg.lowercased() == "true"
    }
    return envReduceTransparency
  }

  private func argumentValue(flag: String) -> String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
      return nil
    }
    return args[index + 1]
  }

  private func makeAuditContext() -> CatbirdDesignAuditContext {
    CatbirdDesignAuditContext(
      surface: surface,
      profile: resolvedProfile,
      theme: resolvedTheme,
      accent: resolvedAccent,
      fontStyle: resolvedFontStyle,
      dynamicType: String(describing: dynamicTypeSize),
      reduceTransparency: resolvedReduceTransparency,
      reduceMotion: envReduceMotion,
      highContrast: colorSchemeContrast == .increased
    )
  }

  private func runAudit() {
    #if os(iOS)
    guard let window = hostWindow ?? activeKeyWindow() else { return }
    let context = makeAuditContext()
    let image = context.expectsNoHardcodedBlue
      ? CatbirdDesignInspector.captureHierarchyImage(of: window, scale: 1)
      : nil
    report = CatbirdDesignInspector.audit(
      rootView: window,
      context: context,
      renderedImage: image
    )
    #endif
  }

  #if os(iOS)
  private func activeKeyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
  }

  private func copyReportJSON() {
    guard let report,
          let data = try? report.jsonData(prettyPrinted: true),
          let text = String(data: data, encoding: .utf8)
    else { return }
    UIPasteboard.general.string = text
  }
  #endif
}

// MARK: - HUD Panel & Wireframes (iOS)

#if os(iOS)
private func calloutColor(
  for category: CatbirdDesignAuditReport.Category,
  theme: CatbirdThemeColors
) -> Color {
  switch category {
  case .hitTarget, .a11yAudit:
    return theme.semantic(.danger)
  case .nonAppFont:
    return theme.semantic(.encryptionShield)
  case .accentLeak:
    return theme.semantic(.accent)
  case .cornerRadius, .reduceTransparency, .surfaceContrast:
    return theme.semantic(.warning)
  case .offGridSpacing:
    return theme.semantic(.info)
  }
}

private struct InspectorHUDPanel: View {
  let report: CatbirdDesignAuditReport?
  let theme: CatbirdThemeColors
  let reduceMotion: Bool
  @Binding var isExpanded: Bool
  @Binding var showWireframes: Bool
  @Binding var showGrid: Bool
  let onRescan: () -> Void
  let onCopyJSON: () -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: Space.sm) {
      Button {
        Motion.withAnimation(Motion.instant, reduceMotion: reduceMotion) {
          self.isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Space.xs) {
          Image(
            systemName: (report?.counts.total ?? 0) == 0
              ? "checkmark.shield.fill"
              : "exclamationmark.triangle.fill"
          )
          Text(verbatim: "QA \(report?.counts.total ?? 0)")
            .appFont(AppTextRole.caption)
        }
        .padding(.horizontal, Space.md)
        .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget)
        .foregroundStyle(theme.onAccent)
        .background(statusPillColor, in: Radius.capsule)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("catbird.designInspector.pill")

      if isExpanded {
        drawerContent
      }
    }
    .padding(.top, Space.lg)
    .padding(.trailing, Space.md)
  }

  private var statusPillColor: Color {
    guard let report else { return theme.semantic(.neutral) }
    if report.counts.total == 0 {
      return theme.semantic(.success)
    }
    let hasError = report.violations.contains { $0.severity == .error }
    return hasError ? theme.semantic(.danger) : theme.semantic(.warning)
  }

  private var drawerContent: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(spacing: Space.sm) {
        Text(verbatim: "Design Inspector")
          .appFont(AppTextRole.headline)
        Spacer()
        Button {
          self.onRescan()
        } label: {
          Image(systemName: "arrow.clockwise")
            .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget)
        }
        .accessibilityLabel(Text(verbatim: "Re-run design audit"))
      }

      HStack(spacing: Space.sm) {
        CatbirdChip(
          title: Text(verbatim: "Wireframes"),
          isSelected: showWireframes,
          size: .sm
        ) {
          self.showWireframes.toggle()
        }
        CatbirdChip(
          title: Text(verbatim: "4pt Grid"),
          isSelected: showGrid,
          size: .sm
        ) {
          self.showGrid.toggle()
        }
        CatbirdChip(
          title: Text(verbatim: "Copy JSON"),
          isSelected: false,
          size: .sm
        ) {
          self.onCopyJSON()
        }
      }

      violationList
    }
    .padding(Space.md)
    .frame(width: 300)
    .catbirdCard(.panel)
    .catbirdElevation(.floating)
    .accessibilityIdentifier("catbird.designInspector.drawer")
  }

  @ViewBuilder
  private var violationList: some View {
    if let report {
      if report.violations.isEmpty {
        Text(verbatim: "No design-system violations detected.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(theme.text(.secondary))
          .padding(.vertical, Space.sm)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(report.violations) { violation in
              VStack(alignment: .leading, spacing: Space.hairline) {
                HStack(spacing: Space.xs) {
                  Text(verbatim: violation.category.shortBadge)
                    .appFont(AppTextRole.caption2)
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.hairline)
                    .background(calloutColor(for: violation.category, theme: theme), in: Radius.xs.shape)
                  Text(verbatim: violation.identifier ?? violation.viewClass ?? "View")
                    .appFont(AppTextRole.caption)
                    .lineLimit(1)
                }
                Text(verbatim: violation.message)
                  .appFont(AppTextRole.caption2)
                  .foregroundStyle(theme.text(.secondary))
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(Space.sm)
              .catbirdCard(.panel)
            }
          }
        }
        .frame(maxHeight: 260)
      }
    }
  }
}

private struct WireframeCalloutOverlay: View {
  let violations: [CatbirdDesignAuditReport.Violation]
  let theme: CatbirdThemeColors

  var body: some View {
    GeometryReader { _ in
      ZStack(alignment: .topLeading) {
        ForEach(violations) { violation in
          if let rect = violation.frame?.cgRect, rect.width > 0, rect.height > 0 {
            let color = calloutColor(for: violation.category, theme: theme)
            ZStack(alignment: .topLeading) {
              if violation.category == .hitTarget {
                Rectangle()
                  .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                  .frame(
                    width: max(ControlHeight.minHitTarget, rect.width),
                    height: max(ControlHeight.minHitTarget, rect.height)
                  )
                  .position(x: rect.midX, y: rect.midY)
              }

              Rectangle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

              Text(verbatim: badgeLabel(for: violation))
                .appFont(AppTextRole.caption2)
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.hairline)
                .background(color, in: Radius.xs.shape)
                .position(
                  x: max(28, rect.minX + 24),
                  y: max(12, rect.minY - 8)
                )
            }
          }
        }
      }
    }
    .ignoresSafeArea()
  }

  private func badgeLabel(for violation: CatbirdDesignAuditReport.Violation) -> String {
    if violation.category == .hitTarget, let rect = violation.frame {
      return "\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
    }
    return violation.category.shortBadge
  }
}

private struct FourPointGridOverlay: View {
  let lineColor: Color

  var body: some View {
    Canvas { context, size in
      let step: CGFloat = Space.xs
      var path = Path()
      var colX: CGFloat = 0
      while colX <= size.width {
        path.move(to: CGPoint(x: colX, y: 0))
        path.addLine(to: CGPoint(x: colX, y: size.height))
        colX += step
      }
      var rowY: CGFloat = 0
      while rowY <= size.height {
        path.move(to: CGPoint(x: 0, y: rowY))
        path.addLine(to: CGPoint(x: size.width, y: rowY))
        rowY += step
      }
      context.stroke(path, with: .color(lineColor), lineWidth: 0.5)
    }
    .ignoresSafeArea()
  }
}

private struct InspectorWindowAnchor: UIViewRepresentable {
  let onResolve: @MainActor (UIWindow) -> Void

  func makeUIView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.tag = CatbirdDesignInspector.excludedOverlayTag
    view.onWindow = onResolve
    return view
  }

  func updateUIView(_ uiView: ProbeView, context: Context) {
    uiView.onWindow = onResolve
    if let window = uiView.window {
      let callback = onResolve
      Task { @MainActor in
        callback(window)
      }
    }
  }

  final class ProbeView: UIView {
    var onWindow: (@MainActor (UIWindow) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let window, let callback = onWindow {
        Task { @MainActor in
          callback(window)
        }
      }
    }
  }
}

private struct InspectorExclusionTagger: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView {
    let view = TaggerView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    uiView.superview?.tag = CatbirdDesignInspector.excludedOverlayTag
  }

  private final class TaggerView: UIView {
    override func didMoveToSuperview() {
      super.didMoveToSuperview()
      superview?.tag = CatbirdDesignInspector.excludedOverlayTag
    }
  }
}
#endif
#endif
