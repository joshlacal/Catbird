import SwiftUI
import OSLog

#if os(iOS)
import UIKit

struct ChatAccountSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  @State private var showingExportConfirmation = false
  @State private var showingDeleteConfirmation = false
  @State private var isExporting = false
  @State private var isDeleting = false
  @State private var exportedData: Data?
  @State private var showingShareSheet = false
  @State private var errorMessage: String?
  @State private var showingError = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatAccountSettings")
  
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Manage your chat account data and settings")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
        
        Section("Data Management") {
          Button {
            showingExportConfirmation = true
          } label: {
            Label("Export Chat Data", systemImage: "square.and.arrow.up")
          }
          .disabled(isExporting || isDeleting)
          
          Button(role: .destructive) {
            showingDeleteConfirmation = true
          } label: {
            Label("Delete Chat Account", systemImage: "trash")
              .foregroundColor(.red)
          }
          .disabled(isExporting || isDeleting)
        }
        
        Section("Chat Activity") {
          NavigationLink {
            ChatActivityLogView()
          } label: {
            Label("View Activity Log", systemImage: "clock.arrow.circlepath")
          }
        }
        
        Section {
          Text("Deleting your chat account will remove all your messages and conversations. This action cannot be undone.")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
      }
      .navigationTitle("Chat Account")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
        }
      }
      .confirmationDialog("Export Chat Data", isPresented: $showingExportConfirmation) {
        Button("Export") {
          exportChatData()
        }
        Button("Cancel", role: .cancel) { }
      } message: {
        Text("This will export all your chat messages and conversations to a file.")
      }
      .confirmationDialog("Delete Chat Account", isPresented: $showingDeleteConfirmation) {
        Button("Delete Account", role: .destructive) {
          deleteChatAccount()
        }
        Button("Cancel", role: .cancel) { }
      } message: {
        Text("Are you sure you want to delete your chat account? This will permanently delete all your messages and conversations. This action cannot be undone.")
      }
      .overlay {
        if isExporting {
          ProgressView("Exporting data...")
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if isDeleting {
          ProgressView("Deleting account...")
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      }
      .alert("Error", isPresented: $showingError) {
        Button("OK") { }
      } message: {
        Text(errorMessage ?? "An unknown error occurred")
      }
      .sheet(isPresented: $showingShareSheet) {
        if let data = exportedData {
          ChatShareSheet(items: [data])
        }
      }
    }
  }
  
  private func exportChatData() {
    Task {
      isExporting = true
      defer { isExporting = false }
      
      do {
        if let data = await appState.chatManager.exportChatAccountData() {
          await MainActor.run {
            exportedData = data
            showingShareSheet = true
          }
        } else {
          await MainActor.run {
            errorMessage = "Failed to export chat data"
            showingError = true
          }
        }
      }
    }
  }
  
  private func deleteChatAccount() {
    Task {
      isDeleting = true
      defer { isDeleting = false }
      
      let (success, exportData) = await appState.chatManager.deleteChatAccount()
      
      await MainActor.run {
        if success {
          if let data = exportData {
            // Offer to save the export before deletion completes
            exportedData = data
            showingShareSheet = true
          }
          // Dismiss after successful deletion
          dismiss()
        } else {
          errorMessage = "Failed to delete chat account"
          showingError = true
        }
      }
    }
  }
}

// MARK: - Chat Activity Log View

struct ChatActivityLogView: View {
  @Environment(AppState.self) private var appState
  @State private var logEntries: [ChatLogEntry] = []
  @State private var isLoading = false
  @State private var cursor: String?
  @State private var hasMore = true
  
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatActivityLog")
  
  var body: some View {
    List {
      ForEach(logEntries) { entry in
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.type)
            .appFont(AppTextRole.headline)
          Text(entry.description)
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          Text(entry.timestamp, style: .relative)
            .appFont(AppTextRole.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
      }
      
      if hasMore && !logEntries.isEmpty {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding()
          .onAppear {
            loadMoreLogs()
          }
      }
    }
    .navigationTitle("Activity Log")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .overlay {
      if isLoading && logEntries.isEmpty {
        ProgressView("Loading activity...")
      } else if logEntries.isEmpty && !isLoading {
        ContentUnavailableView(
          "No Activity",
          systemImage: "clock",
          description: Text("Your chat activity will appear here")
        )
      }
    }
    .onAppear {
      if logEntries.isEmpty {
        loadMoreLogs()
      }
    }
  }
  
  private func loadMoreLogs() {
    guard !isLoading else { return }
    
    Task {
      isLoading = true
      defer { isLoading = false }
      
      let (logs, newCursor) = await appState.chatManager.getConversationLog(cursor: cursor)
      
      await MainActor.run {
        if let logs = logs {
          // Convert raw log data to structured entries
          let newEntries = logs.compactMap { log -> ChatLogEntry? in
            // Parse the log data - this is a simplified example
            // You'd need to handle the actual log format from the API
            guard let logDict = log as? [String: Any] else { return nil }
            
            return ChatLogEntry(
              id: UUID().uuidString,
              type: logDict["type"] as? String ?? "Unknown",
              description: logDict["description"] as? String ?? "",
              timestamp: Date()
            )
          }
          
          logEntries.append(contentsOf: newEntries)
          cursor = newCursor
          hasMore = newCursor != nil
        } else {
          hasMore = false
        }
      }
    }
  }
}

// MARK: - Supporting Types

struct ChatLogEntry: Identifiable {
  let id: String
  let type: String
  let description: String
  let timestamp: Date
}

struct ChatShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  
  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
    // Configure iPad popover anchor to prevent presentation crash
    if let popover = controller.popoverPresentationController {
      if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
         let root = windowScene.windows.first?.rootViewController?.view {
        popover.sourceView = root
        popover.sourceRect = CGRect(x: root.bounds.midX, y: root.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
    }
    return controller
  }
  
  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#endif
