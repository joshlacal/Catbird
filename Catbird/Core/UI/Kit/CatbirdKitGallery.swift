//
//  CatbirdKitGallery.swift
//  Catbird
//
//  DEBUG-only catalogue of every kit component, token, and Tier-1 primitive. AppState-free.
//  Launch standalone:
//    `simctl launch <udid> blue.catbird -CatbirdKitGallery 1`
//  Optional launch args (standalone mode):
//    -CatbirdKitGalleryPage 1..4
//    -CatbirdTheme light|dim|black
//    -CatbirdAccent catbird|twilight|lavender|sunrise|aurora|dusk|midnight
//    -CatbirdFont system|serif|rounded|monospaced
//    -CatbirdFontSize small|default|large|extraLarge
//    -CatbirdReduceTransparency 0|1
//

#if DEBUG
import SwiftUI

struct CatbirdKitGallery: View {
  enum ThemeOption: String, CaseIterable, Identifiable {
    case light, dim, black

    var id: String { rawValue }

    var label: String {
      switch self {
      case .light: return "Light"
      case .dim: return "Dim"
      case .black: return "True Black"
      }
    }

    var themeArg: String { self == .light ? "light" : "dark" }
    var darkModeArg: String { self == .black ? "black" : "dim" }
  }

  private let injectedThemeManager: ThemeManager?
  private let injectedFontManager: FontManager?
  private let showsControls: Bool
  private let embedInNavigationStack: Bool

  @Environment(\.themeManager) private var envThemeManager

  @State private var ownedFontManager: FontManager
  @State private var ownedThemeManager: ThemeManager
  @State private var themeOption: ThemeOption
  @State private var accent: AccentColorOption
  @State private var fontStyle: String
  @State private var fontSize: String
  @State private var simulateReduceTransparency: Bool

  /// `-CatbirdKitGalleryPage N` (1...4) shows one quarter of the catalogue so
  /// each page fits a screenshot; absent/0 shows everything.
  private let page = UserDefaults.standard.integer(forKey: "CatbirdKitGalleryPage")

  init(
    themeManager: ThemeManager? = nil,
    fontManager: FontManager? = nil,
    showsControls: Bool = true,
    embedInNavigationStack: Bool = true
  ) {
    self.injectedThemeManager = themeManager
    self.injectedFontManager = fontManager
    self.showsControls = showsControls
    self.embedInNavigationStack = embedInNavigationStack

    let defaults = UserDefaults.standard
    let rawTheme = defaults.string(forKey: "CatbirdTheme")?.lowercased() ?? "dim"
    let initialTheme: ThemeOption = ThemeOption(rawValue: rawTheme) ?? .dim
    let rawAccent = defaults.string(forKey: "CatbirdAccent")?.lowercased() ?? "default"
    let normalizedAccent = rawAccent == "catbird" ? "default" : rawAccent
    let initialAccent = AccentColorOption(rawValue: normalizedAccent) ?? .catbird
    let initialFontStyle = defaults.string(forKey: "CatbirdFont") ?? "system"
    let initialFontSize = defaults.string(forKey: "CatbirdFontSize") ?? "default"
    let initialReduceTransparency = defaults.bool(forKey: "CatbirdReduceTransparency")

    let fm = fontManager ?? FontManager()
    if fontManager == nil {
      fm.applyFontSettings(
        fontStyle: initialFontStyle,
        fontSize: initialFontSize,
        lineSpacing: "normal",
        letterSpacing: "normal",
        dynamicTypeEnabled: true,
        maxDynamicTypeSize: "accessibility3"
      )
    }
    let tm = themeManager ?? ThemeManager(fontManager: fm)
    if themeManager == nil {
      tm.applyTheme(
        theme: initialTheme.themeArg,
        darkThemeMode: initialTheme.darkModeArg,
        accentColor: initialAccent.rawValue
      )
    }

    _ownedFontManager = State(initialValue: fm)
    _ownedThemeManager = State(initialValue: tm)
    _themeOption = State(initialValue: initialTheme)
    _accent = State(initialValue: initialAccent)
    _fontStyle = State(initialValue: initialFontStyle)
    _fontSize = State(initialValue: initialFontSize)
    _simulateReduceTransparency = State(initialValue: initialReduceTransparency)
  }

