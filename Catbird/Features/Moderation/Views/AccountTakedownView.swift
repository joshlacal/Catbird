//
//  AccountTakedownView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import OSLog
import SwiftUI
import Petrel

/// Full-screen interstitial view shown when the authenticated account has been taken down or suspended.
struct AccountTakedownView: View {
    let appState: AppState
    @Environment(AppStateManager.self) private var appStateManager
    
    @State private var showingAppealForm: Bool = false
    @State private var appealDetails: String = ""
    @State private var isSubmitting: Bool = false
    @State private var appealSubmitted: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isSigningOut: Bool = false
    @State private var showingAccountSwitcher: Bool = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AccountTakedownView")
    private let maxAppealCharacters: Int = 1000
    
    private var isOverLimit: Bool {
        appealDetails.count > maxAppealCharacters
    }
    
    private var canSubmit: Bool {
        !appealDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isOverLimit && !isSubmitting
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerView
                    
                    if appealSubmitted {
                        appealSubmittedView
                    } else if showingAppealForm {
                        appealFormView
                    } else {
                        actionButtonsView
                    }
                    
                    if let errorMessage = errorMessage {
                        errorBanner(errorMessage)
                    }
                    
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Account Status")
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
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
                .padding(.top, 16)
            
            Text("Account Taken Down")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text(statusMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }
    
    private var statusMessage: String {
        let reason = "has been taken down for violating the Terms of Service or Community Guidelines."
        if let handle = appState.currentUserProfile?.handle.description ?? appStateManager.authentication.handle {
            return "Your account (@\(handle)) \(reason)"
        }
        return "Your account \(reason)"
    }
    
    // MARK: - Initial Actions
    
    private var actionButtonsView: some View {
        VStack(spacing: 12) {
            Button {
                errorMessage = nil
                showingAppealForm = true
            } label: {
                HStack {
                    Image(systemName: "doc.text.badge.plus")
                    Text("Submit Appeal")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            
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
            .disabled(isSigningOut)
            
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
            .disabled(isSigningOut)
        }
        .padding(.top, 16)
    }
    
    // MARK: - Appeal Form
    
    private var appealFormView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appeal Takedown")
                .font(.headline)
                .fontWeight(.semibold)
            
            Text("Explain why you believe your account should be restored. A moderator will review your appeal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $appealDetails)
                    .frame(minHeight: 140, maxHeight: 220)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isOverLimit ? Color.red : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                
                Text("\(appealDetails.count)/\(maxAppealCharacters)")
                    .font(.caption)
                    .foregroundStyle(isOverLimit ? .red : .secondary)
            }
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    showingAppealForm = false
                    errorMessage = nil
                }
                .buttonStyle(.bordered)
                .disabled(isSubmitting)
                
                Spacer()
                
                Button {
                    Task {
                        await submitAppeal()
                    }
                } label: {
                    HStack {
                        if isSubmitting {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text("Submit Appeal")
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.top, 8)
    }
    
    // MARK: - Submitted State
    
    private var appealSubmittedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            
            Text("Appeal Submitted")
                .font(.headline)
                .fontWeight(.bold)
            
            Text("Your appeal was received and is waiting for a moderator to review it. You’ll be notified when a decision is made.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                Task {
                    await handleSignOut()
                }
            } label: {
                Text("Sign Out")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.top, 8)
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
    
    // MARK: - Actions
    
    private func submitAppeal() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        
        guard let client = appState.atProtoClient else {
            errorMessage = "You’re signed out. Sign in again to submit an appeal."
            isSubmitting = false
            return
        }
        
        let reportingService = ReportingService(client: client)
        
        do {
            let success = try await reportingService.submitAccountAppeal(
                userDID: appState.userDID,
                details: appealDetails.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            
            if success {
                appealSubmitted = true
                showingAppealForm = false
            } else {
                errorMessage = "Couldn’t send your appeal. Try again later."
            }
        } catch let appealError as LabelAppealError {
            logger.error("Account appeal rejected: \(appealError.localizedDescription, privacy: .public)")
            if appealError == .alreadyAppealed {
                errorMessage = "You’ve already appealed this decision, and it’s under review."
            } else {
                errorMessage = "Couldn’t send your appeal. Check your connection and try again."
            }
        } catch {
            logger.error("Account appeal failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn’t send your appeal. Check your connection and try again."
        }
        
        isSubmitting = false
    }
    
    private func handleSignOut() async {
        isSigningOut = true
        await appStateManager.logout()
        isSigningOut = false
    }
}
