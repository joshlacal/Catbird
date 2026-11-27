//
//  CatbirdCatalogHost.swift
//  Catbird
//
//  DEBUG-only root view for `-CatbirdCatalog`. Hosts Tier A (`kit`) and
//  Tier B (11 mocked offline production surfaces) with a single-launch
//  in-app switcher, `blue.catbird://catalog?...` deep-link routing, trait
//  overrides, and `.catbirdDesignInspector(...)` integration.
//

#if DEBUG
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Root DEBUG container launched via `-CatbirdCatalog <surface|all>`.
@MainActor
struct CatbirdCatalogHost: View {
  @State private var config: CatbirdCatalogLaunchConfig
  @State private var session: CatbirdCatalogSession?
  @State private var failureMessage: String?
  @State private var showingSwitcher = false

  init(config: CatbirdCatalogLaunchConfig = .fromProcessArguments()) {
    _config = State(initialValue: config)
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let session {
          CatbirdCatalogSurfaceView(
            surface: config.surface,
            config: config,
            session: session
          )
          .id("\(config.surface.rawValue)-\(config.profile.rawValue)-\(config.theme)-\(config.darkThemeMode)-\(config.accentColor)-\(config.fontStyle)-\(config.fontSize)-\(config.lineSpacing)-\(config.reduceTransparency)")
          .catbirdDesignInspector(
            enabled: config.inspectorEnabled,
            profile: config.profile.rawValue,
            fontStyle: config.fontStyle,
            accentColor: config.accentColor,
            reduceTransparency: config.reduceTransparency
          )
        } else if let failureMessage {
          VStack(spacing: Space.md) {
            CatbirdNotice(
              tone: .error,
              title: Text(verbatim: "Catalog bootstrap failed"),
              message: Text(verbatim: failureMessage)
            )
          }
          .padding(Space.screenMargin)
          .accessibilityIdentifier("catalog.error")
        } else {
          ProgressView {
            Text(verbatim: "Preparing offline catalog…")
          }
          .accessibilityIdentifier("catalog.loading")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if session != nil && !config.hideChrome {
        Button {
          showingSwitcher = true
        } label: {
          Image(systemName: "square.grid.2x2")
            .appFont(AppTextRole.body)
            .frame(width: ControlHeight.minHitTarget, height: ControlHeight.minHitTarget)
        }
        .buttonStyle(.catbird(.tonal, size: .sm))
        .padding(.top, Space.xs)
        .padding(.trailing, Space.md)
        .accessibilityLabel(Text(verbatim: "Catalog Switcher"))
        .accessibilityIdentifier("catalog.switcher.open")
      }
    }
    .overlay(alignment: .topLeading) {
      if session != nil {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(verbatim: "\(config.surface.rawValue):\(config.profile.rawValue)"))
          .accessibilityIdentifier("catalog.ready.\(config.surface.rawValue).\(config.profile.rawValue)")
      }
    }
    .background {
      #if os(iOS)
      CatalogTraitOverrideBridge(config: config)
        .frame(width: 0, height: 0)
      #endif
    }
    .sheet(isPresented: $showingSwitcher) {
      CatbirdCatalogSwitcherSheet(
        config: $config,
        onConfigChanged: { updated in
          applyUpdatedConfig(updated)
        }
      )
    }
    .task {
      await bootstrapIfNeeded()
    }
    .onOpenURL { url in
      handleCatalogURL(url)
    }
    .onReceive(NotificationCenter.default.publisher(for: .catbirdCatalogRouteChanged)) { note in
      if let url = note.object as? URL {
        handleCatalogURL(url)
      }
    }
    .onDisappear {
      #if os(iOS)
      FontManager.overrideContentSizeCategory = nil
      #endif
      session?.cleanup()
    }
  }

  private func bootstrapIfNeeded() async {
    guard session == nil else { return }
    do {
      session = try await CatbirdCatalogEnvironment.makeSession(for: config, strictOffline: true)
    } catch {
      failureMessage = error.localizedDescription
    }
  }

  private func handleCatalogURL(_ url: URL) {
    guard let updated = config.applying(catalogURL: url) else { return }
    applyUpdatedConfig(updated)
  }

  private func applyUpdatedConfig(_ updated: CatbirdCatalogLaunchConfig) {
    config = updated
    session?.apply(config: updated)
  }
}

// MARK: - Single-Launch In-App Switcher Sheet

