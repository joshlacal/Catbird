//
//  CatbirdKitGallery.swift
//  Catbird
//
//  DEBUG-only catalogue of every kit component. AppState-free.
//  Launch: `simctl launch <udid> blue.catbird -CatbirdKitGallery 1`
//

#if DEBUG
import SwiftUI

struct CatbirdKitGallery: View {
  @State private var fontManager: FontManager
  @State private var themeManager: ThemeManager
  @State private var chipSelected = true
  @State private var accent: AccentColorOption = .catbird
  @State private var loadingFollow = false
  /// `-CatbirdKitGalleryPage N` (1...3) shows one third of the catalogue so
  /// each page fits a screenshot; absent/0 shows everything.
  private let page = UserDefaults.standard.integer(forKey: "CatbirdKitGalleryPage")

  private func showsPage(_ n: Int) -> Bool { page == 0 || page == n }

  init() {
    let fm = FontManager()
    _fontManager = State(initialValue: fm)
    let tm = ThemeManager(fontManager: fm)
    // Same defaults the app boots with (system theme, dim dark mode), so kit
    // colours resolve the way they do in production.
    tm.applyTheme(theme: "system", darkThemeMode: "dim", accentColor: "default")
    _themeManager = State(initialValue: tm)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.x3l) {
          accentPicker
          if showsPage(1) { buttons; iconButtons; follow }
          if showsPage(2) { feedLibrary; chipsAndBadges; notices }
          if showsPage(3) { cards; radii; spacing; brandGradient }
        }
        .padding(Space.screenMargin)
      }
      .navigationTitle(Text(verbatim: "Kit Gallery"))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.large)
      #endif
    }
    .environment(\.fontManager, fontManager)
    .applyTheme(themeManager)
    .onChange(of: accent) { _, newValue in
      themeManager.applyTheme(theme: "system", darkThemeMode: "dim", accentColor: newValue.rawValue)
    }
  }

  private var accentPicker: some View {
    section("Accent") {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          ForEach(AccentColorOption.allCases) { option in
            CatbirdChip(
              title: Text(verbatim: option.rawValue), isSelected: accent == option
            ) { accent = option }
          }
        }
      }
    }
  }

  // MARK: - Sections

  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
    -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text(verbatim: title).appFont(AppTextRole.headline)
      content()
    }
  }

  private var buttons: some View {
    section("Buttons") {
      ForEach(CatbirdButtonKind.allCases, id: \.self) { kind in
        HStack {
          ForEach(CatbirdButtonSize.allCases, id: \.self) { size in
            Button {} label: { Text(verbatim: String(describing: kind)) }
              .buttonStyle(.catbird(kind, size: size))
          }
        }
      }
      Button {} label: { Text(verbatim: "Full width lg") }
        .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
      HStack {
        Button {} label: { Text(verbatim: "Loading") }
          .buttonStyle(.catbird(.primary, size: .md, isLoading: true))
        Button {} label: { Text(verbatim: "Disabled") }
          .buttonStyle(.catbird(.primary, size: .md)).disabled(true)
      }
    }
  }

  private var iconButtons: some View {
    section("Icon buttons") {
      HStack {
        ForEach(CatbirdButtonSize.allCases, id: \.self) { size in
          CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: size) {}
        }
        CatbirdIconButton(systemImage: "heart", label: Text(verbatim: "Like"), style: .quiet) {}
        CatbirdIconButton(systemImage: "bell", label: Text(verbatim: "Alerts"), style: .glass) {}
      }
    }
  }

  private var follow: some View {
    section("Follow") {
      ForEach(FollowButtonSize.allCases, id: \.self) { size in
        HStack {
          ForEach(FollowButtonState.allCases, id: \.self) { state in
            FollowButton(state: state, size: size) {}
          }
        }
      }
      HStack {
        FollowButton(state: .notFollowing, isLoading: true) {}
        FollowButton(state: .following, isLoading: true) {}
      }
    }
  }

  private var feedLibrary: some View {
    section("Feed library (visual)") {
      ForEach(FeedLibraryButtonSize.allCases, id: \.self) { size in
        HStack {
          FeedLibraryButtonLabel(membership: .absent, size: size)
          FeedLibraryButtonLabel(membership: .saved, size: size)
          FeedLibraryButtonLabel(membership: .pinned, size: size)
        }
      }
    }
  }

  private var chipsAndBadges: some View {
    section("Chips and badges") {
      HStack {
        CatbirdChip(title: Text(verbatim: "Selected"), isSelected: chipSelected) { chipSelected.toggle() }
        CatbirdChip(title: Text(verbatim: "Idle"), systemImage: "flame", action: {})
        CatbirdChip(title: Text(verbatim: "Small"), size: .sm)
      }
      HStack {
        ForEach(CatbirdBadgeTone.allCases, id: \.self) { tone in
          CatbirdBadge(Text(verbatim: String(describing: tone)), tone: tone)
        }
      }
    }
  }

  private var notices: some View {
    section("Notices") {
      CatbirdNotice(tone: .info, title: Text(verbatim: "Heads up"), message: Text(verbatim: "Informational message."))
      CatbirdNotice(tone: .warning, message: Text(verbatim: "Be careful."), actionTitle: Text(verbatim: "Review"), action: {})
      CatbirdNotice(tone: .error, title: Text(verbatim: "Failed"), message: Text(verbatim: "Something went wrong."))
      CatbirdNotice(tone: .success, message: Text(verbatim: "All done."))
    }
  }

  private var cards: some View {
    section("Cards") {
      CompactPostCard(
        avatarURL: nil, displayName: "Catbird", handle: "catbird.blue",
        text: "A compact post summary that clamps long text after three lines so list rows stay even and easy to scan.")
      Text(verbatim: "Panel").appFont(AppTextRole.body).padding(Space.lg).frame(maxWidth: .infinity, alignment: .leading)
        .catbirdCard(.panel)
    }
  }

  private var radii: some View {
    section("Radius") {
      HStack {
        ForEach(Radius.allCases, id: \.self) { radius in
          VStack {
            radius.shape.fill(Color.accentColor.opacity(0.3)).frame(width: 52, height: 52)
            Text(verbatim: "\(Int(radius.value))").appFont(AppTextRole.caption)
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
          Rectangle().fill(Color.accentColor).frame(width: step.1, height: 8)
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
}

#Preview("Kit gallery") {
  CatbirdKitGallery()
}
#endif
