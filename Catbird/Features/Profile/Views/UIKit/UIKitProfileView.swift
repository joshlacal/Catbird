import SwiftUI
import UIKit
import Nuke
import NukeUI
import Petrel
import os

/// SwiftUI wrapper for the UIKit profile view implementation
@available(iOS 18.0, *)
struct UIKitProfileView: View {
  @Environment(AppState.self) private var appState
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding var navigationPath: NavigationPath
  
  let viewModel: ProfileViewModel
  @State private var isEditingProfile = false
  @State private var isShowingReportSheet = false
  @State private var isShowingAccountSwitcher = false
  @State private var isShowingBlockConfirmation = false
  @State private var isBlocking = false
  @State private var isMuting = false
  @State private var scrollOffset: CGFloat = 0
  
  private let logger = Logger(subsystem: "blue.catbird", category: "UIKitProfileView")
  
  // MARK: - Initialization
  init(
    viewModel: ProfileViewModel,
    appState: AppState,
    selectedTab: Binding<Int>,
    lastTappedTab: Binding<Int?>,
    path: Binding<NavigationPath>
  ) {
    self.viewModel = viewModel
    self._selectedTab = selectedTab
    self._lastTappedTab = lastTappedTab
    _navigationPath = path
  }
  
  var body: some View {
    UIKitProfileViewControllerRepresentable(
      appState: appState,
      viewModel: viewModel,
      navigationPath: $navigationPath,
      selectedTab: $selectedTab,
      lastTappedTab: $lastTappedTab,
      isEditingProfile: $isEditingProfile,
      scrollOffset: $scrollOffset
    )
    .ignoresSafeArea()

    .id(viewModel.userDID) // Use stable userDID for view identity
    .navigationTitle(viewModel.profile != nil ? "@\(viewModel.profile!.handle)" : "Profile")
    .toolbarTitleDisplayMode(.inline)
    .ensureDeepNavigationFonts()
    .navigationDestination(for: ProfileNavigationDestination.self) { destination in
      switch destination {
      case .section(let tab):
        ProfileSectionView(viewModel: viewModel, tab: tab, path: $navigationPath)
          .id("\(viewModel.userDID)_\(tab.rawValue)") // Stable composite ID
      case .followers(let did):
        FollowersView(userDID: did, client: appState.atProtoClient, path: $navigationPath)
          .id(did)
      case .following(let did):
        FollowingView(userDID: did, client: appState.atProtoClient, path: $navigationPath)
          .id(did)
      }
    }
    .toolbar {
      if let profile = viewModel.profile {
        ToolbarItem(placement: .principal) {
          Text(profile.displayName ?? profile.handle.description)
            .appFont(AppTextRole.headline)
        }
        
        if viewModel.isCurrentUser {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button {
                isShowingAccountSwitcher = true
              } label: {
                Label("Switch Account", systemImage: "person.crop.circle.badge.plus")
              }
              
              Button {
                Task {
                  try? await appState.handleLogout()
                }
              } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        } else {
          ToolbarItem(placement: .primaryAction) {
            Menu {
              Button {
                isShowingReportSheet = true
              } label: {
                Label("Report User", systemImage: "flag")
              }
              
              Button {
                toggleMute()
              } label: {
                if isMuting {
                  Label("Unmute User", systemImage: "speaker.wave.2")
                } else {
                  Label("Mute User", systemImage: "speaker.slash")
                }
              }
              
              Button(role: .destructive) {
                isShowingBlockConfirmation = true
              } label: {
                if isBlocking {
                  Label("Unblock User", systemImage: "person.crop.circle.badge.checkmark")
                } else {
                  Label("Block User", systemImage: "person.crop.circle.badge.xmark")
                }
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        }
      }
    }
    .sheet(isPresented: $isShowingReportSheet) {
      if let profile = viewModel.profile,
         let atProtoClient = appState.atProtoClient {
        let reportingService = ReportingService(client: atProtoClient)
        
        ReportProfileView(
          profile: profile,
          reportingService: reportingService,
          onComplete: { _ in
            isShowingReportSheet = false
          }
        )
      }
    }
    .sheet(isPresented: $isEditingProfile) {
      EditProfileView(isPresented: $isEditingProfile, viewModel: viewModel)
    }
    .sheet(isPresented: $isShowingAccountSwitcher) {
      AccountSwitcherView()
    }
    .alert(isBlocking ? "Unblock User" : "Block User", isPresented: $isShowingBlockConfirmation) {
      Button("Cancel", role: .cancel) {}
      
      Button(isBlocking ? "Unblock" : "Block", role: .destructive) {
        toggleBlock()
      }
    } message: {
      if let profile = viewModel.profile {
        if isBlocking {
          Text("Unblock @\(profile.handle)? You'll be able to see each other's posts again.")
        } else {
          Text("Block @\(profile.handle)? You won't see each other's posts, and they won't be able to follow you.")
        }
      }
    }
    .onChange(of: lastTappedTab) { _, newValue in
      handleTabChange(newValue)
    }
    .task {
      await initialLoad()
    }
  }
  
  // MARK: - Event Handlers
  private func handleTabChange(_ newValue: Int?) {
    guard selectedTab == 3 else { return }
    
    if newValue == 3 {
      // Double-tapped profile tab - refresh profile and scroll to top
      Task {
        await viewModel.loadProfile()
        // Send scroll to top command
        appState.tabTappedAgain = 3
      }
      lastTappedTab = nil
    }
  }
  
  private func initialLoad() async {
    await viewModel.loadProfile()
    
    // Check muting and blocking status
    if let did = viewModel.profile?.did.didString(), !viewModel.isCurrentUser {
      self.isBlocking = await appState.isBlocking(did: did)
      self.isMuting = await appState.isMuting(did: did)
      
      // Load known followers for other users
      await viewModel.loadKnownFollowers()
    }
  }
  
  private func toggleMute() {
    guard let profile = viewModel.profile, !viewModel.isCurrentUser else { return }
    
    let did = profile.did.didString()
    Task {
      do {
        let previousState = isMuting
        
        // Optimistically update UI
        isMuting.toggle()
        
        let success: Bool
        if previousState {
          // Unmute
          success = try await appState.unmute(did: did)
        } else {
          // Mute
          success = try await appState.mute(did: did)
        }
        
        if !success {
          // Revert if unsuccessful
          isMuting = previousState
        }
      } catch {
        // Revert on error
        isMuting = !isMuting
        logger.error("Failed to toggle mute: \(error.localizedDescription)")
      }
    }
  }
  
  private func toggleBlock() {
    guard let profile = viewModel.profile, !viewModel.isCurrentUser else { return }
    
    let did = profile.did.didString()
    Task {
      do {
        let previousState = isBlocking
        
        // Optimistically update UI
        isBlocking.toggle()
        
        let success: Bool
        if previousState {
          // Unblock
          success = try await appState.unblock(did: did)
        } else {
          // Block
          success = try await appState.block(did: did)
        }
        
        if !success {
          // Revert if unsuccessful
          isBlocking = previousState
        }
      } catch {
        // Revert on error
        isBlocking = !isBlocking
        logger.error("Failed to toggle block: \(error.localizedDescription)")
      }
    }
  }
}

// MARK: - UIViewControllerRepresentable
@available(iOS 18.0, *)
struct UIKitProfileViewControllerRepresentable: UIViewControllerRepresentable {
  let appState: AppState
  let viewModel: ProfileViewModel
  @Binding var navigationPath: NavigationPath
  @Binding var selectedTab: Int
  @Binding var lastTappedTab: Int?
  @Binding var isEditingProfile: Bool
  @Binding var scrollOffset: CGFloat
  
  func makeUIViewController(context: Context) -> UIKitProfileViewController {
    let vc = UIKitProfileViewController(
      appState: appState,
      viewModel: viewModel,
      navigationPath: $navigationPath,
      selectedTab: $selectedTab,
      lastTappedTab: $lastTappedTab,
      isEditingProfile: $isEditingProfile
    )
    return vc
  }
  
  func updateUIViewController(_ uiViewController: UIKitProfileViewController, context: Context) {
    // The UIKitProfileViewController manages its own scroll offset internally
  }
  
}