  /// True when hosted inside `CatbirdCatalogHost` (parent owns environment managers).
  private var isHostedExternally: Bool {
    injectedThemeManager != nil || envThemeManager != nil
  }

  var body: some View {
    let content = CatbirdKitGalleryContent(
      page: page,
      showsControls: showsControls && !isHostedExternally,
      embedInNavigationStack: embedInNavigationStack,
      themeOption: $themeOption,
      accent: $accent,
      fontStyle: $fontStyle,
      fontSize: $fontSize,
      simulateReduceTransparency: $simulateReduceTransparency
    )

    if let injectedThemeManager {
      content
        .modifier(OptionalFontManagerModifier(fontManager: injectedFontManager))
        .applyTheme(injectedThemeManager)
    } else if envThemeManager != nil {
      content
        .modifier(OptionalFontManagerModifier(fontManager: injectedFontManager))
    } else {
      content
        .environment(\.fontManager, ownedFontManager)
        .applyTheme(ownedThemeManager)
        .onChange(of: themeOption) { _, _ in self.applyOwnedSettings() }
        .onChange(of: accent) { _, _ in self.applyOwnedSettings() }
        .onChange(of: fontStyle) { _, _ in self.applyOwnedFontSettings() }
        .onChange(of: fontSize) { _, _ in self.applyOwnedFontSettings() }
    }
  }

  private func applyOwnedSettings() {
    ownedThemeManager.applyTheme(
      theme: themeOption.themeArg,
      darkThemeMode: themeOption.darkModeArg,
      accentColor: accent.rawValue
    )
  }

  private func applyOwnedFontSettings() {
    ownedFontManager.applyFontSettings(
      fontStyle: fontStyle,
      fontSize: fontSize,
      lineSpacing: "normal",
      letterSpacing: "normal",
      dynamicTypeEnabled: true,
      maxDynamicTypeSize: "accessibility3"
    )
  }
}

private struct OptionalFontManagerModifier: ViewModifier {
  let fontManager: FontManager?

  @ViewBuilder func body(content: Content) -> some View {
    if let fontManager {
      content.environment(\.fontManager, fontManager)
    } else {
      content
    }
  }
}

/// Separate child view so `@Environment(\.catbirdTheme)` always reads the theme
/// injected by `CatbirdKitGallery` (standalone) or `CatbirdCatalogHost` (hosted).
private struct CatbirdKitGalleryContent: View {
  let page: Int
  let showsControls: Bool
  let embedInNavigationStack: Bool

  @Binding var themeOption: CatbirdKitGallery.ThemeOption
  @Binding var accent: AccentColorOption
  @Binding var fontStyle: String
  @Binding var fontSize: String
  @Binding var simulateReduceTransparency: Bool

