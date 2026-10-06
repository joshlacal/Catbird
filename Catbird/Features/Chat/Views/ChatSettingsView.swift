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
  @State private var exportedFileURL: URL?
  @State private var errorMessage: String?
  @State private var showingDeletedConfirmation = false
  @State private var privacyEditor: AccountSettingsEditSession<ChatPrivacySettingsRecord>?
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatSettingsView")
  
  private var requestedFocus: SettingsControlID? {
    guard let initialFocus else { return nil }
    switch privacyEditor?.state {
    case .loadFailed: return .init(rawValue: "privacy.chatRetryLoad")
    case .saveFailed: return .init(rawValue: "privacy.chatRetrySave")
    default: return initialFocus
    }
  }

  private var isFocusReady: Bool {
    switch privacyEditor?.state {
    case .ready, .loadFailed, .saveFailed: true
    default: false
    }
  }

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
    SettingsFocusedForm(initialFocus: requestedFocus, isReady: isFocusReady) {
      SettingsScopeSection()
      privacySection
        Section {
          Button {
            showingMarkAllReadAlert = true
          } label: {
            HStack {
              Text("Mark All Conversations as Read")
                .foregroundStyle(Color.primary)
              Spacer()
              if isMarkingAllRead {
                ProgressView()
              }
            }
          }
          .disabled(isMarkingAllRead)
        }

        Section {
          Button {
            exportChatData()
          } label: {
            HStack {
              Text("Export Chat Data")
                .foregroundStyle(Color.primary)
              Spacer()
              if isExporting {
                ProgressView()
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
              Text("Moderation Tools")
            }
          #endif
        } footer: {
          Text("Download a copy of your direct messages.")
        }

        Section {
          Button(role: .destructive) {
            showingDeleteAccountAlert = true
          } label: {
            HStack {
              Text("Delete Chat Account")
              Spacer()
              if isDeleting {
                ProgressView()
              }
            }
          }
          .disabled(isDeleting)
        } header: {
          Text("Delete Chat Data")
        } footer: {
          Text("Permanently deletes your chat data, including conversations, messages and chat settings. This can’t be undone.")
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
      .alert("Mark All as Read?", isPresented: $showingMarkAllReadAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Mark All as Read") {
          markAllConversationsAsRead()
        }
      } message: {
        Text("All of your conversations will be marked as read.")
      }
      .alert("Delete Chat Account?", isPresented: $showingDeleteAccountAlert) {
        Button("Cancel", role: .cancel) { }
        Button("Delete", role: .destructive) {
          deleteChatAccount()
        }
      } message: {
        Text("This permanently deletes all of your conversations, messages and chat history. This can’t be undone.")
      }
      .alert("Chat Account Deleted", isPresented: $showingDeletedConfirmation) {
        Button("OK") { dismiss() }
      } message: {
        Text("Your chat account has been deleted.")
      }
      .sheet(isPresented: $showingExportData) {
        if let exportedFileURL {
          ChatDataExportView(fileURL: exportedFileURL)
        }
      }
      .alert("Something Went Wrong", isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button("OK") {
          errorMessage = nil
        }
      } message: {
        Text(errorMessage ?? "")
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
              .settingsControl(.init(rawValue: "privacy.chatRetryLoad"))
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
            Text("This change could not be confirmed. The last loaded rules are shown.")
            Text(editor.errorMessage ?? "Retry the change or reload the saved rules.").font(.footnote).foregroundStyle(.secondary)
            Button("Retry This Change") { editor.retrySave() }
                .settingsControl(.init(rawValue: "privacy.chatRetrySave"))
            Button("Reload Saved Rules") { Task { await editor.load() } }
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
      allowEditingAfterSaveFailure: false,
      isCurrentAccount: {
        AppStateManager.shared.lifecycle.userDID == account
          && AppStateManager.shared.settingsAccountContextRevision == contextRevision
          && !state.isTransitioningAccounts
          && state.atProtoClient === client
      },
      load: {
        return try await state.performSettingsAccountOperation {
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
        }
      },
      save: { value in
        return try await state.performSettingsAccountOperation {
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
      }
    )
    privacyEditor = editor
    await editor.load()
  }

  private func markAllConversationsAsRead() {
    Task {
      isMarkingAllRead = true
      let success = await appState.chatManager.markAllConversationsAsRead()
      isMarkingAllRead = false
      if success {
        appState.toastManager.show(ToastItem(message: "All conversations marked as read"))
      } else {
        appState.chatManager.errorState = nil
        errorMessage = "Couldn’t mark your conversations as read. Try again."
      }
    }
  }

  private func exportChatData() {
    Task {
      isExporting = true
      let data = await appState.chatManager.exportChatAccountData()
      isExporting = false
      guard let data else {
        appState.chatManager.errorState = nil
        errorMessage = "Couldn’t export your chat data. Try again."
        return
      }
      let stamp = Date().formatted(.iso8601.year().month().day())
      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("bluesky-chat-export-\(stamp).jsonl")
      do {
        try data.write(to: fileURL, options: .atomic)
        exportedFileURL = fileURL
        showingExportData = true
      } catch {
        logger.error("Failed to write chat export: \(error.localizedDescription)")
        errorMessage = "Couldn’t save your chat data. Try again."
      }
    }
  }

  private func deleteChatAccount() {
    Task {
      isDeleting = true
      let success = await appState.chatManager.deleteChatAccount()
      isDeleting = false
      if success {
        showingDeletedConfirmation = true
      } else {
        appState.chatManager.errorState = nil
        errorMessage = "Couldn’t delete your chat account. Try again."
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
    case .response: "Chat privacy settings couldn’t be confirmed. Try again."
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

/// View for sharing or saving an exported chat data file
struct ChatDataExportView: View {
  let fileURL: URL
  @Environment(\.dismiss) private var dismiss

  private var fileSize: Int64? {
    (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Image(systemName: "square.and.arrow.up.circle")
          .appFont(size: 64)
          .foregroundStyle(.tint)
          .accessibilityHidden(true)

        Text("Chat Data Exported")
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)

        Text("Your chat data is ready. Share it or save it to Files.")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)

        VStack(spacing: 12) {
          if let fileSize {
            Text("File size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
          }

          ShareLink(item: fileURL) {
            Label("Share Export File", systemImage: "square.and.arrow.up")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
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
    }
  }
}

#Preview {
  AsyncPreviewContent { appState in
    ChatSettingsView()
        .environment(AppStateManager.shared)
  }
}
