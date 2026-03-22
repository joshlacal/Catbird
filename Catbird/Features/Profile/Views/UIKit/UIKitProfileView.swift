import SwiftUI
import UIKit
import Petrel
import os

// MARK: - ProfileInfoView
// Thin SwiftUI wrapper around ProfileHeader, hosted inside ProfileViewController via UIHostingController.

struct ProfileInfoView: View {
  let profile: AppBskyActorDefs.ProfileViewDetailed
  let viewModel: ProfileViewModel
  let appState: AppState
  @Binding var isEditingProfile: Bool
  @Binding var path: NavigationPath

  var body: some View {
    ProfileHeader(
      profile: profile,
      viewModel: viewModel,
      appState: appState,
      isEditingProfile: $isEditingProfile,
      path: $path, screenWidth: UIScreen.main.bounds.width - 32,
      hideAvatar: false
    )
    .padding(.horizontal, 16)
  }
}

// MARK: - UIViewControllerRepresentable

@available(iOS 18.0, *)
struct UIKitProfileRepresentable: UIViewControllerRepresentable {
  let appState: AppState
  let viewModel: ProfileViewModel
  @Binding var isEditingProfile: Bool
  @Binding var navigationPath: NavigationPath

  func makeUIViewController(context: Context) -> ProfileViewController {
    ProfileViewController(
      appState: appState,
      viewModel: viewModel,
      isEditingProfile: $isEditingProfile,
      navigationPath: $navigationPath
    )
  }

  func updateUIViewController(_ vc: ProfileViewController, context: Context) {
    // ProfileViewController observes viewModel internally
  }
}

// MARK: - UIKitProfileContentView
// Full SwiftUI wrapper. Hosts the UIKit profile content plus all sheets, alerts, toolbar, and navigation.

@available(iOS 18.0, *)
struct UIKitProfileContentView: View {
  let viewModel: ProfileViewModel
  let appState: AppState
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding var path: NavigationPath

  @State private var isEditingProfile = false
  @State private var isShowingReportSheet = false
  @State private var isShowingAccountSwitcher = false
  @State private var isShowingBlockConfirmation = false
  @State private var isShowingAddToListSheet = false
  @State private var isBlocking = false
  @State private var isMuting = false
  @State private var profileForAddToList: AppBskyActorDefs.ProfileViewDetailed?

  private let logger = Logger(subsystem: "blue.catbird", category: "UIKitProfileContentView")

  var body: some View {
    UIKitProfileRepresentable(
      appState: appState,
      viewModel: viewModel,
      isEditingProfile: $isEditingProfile,
      navigationPath: $path
    )
    .ignoresSafeArea()
  }
}

// MARK: - Modifier Extensions on UIKitProfileContentView
// All sheets, alerts, toolbar, and navigation destinations are applied in UnifiedProfileView
// via the profileViewConfiguration wrapper so they remain in the SwiftUI host.