  @Environment(\.catbirdTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

  @State private var chipSelected = true
  @State private var sampleText = "catbird.blue"
  @State private var errorText = "bad handle"
  @State private var searchQuery = ""
  @State private var showsSheetSample = false

  private func showsPage(_ n: Int) -> Bool { page == 0 || page == n }

  var body: some View {
    if embedInNavigationStack {
      NavigationStack {
        galleryScroll
          .navigationTitle(Text(verbatim: "Kit Gallery"))
          .modifier(GalleryNavTitleModeModifier())
      }
    } else {
      galleryScroll
    }
  }

  private var galleryScroll: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Space.x3l) {
        if showsControls {
          controlsSection
        }
        if showsPage(1) {
          typographySection
          buttons
          iconButtons
          follow
        }
        if showsPage(2) {
          feedLibrary
          chipsAndBadges
          notices
          textFieldsSection
        }
        if showsPage(3) {
          avatarsSection
          headersAndHairlinesSection
          cards
          elevationSection
        }
        if showsPage(4) {
          iconsSection
          glassSection
          spinnerSection
          radii
          spacing
          brandGradient
          sheetSection
        }
      }
      .padding(Space.screenMargin)
      .containerRelativeFrame(.horizontal, alignment: .leading)
    }
    .background(theme.surface(.canvas))
    .sheet(isPresented: $showsSheetSample) {
      NavigationStack {
        VStack(alignment: .leading, spacing: Space.md) {
          CatbirdSectionHeader(
            "Sheet Chrome Sample",
            subtitle: "Themed canvas, detents, and Cancel/Done placement."
          )
          CatbirdNotice(
            tone: .info,
            message: Text(verbatim: "Consistent sheet presentation via .catbirdSheetChrome.")
          )
          Spacer()
        }
        .padding(Space.screenMargin)
        .navigationTitle(Text(verbatim: "Sheet Preview"))
        .catbirdSheetToolbar(
          onCancel: { self.showsSheetSample = false },
          confirmTitle: "Done",
          onConfirm: { self.showsSheetSample = false }
        )
      }
      .catbirdSheetChrome(detents: [.medium, .large])
    }
  }

  // MARK: - Interactive Controls

  private var controlsSection: some View {
    section("Environment Controls") {
      VStack(alignment: .leading, spacing: Space.md) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Space.sm) {
            ForEach(CatbirdKitGallery.ThemeOption.allCases) { option in
              CatbirdChip(
                title: Text(verbatim: option.label),
                isSelected: themeOption == option,
                size: .sm
              ) {
                self.themeOption = option
              }
            }
          }
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Space.sm) {
            ForEach(AccentColorOption.allCases) { option in
              CatbirdChip(
                title: Text(verbatim: option.displayName),
                isSelected: accent == option,
                size: .sm
              ) {
                self.accent = option
              }
            }
          }
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Space.sm) {
            ForEach(["system", "serif", "rounded", "monospaced"], id: \.self) { style in
              CatbirdChip(
                title: Text(verbatim: style.capitalized),
                isSelected: fontStyle == style,
                size: .sm
              ) {
                self.fontStyle = style
              }
            }
          }
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Space.sm) {
            ForEach(["small", "default", "large", "extraLarge"], id: \.self) { size in
              CatbirdChip(
                title: Text(verbatim: size),
                isSelected: fontSize == size,
                size: .sm
              ) {
                self.fontSize = size
              }
            }
          }
        }
        Toggle(isOn: $simulateReduceTransparency) {
          Text(
            verbatim: "Reduce Transparency: \(systemReduceTransparency || simulateReduceTransparency ? "ON" : "OFF")"
          )
          .appFont(AppTextRole.footnote)
        }
      }
      .padding(Space.md)
      .catbirdCard(.panel)
    }
  }

  // MARK: - Sections

  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      CatbirdSectionHeader(title: Text(verbatim: title), style: .prominent)
      content()
    }
  }

  private var typographySection: some View {
    section("Typography") {
      VStack(alignment: .leading, spacing: Space.sm) {
        Text(verbatim: "Display 125% · 800").appFont(AppTextRole.display)
        Text(verbatim: "Title 1 · Bold").appFont(AppTextRole.title1)
        Text(verbatim: "Headline · Semibold").appFont(AppTextRole.headline)
        Text(verbatim: "Subheadline · Weight Override (.semibold)")
          .appFont(AppTextRole.subheadline.weight(.semibold))
        Text(verbatim: "Body · Regular copy scales cleanly").appFont(AppTextRole.body)
        Text(verbatim: "Monospaced · did:plc:catbird").appFont(AppTextRole.footnote.monospaced())
        Text(verbatim: "Tabular digits · 12,345 · 98.7%").appFont(AppTextRole.caption.monospacedDigits())
      }
      .foregroundStyle(theme.text(.primary))
      .padding(Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .catbirdCard(.panel)
    }
  }

  private var buttons: some View {
    section("Buttons") {
      ForEach(CatbirdButtonKind.allCases, id: \.self) { kind in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(CatbirdButtonSize.allCases, id: \.self) { size in
              Button {} label: { Text(verbatim: String(describing: kind)) }
                .buttonStyle(.catbird(kind, size: size))
            }
          }
        }
      }
      Button {} label: { Text(verbatim: "Full width lg") }
        .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          Button {} label: { Text(verbatim: "Loading") }
            .buttonStyle(.catbird(.primary, size: .md, isLoading: true))
          Button {} label: { Text(verbatim: "Disabled") }
            .buttonStyle(.catbird(.primary, size: .md)).disabled(true)
        }
      }
    }
  }

  private var iconButtons: some View {
    section("Icon buttons") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          ForEach(CatbirdButtonSize.allCases, id: \.self) { size in
            CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: size) {}
          }
          CatbirdIconButton(systemImage: "heart", label: Text(verbatim: "Like"), style: .quiet) {}
          CatbirdIconButton(systemImage: "bell", label: Text(verbatim: "Alerts"), style: .glass) {}
        }
      }
    }
  }

  private var follow: some View {
    section("Follow") {
      ForEach(FollowButtonSize.allCases, id: \.self) { size in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(FollowButtonState.allCases, id: \.self) { state in
              FollowButton(state: state, size: size) {}
            }
          }
        }
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          FollowButton(state: .notFollowing, isLoading: true) {}
          FollowButton(state: .following, isLoading: true) {}
        }
      }
    }
  }

  private var feedLibrary: some View {
    section("Feed library (visual)") {
      ForEach(FeedLibraryButtonSize.allCases, id: \.self) { size in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            FeedLibraryButtonLabel(membership: .absent, size: size)
            FeedLibraryButtonLabel(membership: .saved, size: size)
            FeedLibraryButtonLabel(membership: .pinned, size: size)
          }
        }
      }
    }
  }

  private var chipsAndBadges: some View {
    section("Chips and badges") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          CatbirdChip(title: Text(verbatim: "Selected"), isSelected: chipSelected) {
            self.chipSelected.toggle()
          }
          CatbirdChip(title: Text(verbatim: "Idle"), systemImage: "flame", action: {})
          CatbirdChip(title: Text(verbatim: "Small"), size: .sm)
        }
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          ForEach(CatbirdTone.allCases, id: \.self) { tone in
            CatbirdBadge(Text(verbatim: String(describing: tone)), tone: tone)
          }
        }
      }
    }
  }

  private var notices: some View {
    section("Notices") {
      CatbirdNotice(
        tone: .info,
        title: Text(verbatim: "Heads up"),
        message: Text(verbatim: "Informational message.")
      )
      CatbirdNotice(
        tone: .warning,
        message: Text(verbatim: "Be careful."),
        actionTitle: Text(verbatim: "Review"),
        action: {}
      )
      CatbirdNotice(
        tone: .error,
        title: Text(verbatim: "Failed"),
        message: Text(verbatim: "Something went wrong.")
      )
      CatbirdNotice(tone: .success, message: Text(verbatim: "All done."))
    }
  }

  private var textFieldsSection: some View {
    section("Text fields") {
      CatbirdTextField(text: $sampleText, prompt: "Handle", leadingSystemImage: "at")
      CatbirdTextField(
        text: $errorText,
        prompt: "Handle",
        leadingSystemImage: "at",
        validationError: "Must be a valid domain handle."
      )
      CatbirdSearchField(text: $searchQuery, prompt: "Search feeds", onCancel: { self.searchQuery = "" })
    }
  }

  private var avatarsSection: some View {
    section("Avatars") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Space.md) {
          CatbirdAvatar(url: nil, displayName: "Alice", size: AvatarSize.xs)
          CatbirdAvatar(url: nil, displayName: "Bob", size: AvatarSize.sm)
          CatbirdAvatar(url: nil, displayName: "Catbird", size: AvatarSize.md)
          CatbirdAvatar(url: nil, displayName: "Dana", size: AvatarSize.lg)
          CatbirdAvatar(url: nil, displayName: "Eve", size: AvatarSize.xl, shape: .squircle(.md))
        }
      }
    }
  }

  private var headersAndHairlinesSection: some View {
    section("Section headers & hairlines") {
      VStack(alignment: .leading, spacing: Space.sm) {
        CatbirdSectionHeader("Grouped Section", subtitle: "Subtitle metadata", actionTitle: "Action") {}
        CatbirdHairline(extent: .fullWidth)
        CatbirdHairline(extent: .contentInset())
        CatbirdHairline(extent: .leadingInset(AvatarSize.lg + Space.md))
      }
      .padding(Space.md)
      .catbirdCard(.panel)
    }
  }

  private var cards: some View {
    section("Cards") {
      CompactPostCard(
        avatarURL: nil,
        displayName: "Catbird",
        handle: "catbird.blue",
        text: "A compact post summary that clamps long text after three lines so list rows stay even and easy to scan."
      )
      Text(verbatim: "Panel")
        .appFont(AppTextRole.body)
        .foregroundStyle(theme.text(.primary))
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .catbirdCard(.panel)
    }
  }

  private var elevationSection: some View {
    section("Elevation") {
      HStack(spacing: Space.md) {
        ForEach(Elevation.allCases, id: \.self) { level in
          Text(verbatim: String(describing: level))
            .appFont(AppTextRole.caption)
            .foregroundStyle(theme.text(.primary))
            .padding(Space.md)
            .frame(maxWidth: .infinity)
            .background(theme.surface(.elevated), in: Radius.md.shape)
            .catbirdElevation(level)
        }
      }
    }
  }

  private var iconsSection: some View {
    section("Icon scale") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Space.lg) {
          ForEach(CatbirdSymbolRole.allCases, id: \.self) { role in
            VStack(spacing: Space.xs) {
              Image(systemName: "sparkles").catbirdSymbol(role)
              Text(verbatim: "\(Int(role.pointSize))")
                .appFont(AppTextRole.caption2)
                .foregroundStyle(theme.text(.secondary))
            }
          }
        }
      }
    }
  }

  private var glassSection: some View {
    section("Liquid Glass (.catbirdGlass)") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Space.md) {
          Text(verbatim: "Regular")
            .appFont(AppTextRole.footnote.weight(.semibold))
            .foregroundStyle(theme.text(.primary))
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .catbirdGlass(.regular, in: Capsule(style: .continuous), interactive: true)
          Text(verbatim: "Clear Tinted")
            .appFont(AppTextRole.footnote.weight(.semibold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .catbirdGlass(.clear, in: Capsule(style: .continuous), interactive: true, tinted: true)
          Text(verbatim: "Prominent")
            .appFont(AppTextRole.footnote.weight(.semibold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .catbirdGlass(.prominent, in: Capsule(style: .continuous), interactive: true, tinted: true)
        }
        .padding(Space.lg)
      }
      .frame(maxWidth: .infinity)
      .background(BrandGradientFill().catbirdClip(.lg))
    }
  }

  private var spinnerSection: some View {
    section("Mascot Spinner") {
      HStack(spacing: Space.lg) {
        BirdSpinner(size: AvatarSize.xl)
        Text(verbatim: "Tactile 3D BirdSpinner (drag to spin · tap to bounce)")
          .appFont(AppTextRole.footnote)
          .foregroundStyle(theme.text(.secondary))
      }
      .padding(Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .catbirdCard(.panel)
    }
  }

  private var radii: some View {
    section("Radius") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          ForEach(Radius.allCases, id: \.self) { radius in
            VStack {
              radius.shape.fill(theme.accentChrome.opacity(0.3)).frame(width: 52, height: 52)
              Text(verbatim: "\(Int(radius.value))").appFont(AppTextRole.caption)
            }
          }
        }
      }
    }
  }

  private var spacing: some View {
    section("Space") {
      let steps: [(String, CGFloat)] = [
        ("2", Space.hairline), ("4", Space.xs), ("8", Space.sm), ("12", Space.md),
        ("16", Space.lg), ("24", Space.xxl), ("32", Space.x3l), ("48", Space.x5l)
      ]
      ForEach(steps, id: \.0) { step in
        HStack {
          Text(verbatim: step.0).appFont(AppTextRole.caption).frame(width: 24, alignment: .trailing)
          Rectangle().fill(theme.accentChrome).frame(width: step.1, height: 8)
        }
      }
    }
  }

  private var brandGradient: some View {
    section("Brand gradient") {
      BrandGradientFill().frame(height: 56).catbirdClip(.md)
      Button {} label: { Text(verbatim: "Brand gradient button") }
        .buttonStyle(.catbird(.brand, size: .lg, fullWidth: true))
    }
  }

  private var sheetSection: some View {
    section("Sheet Chrome") {
      Button("Preview Sheet Chrome") {
        self.showsSheetSample = true
      }
      .buttonStyle(.catbird(.tonal, size: .md))
    }
  }
}

private struct GalleryNavTitleModeModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.navigationBarTitleDisplayMode(.large)
    #else
    content
    #endif
  }
}

#Preview("Kit gallery") {
  CatbirdKitGallery()
}
#endif
