import SwiftUI
import Petrel
import OSLog
import CatbirdMLSService

#if os(iOS)

struct MLSJoinConversationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var convoId = ""
    @State private var isJoining = false
    @State private var errorMessage: String?
    @State private var showingError = false
    
    let onJoinSuccess: (@Sendable () async -> Void)?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSJoinConversation")
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Conversation ID", text: $convoId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Enter Conversation ID")
                } footer: {
                    Text("Enter the ID of the conversation you want to join.")
                }
                
                Section {
                    Button {
                        Task {
                            await joinConversation()
                        }
                    } label: {
                        if isJoining {
                            HStack {
                                Text("Joining...")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Text("Join Conversation")
                        }
                    }
                    .disabled(convoId.isEmpty || isJoining)
                }
            }
            .navigationTitle("Join Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isJoining)
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }
    
    @MainActor
    private func joinConversation() async {
        guard !convoId.isEmpty else { return }
        
        isJoining = true
        errorMessage = nil
        
        guard let manager = await appState.getMLSConversationManager(),
              let userDid = manager.userDid else {
            errorMessage = "MLS service not available"
            showingError = true
            isJoining = false
            return
        }
        
        do {
            logger.info("Joining conversation via External Commit: \(convoId)")
            
            // Call joinByExternalCommit on MLSClient
            // Note: We need to access MLSClient directly or via Manager
            // Manager doesn't expose joinByExternalCommit yet, so we might need to add it there too.
            // For now, let's assume we can access it via manager.mlsClient
            
            _ = try await manager.mlsClient.joinByExternalCommit(for: userDid, convoId: convoId)
            
            logger.info("Successfully joined conversation")
            
            // Refresh conversations
            await appState.reloadMLSConversations()
            
            if let onJoinSuccess {
                await onJoinSuccess()
            }
            
            dismiss()
            
        } catch {
            logger.error("Failed to join conversation: \(error.localizedDescription)")
            errorMessage = "Failed to join: \(error.localizedDescription)"
            showingError = true
        }
        
        isJoining = false
    }
}

#Preview {
    MLSJoinConversationView(onJoinSuccess: nil)
        .environment(AppStateManager.shared)
}

#endif
