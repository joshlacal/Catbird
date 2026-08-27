//
//  AccountTakedownView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

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
            
            Text("Your account (@\(appState.currentUserProfile?.handle.description ?? appState.userDID)) has been taken down due to violations of terms of service or community guidelines.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
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
            
            Text("Please explain why you believe your account should be reinstated. Your appeal will be reviewed by moderation.")
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
            
            Text("Your appeal has been received and is currently under review by moderation. You will be notified once a decision has been reached.")
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
            errorMessage = "Authentication client is not available."
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
                errorMessage = "Failed to submit appeal. Please try again later."
            }
        } catch let appealError as LabelAppealError {
            if appealError == .alreadyAppealed {
                errorMessage = "This account takedown has already been appealed and is currently under review."
            } else {
                errorMessage = appealError.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isSubmitting = false
    }
    
    private func handleSignOut() async {
        isSigningOut = true
        await appStateManager.logout()
        isSigningOut = false
    }
}
