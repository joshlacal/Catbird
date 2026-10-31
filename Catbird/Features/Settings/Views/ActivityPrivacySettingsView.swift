import SwiftUI
import Petrel

public enum ActivityPrivacyOption: String, CaseIterable, Identifiable {
  case followers = "followers"
  case mutuals = "mutuals"
  case none = "none"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .followers: "Anyone who follows me"
    case .mutuals: "Only followers who I follow"
    case .none: "No one"
    }
  }

  public var subtitle: String {
    switch self {
    case .followers: "Anyone following your account can subscribe to receive notifications when you post."
    case .mutuals: "Only mutual followers can subscribe to receive notifications when you post."
    case .none: "No one can subscribe to receive notifications when you post."
    }
  }
}

private struct ActivityPrivacySettingsRecord {
  var allowSubscriptions: String
  var cid: CID?
}

struct ActivityPrivacySettingsView: View {
  @Environment(AppState.self) private var appState
  let initialFocus: SettingsControlID?
  @State private var editor: AccountSettingsEditSession<ActivityPrivacySettingsRecord>?

  init(initialFocus: SettingsControlID? = nil) {
    self.initialFocus = initialFocus
  }

  private var requestedFocus: SettingsControlID? {
    guard let initialFocus else { return nil }
    switch editor?.state {
    case .loadFailed: return .init(rawValue: "privacy.activityRetryLoad")
    case .saveFailed: return .init(rawValue: "privacy.activityRetrySave")
    default: return initialFocus
    }
  }

  private var isFocusReady: Bool {
    switch editor?.state {
    case .ready, .loadFailed, .saveFailed: true
    default: false
    }
  }

