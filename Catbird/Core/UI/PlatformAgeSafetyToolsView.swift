import Petrel
import SwiftUI

/// Resolves only the identity and record reference needed for safety actions.
/// Post text, profile descriptions and media are never rendered here.
struct PlatformAgeSafetyToolsView: View {
  @Environment(AppState.self) private var appState
  @Environment(AppStateManager.self) private var appStateManager
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.dismiss) private var dismiss
  @State private var input: String
  @State private var target: SafetyTarget?
  @State private var report: SafetyReport?
  @State private var work: Task<Void, Never>?
  @State private var generation = UUID()
  @State private var errorMessage: String?
  @State private var statusMessage: String?
  @State private var confirmingBlock = false
  @State private var blockedDID: String?
  @State private var mutedDID: String?

  init(initialTarget: String? = nil) {
    _input = State(initialValue: initialTarget ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Handle, profile link, or post link", text: $input)
            .autocorrectionDisabled()
            .onSubmit { lookUp() }
          Button("Find Account or Post") { lookUp() }
            .disabled(work != nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if work != nil { ProgressView() }
        } footer: {
          Text("Look up a specific account or post to report, block, or mute. Its content will not be displayed.")
        }

        if let target {
          Section("Account") {
            Text(target.did.didString())
              .font(.footnote.monospaced())
              .textSelection(.enabled)
            if target.post != nil {
              Button("Report Post") { presentReport(for: target, post: true) }
            }
            Button("Report Account") { presentReport(for: target, post: false) }
            Button("Block Account", role: .destructive) { confirmingBlock = true }
              .disabled(target.did.didString() == appState.userDID || blockedDID == target.did.didString())
            Button("Mute Account") { performSafetyAction(.mute, target: target) }
              .disabled(target.did.didString() == appState.userDID || mutedDID == target.did.didString())
          }
          .disabled(work != nil)
        }

        if let errorMessage {
          Section { Text(errorMessage).foregroundStyle(.red) }
        }
        if let statusMessage {
          Section { Text(statusMessage).foregroundStyle(.secondary) }
        }
      }
      .navigationTitle("Report or Block")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
      .confirmationDialog("Block this account?", isPresented: $confirmingBlock, titleVisibility: .visible) {
        if let target {
          Button("Block Account", role: .destructive) { performSafetyAction(.block, target: target) }
        }
      } message: {
        Text("This uses your account’s existing block controls. You can manage blocks in Moderation Settings.")
      }
      .sheet(item: $report) { request in
        ReportFormView(
          reportingService: ReportingService(client: request.client),
          subject: request.subject,
          contentDescription: request.description,
          expectedAccountDID: request.accountDID
        )
      }
      .onChange(of: input) { _, _ in
        invalidateWork()
        target = nil
        statusMessage = nil
        errorMessage = nil
      }
      .onChange(of: appStateManager.settingsAccountContextRevision) { _, _ in
        invalidateWork()
        target = nil
        report = nil
      }
      .onChange(of: sceneContext.isInvalidated) { _, invalidated in
        if invalidated { invalidateWork(); report = nil }
      }
      .onDisappear { invalidateWork() }
    }
  }

  private struct SafetyTarget {
    let did: DID
    let post: ComAtprotoRepoStrongRef?
  }

  private struct SafetyReport: Identifiable {
    let id = UUID()
    let client: ATProtoClient
    let accountDID: String
    let subject: ComAtprotoModerationCreateReport.InputSubjectUnion
    let description: String
  }

  private struct AccountContext {
    let accountDID: String
    let revision: UInt64
    let registrationID: UUID
    let client: ATProtoClient
  }

  private func captureAccount() -> AccountContext? {
    guard appStateManager.lifecycle.appState === appState,
          appStateManager.lifecycle.isAuthenticated, !appState.isTransitioningAccounts,
          !sceneContext.isInvalidated, sceneContext.accountDID == appState.userDID else { return nil }
    return AccountContext(
      accountDID: appState.userDID,
      revision: appStateManager.settingsAccountContextRevision,
      registrationID: sceneContext.activityRegistrationID,
      client: appState.client)
  }

  private func isCurrent(_ account: AccountContext, generation expected: UUID) -> Bool {
    guard !Task.isCancelled, generation == expected, let current = captureAccount() else { return false }
    return current.accountDID == account.accountDID && current.revision == account.revision
      && current.registrationID == account.registrationID && current.client === account.client
  }

  private func invalidateWork() {
    generation = UUID()
    work?.cancel()
    work = nil
  }

  private func lookUp() {
    guard work == nil, let account = captureAccount() else { return }
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestID = UUID()
    generation = requestID
    target = nil
    errorMessage = nil
    statusMessage = nil
    work = Task { @MainActor in
      defer { if generation == requestID { work = nil } }
      do {
        let parsed = try Self.parseTarget(text)
        guard isCurrent(account, generation: requestID) else { return }
        let finish = try appState.preferencesManager.beginSettingsAccountIO()
        defer { finish?() }
        let didString: String
        if parsed.actor.hasPrefix("did:") {
          didString = parsed.actor
        } else {
          didString = try await account.client.resolveHandleToDID(handle: parsed.actor)
        }
        guard isCurrent(account, generation: requestID) else { return }
        let did = try DID(didString: didString)
        target = SafetyTarget(did: did, post: nil)
        var postReference: ComAtprotoRepoStrongRef?
        if let recordKey = parsed.recordKey {
          let uri = try ATProtocolURI(uriString: "at://\(didString)/app.bsky.feed.post/\(recordKey)")
          let (code, output) = try await account.client.app.bsky.feed.getPosts(input: .init(uris: [uri]))
          guard isCurrent(account, generation: requestID) else { return }
          if (200..<300).contains(code),
             let post = output?.posts.first(where: { $0.uri == uri && $0.author.did == did }) {
            postReference = ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid)
          } else {
            statusMessage = "This post is unavailable. You can still report, block, or mute its account."
          }
        }
        target = SafetyTarget(did: did, post: postReference)
      } catch {
        guard isCurrent(account, generation: requestID) else { return }
        errorMessage = target == nil
          ? "Couldn’t find this account or post. Check the handle or link and try again."
          : "Couldn’t load this post. You can still report, block, or mute its account."
      }
    }
  }

  private func presentReport(for target: SafetyTarget, post: Bool) {
    guard work == nil, let account = captureAccount() else { return }
    let subject: ComAtprotoModerationCreateReport.InputSubjectUnion
    if post, let reference = target.post {
      subject = .comAtprotoRepoStrongRef(reference)
    } else {
      subject = .comAtprotoAdminDefsRepoRef(ComAtprotoAdminDefs.RepoRef(did: target.did))
    }
    report = SafetyReport(
      client: account.client, accountDID: account.accountDID, subject: subject,
      description: post ? "Post by \(target.did.didString())" : "Account \(target.did.didString())")
  }

  private enum SafetyAction { case block, mute }

  private func performSafetyAction(_ action: SafetyAction, target: SafetyTarget) {
    guard work == nil, let account = captureAccount(), target.did.didString() != account.accountDID else { return }
    let requestID = UUID()
    generation = requestID
    errorMessage = nil
    statusMessage = nil
    work = Task { @MainActor in
      defer { if generation == requestID { work = nil } }
      do {
        guard isCurrent(account, generation: requestID) else { return }
        let finish = try appState.preferencesManager.beginSettingsAccountIO()
        defer { finish?() }
        let success: Bool
        switch action {
        case .block: success = try await appState.graphManager.block(did: target.did.didString())
        case .mute: success = try await appState.graphManager.mute(did: target.did.didString())
        }
        guard isCurrent(account, generation: requestID) else { return }
        guard success else { throw PreferencesManagerError.invalidData }
        switch action {
        case .block: blockedDID = target.did.didString(); statusMessage = "Account blocked."
        case .mute: mutedDID = target.did.didString(); statusMessage = "Account muted."
        }
      } catch {
        guard isCurrent(account, generation: requestID) else { return }
        errorMessage = "This action could not be completed. Try again."
      }
    }
  }

  private static func parseTarget(_ text: String) throws -> (actor: String, recordKey: String?) {
    if text.hasPrefix("at://") {
      let uri = try ATProtocolURI(uriString: text)
      guard uri.collection == "app.bsky.feed.post", let key = uri.recordKey else {
        throw PreferencesManagerError.invalidData
      }
      _ = try ATIdentifier(string: uri.authority)
      return (uri.authority, key)
    }
    if text.contains("://") {
      guard let url = URLComponents(string: text), url.scheme?.lowercased() == "https",
            url.host?.lowercased() == "bsky.app", url.user == nil, url.password == nil,
            url.port == nil else { throw PreferencesManagerError.invalidData }
      let path = url.path.split(separator: "/").map(String.init)
      guard (path.count == 2 || path.count == 4), path[0] == "profile",
            path.count == 2 || path[2] == "post" else { throw PreferencesManagerError.invalidData }
      _ = try ATIdentifier(string: path[1])
      return (path[1], path.count == 4 ? path[3] : nil)
    }
    let actor = text.hasPrefix("@") ? String(text.dropFirst()) : text
    _ = try ATIdentifier(string: actor)
    return (actor, nil)
  }
}
