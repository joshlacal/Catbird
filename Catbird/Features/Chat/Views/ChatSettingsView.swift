import OSLog
import SwiftUI

#if os(iOS)

/// Settings view for chat-related options and actions
struct ChatSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  @State private var showingExportData = false
  @State private var showingDeleteAccountAlert = false
  @State private var showingMarkAllReadAlert = false
  @State private var isExporting = false
  @State private var isDeleting = false
  @State private var isMarkingAllRead = false
  @State private var exportedData: Data?
  @State private var errorMessage: String?
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatSettingsView")
  
  var body: some View {
    NavigationView {
      List {
        Section {
          Button {
            markAllConversationsAsRead()
          } label: {
            HStack {
              Image(systemName: "envelope.open")
                .foregroundColor(.blue)
              Text("Mark All Conversations as Read")
              Spacer()
              if isMarkingAllRead {
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }
          .disabled(isMarkingAllRead)
        } header: {
          Text("Quick Actions")
        }
        
        Section {
          Button {
            exportChatData()
          } label: {
            HStack {
              Image(systemName: "square.and.arrow.up")
                .foregroundColor(.blue)
              Text("Export Chat Data")
              Spacer()
              if isExporting {
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }
          .disabled(isExporting)
          
          NavigationLink {
            ChatModerationView()
          } label: {
            HStack {
              Image(systemName: "shield")
                .foregroundColor(.orange)
              Text("Moderation Tools")
            }
          }
        } header: {
          Text("Data & Moderation")
        }
        
        Section {
          Button {
            showingDeleteAccountAlert = true
          } label: {
            HStack {
              Image(systemName: "trash")
                .foregroundColor(.red)
              Text("Delete Chat Account")
              Spacer()
              if isDeleting {
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }
          .disabled(isDeleting)
        } header: {
          Text("Danger Zone")
        } footer: {
          Text("This will permanently delete all your chat data including conversations, messages, and settings. This action cannot be undone.")
        }
      }
      .navigationTitle("Chat Settings")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .alert("Mark All as Read", isPresented: $showingMarkAllReadAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Mark All Read") {
          markAllConversationsAsRead()
        }
      } message: {
        Text("This will mark all conversations as read. Continue?")
      }
      .alert("Delete Chat Account", isPresented: $showingDeleteAccountAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Delete", role: .destructive) {
          deleteChatAccount()
        }
      } message: {
        Text("Are you sure you want to permanently delete your chat account? This will remove all conversations, messages, and chat history. This action cannot be undone.")
      }
      .sheet(isPresented: $showingExportData) {
        ChatDataExportView(exportedData: $exportedData)
      }
      .alert("Error", isPresented: .constant(errorMessage != nil)) {
        Button("OK") {
          errorMessage = nil
        }
      } message: {
        Text(errorMessage ?? "An unknown error occurred")
      }
    }
  }
  
  private func markAllConversationsAsRead() {
    Task {
      isMarkingAllRead = true
      let success = await appState.chatManager.markAllConversationsAsRead()
      await MainActor.run {
        isMarkingAllRead = false
        if !success {
          errorMessage = "Failed to mark all conversations as read"
        }
      }
    }
  }
  
  private func exportChatData() {
    Task {
      isExporting = true
      let data = await appState.chatManager.exportChatAccountData()
      await MainActor.run {
        isExporting = false
        if let data = data {
          exportedData = data
          showingExportData = true
        } else {
          errorMessage = "Failed to export chat data"
        }
      }
    }
  }
  
  private func deleteChatAccount() {
    Task {
      isDeleting = true
      let result = await appState.chatManager.deleteChatAccount()
      await MainActor.run {
        isDeleting = false
        if result.success {
          // Optionally save export data before dismissing
          if let exportData = result.exportData {
            exportedData = exportData
            showingExportData = true
          }
          dismiss()
        } else {
          errorMessage = "Failed to delete chat account"
        }
      }
    }
  }
}

/// View for displaying and sharing exported chat data
struct ChatDataExportView: View {
  @Binding var exportedData: Data?
  @Environment(\.dismiss) private var dismiss
  @State private var showingShareSheet = false
  
  var body: some View {
    NavigationView {
      VStack(spacing: 20) {
        Image(systemName: "square.and.arrow.up.circle")
          .appFont(size: 64)
          .foregroundColor(.blue)
        
        Text("Chat Data Exported")
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
        
        Text("Your chat data has been exported successfully. You can share or save this file.")
          .multilineTextAlignment(.center)
          .foregroundColor(.secondary)
        
        if let data = exportedData {
          VStack(spacing: 12) {
            Text("File Size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
            
            Button {
              showingShareSheet = true
            } label: {
              HStack {
                Image(systemName: "square.and.arrow.up")
                Text("Share Export File")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          }
        }
        
        Spacer()
      }
      .padding()
      .navigationTitle("Export Complete")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .sheet(isPresented: $showingShareSheet) {
        if let data = exportedData {
          ChatShareSheet(items: [data])
        }
      }
    }
  }
}

#Preview {
  ChatSettingsView()
    .environment(AppState.shared)
}
#endif