  var body: some View {
    SettingsFocusedForm(initialFocus: requestedFocus, isReady: isFocusReady) {
      SettingsScopeSection()
      if let editor {
        if editor.state == .unavailable {
          Section { Text("This account is no longer active. Open Settings for the current account.") }
        } else if editor.state == .loading {
          Section { ProgressView("Loading your subscription setting…") }
        } else if editor.state == .loadFailed {
          Section {
            Text("Your subscription setting couldn’t be loaded.")
            Text(editor.errorMessage ?? "Try again.")
              .font(.footnote).foregroundStyle(.secondary)
            Button("Try Again") { Task { await editor.load() } }
              .settingsControl(.init(rawValue: "privacy.activityRetryLoad"))
          }
          .settingsControl(.init(rawValue: "privacy.activitySubscriptions"))
        } else {
          Section {
            if let value = editor.displayedValue,
               ActivityPrivacyOption(rawValue: value.allowSubscriptions) == nil {
              Text("Your current rule isn’t supported by this version of Catbird. It stays unchanged unless you choose a rule below.")
                .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(ActivityPrivacyOption.allCases) { option in
              Button { select(option, in: editor) } label: {
                HStack(alignment: .top, spacing: 12) {
                  Image(systemName: editor.displayedValue?.allowSubscriptions == option.rawValue
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(option.title).foregroundStyle(.primary)
                    Text(option.subtitle).font(.footnote).foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(!editor.canEdit)
              .accessibilityAddTraits(editor.displayedValue?.allowSubscriptions == option.rawValue ? .isSelected : [])
            }
          } header: {
            Text("Who Can Subscribe to My Posts")
          } footer: {
            Text("This controls alerts about your posts. Other people may still view and interact with public posts according to your other privacy settings.")
          }
          .settingsControl(.init(rawValue: "privacy.activitySubscriptions"))
          if editor.state == .saving {
            Section { ProgressView("Saving subscription rule…") }
          } else if editor.state == .saveFailed {
            Section {
              Text("This change couldn’t be confirmed. Your last saved rule is shown.")
              Text(editor.errorMessage ?? "Try the change again or reload the saved rule.")
                .font(.footnote).foregroundStyle(.secondary)
              Button("Try This Change Again") { editor.retrySave() }
                .settingsControl(.init(rawValue: "privacy.activityRetrySave"))
              Button("Reload Saved Rule") { Task { await editor.load() } }
            }
          }
        }
      } else {
        Section { ProgressView("Loading your subscription setting…") }
      }
    }
    .navigationTitle("Who Can Subscribe to My Posts")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: appState.userDID) { await loadEditor() }
    .onDisappear { editor?.invalidate() }
  }

  @MainActor
  private func loadEditor() async {
    editor?.invalidate()
    let account = appState.userDID
    let contextRevision = AppStateManager.shared.settingsAccountContextRevision
    let state = appState
    let client = state.atProtoClient
    let session = AccountSettingsEditSession<ActivityPrivacySettingsRecord>(
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
          guard let client else { throw ActivityPrivacySettingsError.notAuthenticated }
          do {
            let (code, output) = try await client.com.atproto.repo.getRecord(input: .init(
              repo: try ATIdentifier(string: account),
              collection: try NSID(nsidString: "app.bsky.notification.declaration"),
              rkey: try RecordKey(keyString: "self")
            ))
            guard code == 200, let output,
                  let record = output.value.decoded(AppBskyNotificationDeclaration.self) else {
              throw ActivityPrivacySettingsError.response(code)
            }
            return ActivityPrivacySettingsRecord(allowSubscriptions: record.allowSubscriptions, cid: output.cid)
          } catch ComAtprotoRepoGetRecord.Error.recordNotFound {
            return ActivityPrivacySettingsRecord(allowSubscriptions: ActivityPrivacyOption.followers.rawValue, cid: nil)
          } catch let error as ATProtoError<ComAtprotoRepoGetRecord.Error> where error.error == .recordNotFound {
            return ActivityPrivacySettingsRecord(allowSubscriptions: ActivityPrivacyOption.followers.rawValue, cid: nil)
          } catch let error as ATProtoXRPCError where error.error == "RecordNotFound" {
            return ActivityPrivacySettingsRecord(allowSubscriptions: ActivityPrivacyOption.followers.rawValue, cid: nil)
          }
        }
      },
      save: { value in
        return try await state.performSettingsAccountOperation {
          guard let client, AppStateManager.shared.lifecycle.userDID == account,
                AppStateManager.shared.settingsAccountContextRevision == contextRevision, !state.isTransitioningAccounts,
                state.atProtoClient === client else { throw ActivityPrivacySettingsError.accountChanged }
          let (code, output) = try await client.com.atproto.repo.putRecord(input: .init(
            repo: try ATIdentifier(string: account),
            collection: try NSID(nsidString: "app.bsky.notification.declaration"),
            rkey: try RecordKey(keyString: "self"),
            record: .knownType(AppBskyNotificationDeclaration(allowSubscriptions: value.allowSubscriptions)),
            swapRecord: value.cid
          ))
          guard code == 200, let output else { throw ActivityPrivacySettingsError.response(code) }
          return ActivityPrivacySettingsRecord(allowSubscriptions: value.allowSubscriptions, cid: output.cid)
        }
      }
    )
    editor = session
    await session.load()
  }

  @MainActor
  private func select(_ option: ActivityPrivacyOption, in session: AccountSettingsEditSession<ActivityPrivacySettingsRecord>) {
    guard session.canEdit, var value = session.confirmedValue,
          value.allowSubscriptions != option.rawValue else { return }
    value.allowSubscriptions = option.rawValue
    session.submit(value)
  }
}

private enum ActivityPrivacySettingsError: LocalizedError {
  case notAuthenticated, accountChanged, response(Int)

  var errorDescription: String? {
    switch self {
    case .notAuthenticated: "Sign in to load this account’s subscription rule."
    case .accountChanged: "The account changed. Open these settings again."
    case .response(let code): "The subscription rule could not be confirmed (status \(code)). Try again."
    }
  }
}