private struct CatbirdCatalogSwitcherSheet: View {
  @Binding var config: CatbirdCatalogLaunchConfig
  let onConfigChanged: (CatbirdCatalogLaunchConfig) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.xl) {
          VStack(alignment: .leading, spacing: Space.sm) {
            Text(verbatim: "Trap Profile")
              .appFont(AppTextRole.headline)

            ForEach(CatbirdTrapProfile.allCases) { profile in
              Button {
                let updated = config.applying(profile: profile)
                onConfigChanged(updated)
                dismiss()
              } label: {
                HStack {
                  Text(verbatim: profile.displayName)
                    .appFont(AppTextRole.subheadline)
                  Spacer()
                  if config.profile == profile {
                    Image(systemName: "checkmark")
                      .appFont(AppTextRole.subheadline)
                  }
                }
                .frame(maxWidth: .infinity, minHeight: ControlHeight.minHitTarget, alignment: .leading)
              }
              .buttonStyle(.catbird(config.profile == profile ? .primary : .tonal, size: .md, fullWidth: true))
              .accessibilityIdentifier("catalog.profile.\(profile.rawValue)")
            }
          }

          VStack(alignment: .leading, spacing: Space.sm) {
            Text(verbatim: "Surface")
              .appFont(AppTextRole.headline)

            ForEach(CatbirdCatalogSurface.allCases) { surface in
              Button {
                var updated = config
                updated.surface = surface
                onConfigChanged(updated)
                dismiss()
              } label: {
                HStack {
                  Text(verbatim: surface.displayName)
                    .appFont(AppTextRole.subheadline)
                  Spacer()
                  if config.surface == surface {
                    Image(systemName: "checkmark")
                      .appFont(AppTextRole.subheadline)
                  }
                }
                .frame(maxWidth: .infinity, minHeight: ControlHeight.minHitTarget, alignment: .leading)
              }
              .buttonStyle(.catbird(config.surface == surface ? .primary : .outline, size: .md, fullWidth: true))
              .accessibilityIdentifier("catalog.surface.\(surface.rawValue)")
            }
          }

          Toggle(
            isOn: Binding(
              get: { config.inspectorEnabled },
              set: { enabled in
                var updated = config
                updated.inspectorEnabled = enabled
                onConfigChanged(updated)
              }
            )
          ) {
            Text(verbatim: "Neurotic Design Inspector HUD")
              .appFont(AppTextRole.subheadline)
          }
          .frame(minHeight: ControlHeight.minHitTarget)
          .accessibilityIdentifier("catalog.inspector.toggle")
        }
        .padding(Space.screenMargin)
      }
      .navigationTitle(Text(verbatim: "Catbird Catalog"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Text(verbatim: "Done")
          }
          .accessibilityIdentifier("catalog.switcher.close")
        }
      }
    }
    .accessibilityIdentifier("catalog.switcher.sheet")
  }
}

// MARK: - iOS Trait Override Bridge

#if os(iOS)
/// Propagates deterministic UIKit trait overrides (`userInterfaceStyle`,
/// `accessibilityContrast`, `legibilityWeight`, `preferredContentSizeCategory`)
/// to the hosting view controller so both SwiftUI and UIKit surfaces reflect
/// the active `CatbirdTrapProfile`.
private struct CatalogTraitOverrideBridge: UIViewControllerRepresentable {
  let config: CatbirdCatalogLaunchConfig

  func makeUIViewController(context: Context) -> TraitBridgeController {
    TraitBridgeController()
  }

  func updateUIViewController(_ uiViewController: TraitBridgeController, context: Context) {
    uiViewController.apply(config: config)
  }

  final class TraitBridgeController: UIViewController {
    func apply(config: CatbirdCatalogLaunchConfig) {
      guard let target = parent else { return }
      if #available(iOS 17.0, *) {
        if let scheme = config.preferredColorScheme {
          target.traitOverrides.userInterfaceStyle = scheme == .dark ? .dark : .light
        } else {
          target.traitOverrides.remove(UITraitUserInterfaceStyle.self)
        }
        target.traitOverrides.accessibilityContrast = config.increaseContrast ? .high : .normal
        target.traitOverrides.legibilityWeight = config.boldText ? .bold : .regular
        target.traitOverrides.preferredContentSizeCategory = config.uiContentSizeCategory
      }
    }
  }
}
#endif
#endif
