import SwiftUI

struct SearchBarView: View {
  @Binding var searchText: String
  var onSearchChange: () async -> Void
  let placeholder: String
  let intensity: SolariumDesignSystem.GlassIntensity
  let autoFocus: Bool
  
  @FocusState private var isTextFieldFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(AppState.self) private var appState
  
  init(
    searchText: Binding<String>,
    placeholder: String = "Search feeds...",
    intensity: SolariumDesignSystem.GlassIntensity = .medium,
    autoFocus: Bool = false,
    onSearchChange: @escaping () async -> Void
  ) {
    self._searchText = searchText
    self.placeholder = placeholder
    self.intensity = intensity
    self.autoFocus = autoFocus
    self.onSearchChange = onSearchChange
  }

  var body: some View {
    HStack(spacing: 12) {
      // Enhanced search icon with glass treatment
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
        .appFont(size: 16)
        .solariumText(intensity: intensity)

      // Enhanced text field
      TextField(placeholder, text: $searchText)
        .focused($isTextFieldFocused)
        .appFont(size: 16)
        .foregroundColor(.primary)
        .solariumText(intensity: intensity)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: searchText) { _, _ in
          Task { await onSearchChange() }
        }
        .onAppear {
          if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
              isTextFieldFocused = true
            }
          }
        }

      // Enhanced clear button with glass treatment
      if !searchText.isEmpty {
        Button {
          MotionManager.withAnimation(for: appState.appSettings, animation: .easeInOut(duration: 0.2)) {
            searchText = ""
            Task { await onSearchChange() }
          }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
            .appFont(size: 16)
            .solariumText(intensity: intensity)
        }
        .motionAwareTransition(.scale.combined(with: .opacity), appSettings: appState.appSettings)
        .interactiveGlass()
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .solariumOverlay(intensity: intensity)
    .interactiveGlass()
    .motionAwareAnimation(.easeInOut(duration: 0.2), value: searchText.isEmpty, appSettings: appState.appSettings)
    .padding(.bottom, 8)
  }
}

// MARK: - Enhanced Search Bar Variants for Different Contexts

extension SearchBarView {
  
  /// Navigation-style glass search bar
  static func navigation(
    searchText: Binding<String>,
    placeholder: String = "Search...",
    onSearchChange: @escaping () async -> Void
  ) -> some View {
    SearchBarView(
      searchText: searchText,
      placeholder: placeholder,
      intensity: .medium,
      autoFocus: false,
      onSearchChange: onSearchChange
    )
    .solariumNavigation()
  }
  
  /// Floating search bar for overlays and modals
  static func floating(
    searchText: Binding<String>,
    placeholder: String = "Search...",
    autoFocus: Bool = true,
    onSearchChange: @escaping () async -> Void
  ) -> some View {
    SearchBarView(
      searchText: searchText,
      placeholder: placeholder,
      intensity: .strong,
      autoFocus: autoFocus,
      onSearchChange: onSearchChange
    )
    .solariumShimmer(intensity: 0.1)
  }
  
  /// Subtle search bar for embedded contexts like feeds page
  static func embedded(
    searchText: Binding<String>,
    placeholder: String = "Search feeds...",
    onSearchChange: @escaping () async -> Void
  ) -> some View {
    SearchBarView(
      searchText: searchText,
      placeholder: placeholder,
      intensity: .subtle,
      autoFocus: false,
      onSearchChange: onSearchChange
    )
  }
  
  /// Dramatic search bar for primary search experiences
  static func primary(
    searchText: Binding<String>,
    placeholder: String = "Search...",
    autoFocus: Bool = true,
    onSearchChange: @escaping () async -> Void
  ) -> some View {
    SearchBarView(
      searchText: searchText,
      placeholder: placeholder,
      intensity: .dramatic,
      autoFocus: autoFocus,
      onSearchChange: onSearchChange
    )
    .solariumShimmer(intensity: 0.2, angle: 45)
  }
}
