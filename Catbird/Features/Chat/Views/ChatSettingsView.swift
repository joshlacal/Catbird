import OSLog
import Petrel
import SwiftUI

/// Bluesky chat declaration privacy options
enum ChatPrivacyOption: String, CaseIterable, Identifiable, Sendable {
  case all = "all"
  case following = "following"
  case none = "none"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all:
      return "Everyone"
    case .following:
      return "People I follow"
    case .none:
      return "No one"
    }
  }
}

/// Settings view for chat-related options and actions
private struct ChatPrivacySettingsRecord {
  var allowIncoming: String
  var allowGroupInvites: String?
  var cid: CID?
}

struct ChatSettingsView: View {
  enum Presentation { case modal, navigation }
  let initialFocus: SettingsControlID?
  let presentation: Presentation

  init(initialFocus: SettingsControlID? = nil, presentation: Presentation = .modal) {
    self.initialFocus = initialFocus
    self.presentation = presentation
  }
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
  @State private var privacyEditor: AccountSettingsEditSession<ChatPrivacySettingsRecord>?
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatSettingsView")
  
  var body: some View {
    Group {
      if presentation == .modal {
        NavigationStack { settingsContent }
      } else {
        settingsContent
      }
    }
  }

  private var settingsContent: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: privacyEditor?.canEdit == true) {
      SettingsScopeSection()
      privacySection
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

          // chat.bsky.moderation.* requires chat-service admin auth no user session has;
          // the entry point exists for internal debug builds only.
          #if DEBUG
            NavigationLink {
              ChatModerationView()
            } label: {
              HStack {
                Image(systemName: "shield")
                  .foregroundColor(.orange)
                Text("Moderation Tools")
              }
            }
          #endif
        } header: {
          #if DEBUG
            Text("Data & Moderation")
          #else
            Text("Data")
          #endif
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
      .modifier(ChatSettingsTitleStyle())
      .toolbar {
        if presentation == .modal {
          ToolbarItem(placement: .primaryAction) {
            Button("Done") { dismiss() }
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
      .task(id: appState.userDID) { await loadPrivacyEditor() }
      .onDisappear { privacyEditor?.invalidate() }
  }

  @ViewBuilder
  private var privacySection: some View {
    Section {
      if let editor = privacyEditor {
        switch editor.state {
        case .unavailable:
          Text("This account is no longer active. Open Settings for the current account.")
        case .loading:
          ProgressView("Loading chat privacy settings…")
        case .loadFailed:
          Text("Chat privacy settings could not be loaded.")
          Text(editor.errorMessage ?? "Try again.").font(.footnote).foregroundStyle(.secondary)
          Button("Retry") { Task { await editor.load() } }
        case .ready, .saving, .saveFailed:
          privacyPicker("Messages from", groupInvites: false, editor: editor)
            .settingsControl(.init(rawValue: "privacy.messages"))
          privacyPicker("Group chat invitations from", groupInvites: true, editor: editor)
            .settingsControl(.init(rawValue: "privacy.groupInvitations"))
          if editor.displayedValue?.allowGroupInvites == nil {
            Text("Group invitations follow your message rule until you save a separate invitation rule.")
              .font(.footnote).foregroundStyle(.secondary)
          }
          if editor.state == .saving {
            ProgressView("Saving chat privacy settings…")
          } else if editor.state == .saveFailed {
            Text("Your saved rules are still selected.")
            Text(editor.errorMessage ?? "The change was not saved.").font(.footnote).foregroundStyle(.secondary)
            Button("Retry This Change") { editor.retrySave() }
          }
        }
      } else {
        ProgressView("Loading chat privacy settings…")
      }
    } header: {
      Text("Bluesky Chat Privacy")
    } footer: {
      Text("Choose who can send you direct messages and invite you to group chats on Bluesky. Changes apply to this account.")
    }
    .settingsControl(.init(rawValue: "privacy.chatPrivacy"))
  }

  private func privacyPicker(
    _ title: String, groupInvites: Bool,
    editor: AccountSettingsEditSession<ChatPrivacySettingsRecord>
  ) -> some View {
    let raw = groupInvites
      ? (editor.displayedValue?.allowGroupInvites ?? editor.displayedValue?.allowIncoming ?? "")
      : (editor.displayedValue?.allowIncoming ?? "")
    return Picker(title, selection: Binding(
      get: { raw },
      set: { selection in
        guard editor.canEdit, var value = editor.confirmedValue, selection != raw else { return }
        if groupInvites { value.allowGroupInvites = selection } else { value.allowIncoming = selection }
        editor.submit(value)
      }
    )) {
      if ChatPrivacyOption(rawValue: raw) == nil {
        Text("Saved rule (unsupported)").tag(raw)
      }
      ForEach(ChatPrivacyOption.allCases) { Text($0.title).tag($0.rawValue) }
    }
    .disabled(!editor.canEdit)
  }

  @MainActor
  private func loadPrivacyEditor() async {
    privacyEditor?.invalidate()
    let state = appState
    let account = state.userDID
    let contextRevision = AppStateManager.shared.settingsAccountContextRevision
    let client = state.atProtoClient
    let editor = AccountSettingsEditSession<ChatPrivacySettingsRecord>(
      accountDID: account,
      isCurrentAccount: {
        AppStateManager.shared.lifecycle.userDID == account
          && AppStateManager.shared.settingsAccountContextRevision == contextRevision
          && !state.isTransitioningAccounts
          && state.atProtoClient === client
      },
      load: {
        guard let client else { throw ChatPrivacySettingsError.notAuthenticated }
        do {
          let (code, output) = try await client.com.atproto.repo.getRecord(input: .init(
            repo: try ATIdentifier(string: account),
            collection: try NSID(nsidString: "chat.bsky.actor.declaration"),
            rkey: try RecordKey(keyString: "self")
          ))
          guard code == 200, let output,
                let record = output.value.decoded(ChatBskyActorDeclaration.self) else {
            throw ChatPrivacySettingsError.response(code)
          }
          return ChatPrivacySettingsRecord(allowIncoming: record.allowIncoming,
            allowGroupInvites: record.allowGroupInvites, cid: output.cid)
        } catch let error as ATProtoError<ComAtprotoRepoGetRecord.Error> where error.error == .recordNotFound {
          return ChatPrivacySettingsRecord(allowIncoming: "following", allowGroupInvites: "following", cid: nil)
        } catch let error as ATProtoXRPCError where error.error == "RecordNotFound" {
          return ChatPrivacySettingsRecord(allowIncoming: "following", allowGroupInvites: "following", cid: nil)
        }
      },
      save: { value in
        guard let client, AppStateManager.shared.lifecycle.userDID == account,
              AppStateManager.shared.settingsAccountContextRevision == contextRevision,
              !state.isTransitioningAccounts, state.atProtoClient === client else {
          throw ChatPrivacySettingsError.accountChanged
        }
        let (code, output) = try await client.com.atproto.repo.putRecord(input: .init(
          repo: try ATIdentifier(string: account),
          collection: try NSID(nsidString: "chat.bsky.actor.declaration"),
          rkey: try RecordKey(keyString: "self"),
          record: .knownType(ChatBskyActorDeclaration(allowIncoming: value.allowIncoming,
            allowGroupInvites: value.allowGroupInvites)),
          swapRecord: value.cid
        ))
        guard code == 200, let output else { throw ChatPrivacySettingsError.response(code) }
        return ChatPrivacySettingsRecord(allowIncoming: value.allowIncoming,
          allowGroupInvites: value.allowGroupInvites, cid: output.cid)
      }
    )
    privacyEditor = editor
    await editor.load()
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

private enum ChatPrivacySettingsError: LocalizedError {
  case notAuthenticated, accountChanged, response(Int)
  var errorDescription: String? {
    switch self {
    case .notAuthenticated: "Sign in to load chat privacy settings."
    case .accountChanged: "The account changed. Open these settings again."
    case .response(let code): "Chat privacy settings could not be confirmed (status \(code)). Try again."
    }
  }
}

private struct ChatSettingsTitleStyle: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.toolbarTitleDisplayMode(.inline)
    #else
    content
    #endif
  }
}

/// View for displaying and sharing exported chat data
struct ChatDataExportView: View {
  @Binding var exportedData: Data?
  @Environment(\.dismiss) private var dismiss
  @State private var showingShareSheet = false
  
  var body: some View {
    NavigationStack {
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
      #if os(iOS)
      .sheet(isPresented: $showingShareSheet) {
        if let data = exportedData {
          ChatShareSheet(items: [data])
        }
      }
      #endif
    }
  }
}

#Preview {
  AsyncPreviewContent { appState in
    ChatSettingsView()
        .environment(AppStateManager.shared)
  }
}
