//
//  AccountDeactivatedView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import SwiftUI
import Petrel

/// Full-screen interstitial view shown when the authenticated account is deactivated.
struct AccountDeactivatedView: View {
    let appState: AppState
    @Environment(AppStateManager.self) private var appStateManager
    
    @State private var isReactivating: Bool = false
    @State private var isSigningOut: Bool = false
    @State private var showingAccountSwitcher: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerView
                    
                    if let errorMessage = errorMessage {
                        errorBanner(errorMessage)
                    }
                    
                    actionButtonsView
                    
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Account Deactivated")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showingAccountSwitcher) {
                AccountSwitcherView()
                    .environment(appStateManager)
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
                .padding(.top, 16)
            
            Text("Account Deactivated")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            let handle = appState.currentUserProfile?.handle.description ?? appState.userDID
            Text("Your account (@\(handle)) is currently deactivated. Social features, posts, and feeds are disabled until reactivated.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }
    
    // MARK: - Actions
    
    private var actionButtonsView: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await handleReactivate()
                }
            } label: {
                HStack {
                    if isReactivating {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                    Text("Reactivate Account")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isReactivating || isSigningOut)
            
            Button {
                showingAccountSwitcher = true
            } label: {
                HStack {
                    Image(systemName: "person.2.circle")
                    Text("Switch / Add Account")
                }
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .disabled(isReactivating || isSigningOut)
            
            Button {
                Task {
                    await handleSignOut()
                }
            } label: {
                HStack {
                    if isSigningOut {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    Text("Sign Out")
                }
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .disabled(isReactivating || isSigningOut)
        }
        .padding(.top, 16)
    }
    
    // MARK: - Error Banner
    
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.12))
        )
    }
    
    // MARK: - Handlers
    
    private func handleReactivate() async {
        isReactivating = true
        errorMessage = nil
        
        do {
            try await appStateManager.reactivateAccount(appState: appState)
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isReactivating = false
    }
    
    private func handleSignOut() async {
        isSigningOut = true
        await appStateManager.logout()
        isSigningOut = false
    }
}
