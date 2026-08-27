//
//  PostInteractionSettingsView.swift
//  Catbird
//

import Petrel
import SwiftUI

public struct PostInteractionSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservationIgnored @Environment(AppState.self) private var appState

  private var externalBinding: Binding<PostInteractionSettingsState>?
  private let post: AppBskyFeedDefs.PostView?
  private let rootPostURI: ATProtocolURI?
  private let isRootAuthor: Bool
  private let isPostPublishMode: Bool
  private let canEditThreadgate: Bool

  @State private var localSettings: PostInteractionSettingsState
  @State private var initialSettings: PostInteractionSettingsState?
  @State private var userLists: [AppBskyGraphDefs.ListView] = []
  @State private var isLoadingLists = false
  @State private var isLoadingRecords = false
  @State private var loadFailed = false
  @State private var isSaving = false
  @State private var errorMessage: String?
  /// Composer mode initializer
  public init(
    settings: Binding<PostInteractionSettingsState>,
    canEditThreadgate: Bool = true
  ) {
    self.externalBinding = settings
    self.post = nil
    self.rootPostURI = nil
    self.isRootAuthor = canEditThreadgate
    self.isPostPublishMode = false
    self.canEditThreadgate = canEditThreadgate

    let initial = settings.wrappedValue
    _localSettings = State(initialValue: initial)
  }

  /// Post-publish editing mode initializer (G12)
  public init(
    post: AppBskyFeedDefs.PostView,
    rootPostURI: ATProtocolURI? = nil,
    isRootAuthor: Bool = true
  ) {
    self.externalBinding = nil
    self.post = post
    self.rootPostURI = rootPostURI
    self.isRootAuthor = isRootAuthor
    self.isPostPublishMode = true
    self.canEditThreadgate = isRootAuthor

    let initial = PostInteractionSettingsState()
    _localSettings = State(initialValue: initial)
  }

  public var body: some View {
    NavigationStack {
      Form {
        if let errorMessage {
          Section {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
              Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.red)
              if loadFailed {
                Spacer()
                Button("Retry") {
                  Task {
                    await loadExistingRecords()
                  }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
              }
            }
          }
        }
        // Section 1: Who can reply
        Section {
          Button(action: {
            localSettings.threadgate.selectOption(.everybody)
            syncExternalSettings()
          }) {
            HStack {
              Image(systemName: ThreadgateSettings.ReplyOption.everybody.iconName)
                .frame(width: 24)
                .foregroundStyle(.primary)

              Text(ThreadgateSettings.ReplyOption.everybody.rawValue)
                .foregroundStyle(.primary)

              Spacer()

              if localSettings.threadgate.primaryOption == .everybody
                && localSettings.threadgate.enabledOptions.isEmpty {
                Image(systemName: "checkmark")
                  .foregroundStyle(Color.accentColor)
              }
            }
          }
          .buttonStyle(.plain)
          .disabled(!canEditThreadgate || loadFailed || isLoadingRecords)

          Button(action: {
            localSettings.threadgate.selectOption(.nobody)
            syncExternalSettings()
          }) {
            HStack {
              Image(systemName: ThreadgateSettings.ReplyOption.nobody.iconName)
                .frame(width: 24)
                .foregroundStyle(.primary)

              Text(ThreadgateSettings.ReplyOption.nobody.rawValue)
                .foregroundStyle(.primary)

              Spacer()

              if localSettings.threadgate.primaryOption == .nobody
                && localSettings.threadgate.enabledOptions.isEmpty {
                Image(systemName: "checkmark")
                  .foregroundStyle(Color.accentColor)
              }
            }
          }
          .buttonStyle(.plain)
          .disabled(!canEditThreadgate || loadFailed || isLoadingRecords)
        } header: {
          Text("Who can reply")
        } footer: {
          if !canEditThreadgate {
            Text("Only the thread author can adjust who can reply.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        // Combined options
        if canEditThreadgate {
          Section {
            ForEach(
              ThreadgateSettings.ReplyOption.allCases.filter {
                $0 != .everybody && $0 != .nobody
              }
            ) { option in
              Button(action: {
                toggleOption(option)
              }) {
                HStack {
                  Image(systemName: option.iconName)
                    .frame(width: 24)
                    .foregroundStyle(.primary)

                  Text(option.rawValue)
                    .foregroundStyle(.primary)

                  Spacer()

                  if localSettings.threadgate.enabledOptions.contains(option) {
                    Image(systemName: "checkmark")
                      .foregroundStyle(Color.accentColor)
                  }
                }
              }
              .buttonStyle(.plain)
              .disabled(loadFailed || isLoadingRecords)
            }
          } header: {
            Text("Or combine these options")
          }

          // Custom lists
          if !userLists.isEmpty || isLoadingLists {
            Section {
              if isLoadingLists {
                HStack {
                  Spacer()
                  ProgressView()
                  Spacer()
                }
              } else {
                ForEach(userLists, id: \.uri) { list in
                  Button(action: {
                    toggleList(list)
                  }) {
                    HStack {
                      Image(systemName: "list.bullet")
                        .frame(width: 24)
                        .foregroundStyle(.primary)

                      Text(list.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                      Spacer()

                      if localSettings.threadgate.selectedLists.contains(list.uri.uriString()) {
                        Image(systemName: "checkmark")
                          .foregroundStyle(Color.accentColor)
                      }
                    }
                  }
                  .buttonStyle(.plain)
                  .disabled(loadFailed || isLoadingRecords)
                }
              }
            } header: {
              Text("User lists")
            }
          }
        }
        // Section 2: Quote posts
        Section {
          Toggle(isOn: $localSettings.allowQuotes) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Allow quote posts")
                .foregroundStyle(.primary)
            }
          }
          .onChange(of: localSettings.allowQuotes) { _, _ in
            syncExternalSettings()
          }
          .disabled(loadFailed || isLoadingRecords)
        } header: {
          Text("Quote posts")
        } footer: {
          Text("If turned off, other users won't be able to quote this post.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Interaction settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if isPostPublishMode {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              dismiss()
            }
            .disabled(isSaving)
          }

          ToolbarItem(placement: .confirmationAction) {
            if isSaving {
              ProgressView()
            } else {
              Button("Save") {
                Task {
                  await savePostPublishSettings()
                }
              }
              .disabled(isLoadingRecords || loadFailed)
            }
          }
        } else {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              dismiss()
            }
          }
        }
      }
      .task {
        if isPostPublishMode {
          await loadExistingRecords()
        }
        if canEditThreadgate {
          await loadUserLists()
        }
      }
    }
  }

  private func syncExternalSettings() {
    externalBinding?.wrappedValue = localSettings
  }

  private func toggleOption(_ option: ThreadgateSettings.ReplyOption) {
    localSettings.threadgate.toggleOption(option)
    syncExternalSettings()
  }

  private func toggleList(_ list: AppBskyGraphDefs.ListView) {
    let listURI = list.uri.uriString()
    localSettings.threadgate.toggleList(listURI)
    syncExternalSettings()
  }

  private func loadUserLists() async {
    guard let client = appState.atProtoClient else { return }

    isLoadingLists = true
    defer { isLoadingLists = false }

    do {
      let did = appState.userDID
      let params = AppBskyGraphGetLists.Parameters(
        actor: try ATIdentifier(string: did),
        limit: 50,
        cursor: nil
      )

      let (code, output) = try await client.app.bsky.graph.getLists(input: params)
      if code == 200, let output = output {
        userLists = output.lists
      }
    } catch {
      // User lists loading failed, degrade gracefully
    }
  }

  private func isRecordNotFoundError(_ error: Error) -> Bool {
    if let protoError = error as? ATProtoError<ComAtprotoRepoGetRecord.Error>, protoError.error == .recordNotFound {
      return true
    }
    if let directError = error as? ComAtprotoRepoGetRecord.Error, directError == .recordNotFound {
      return true
    }
    if let xrpcError = error as? ATProtoXRPCError, xrpcError.error == "RecordNotFound" {
      return true
    }
    return false
  }

  private func loadExistingRecords() async {
    guard let client = appState.atProtoClient, let post = post else { return }
    isLoadingRecords = true
    loadFailed = false
    errorMessage = nil
    defer { isLoadingRecords = false }

    let did = appState.userDID
    let targetRootURI = rootPostURI ?? post.uri
    var existingTg: AppBskyFeedThreadgate?
    var existingPg: AppBskyFeedPostgate?

    // 1. Fetch threadgate if root author
    if isRootAuthor, let rootRkey = targetRootURI.recordKey {
      do {
        let params = ComAtprotoRepoGetRecord.Parameters(
          repo: try ATIdentifier(string: did),
          collection: try NSID(nsidString: "app.bsky.feed.threadgate"),
          rkey: try RecordKey(keyString: rootRkey)
        )
        let (code, output) = try await client.com.atproto.repo.getRecord(input: params)
        if (200...299).contains(code) {
          if let record = output, case let .knownType(val) = record.value {
            existingTg = val as? AppBskyFeedThreadgate
          }
        } else {
          throw PostManager.AuthError.badResponse(code)
        }
      } catch {
        if isRecordNotFoundError(error) {
          existingTg = nil
        } else {
          loadFailed = true
          errorMessage = "Failed to load threadgate settings: \(error.localizedDescription)"
          return
        }
      }
    }

    // 2. Fetch postgate for post
    if let postRkey = post.uri.recordKey {
      do {
        let params = ComAtprotoRepoGetRecord.Parameters(
          repo: try ATIdentifier(string: did),
          collection: try NSID(nsidString: "app.bsky.feed.postgate"),
          rkey: try RecordKey(keyString: postRkey)
        )
        let (code, output) = try await client.com.atproto.repo.getRecord(input: params)
        if (200...299).contains(code) {
          if let record = output, case let .knownType(val) = record.value {
            existingPg = val as? AppBskyFeedPostgate
          }
        } else {
          throw PostManager.AuthError.badResponse(code)
        }
      } catch {
        if isRecordNotFoundError(error) {
          existingPg = nil
        } else {
          loadFailed = true
          errorMessage = "Failed to load postgate settings: \(error.localizedDescription)"
          return
        }
      }
    }

    let loadedSettings = PostInteractionSettingsState(
      threadgateRecord: existingTg,
      postgateRecord: existingPg
    )
    initialSettings = loadedSettings
    localSettings = loadedSettings
  }

  private func savePostPublishSettings() async {
    guard let post = post else { return }
    isSaving = true
    errorMessage = nil

    if let initial = initialSettings, initial == localSettings {
      dismiss()
      return
    }

    do {
      let targetRootURI = rootPostURI ?? post.uri
      try await appState.postManager.updateInteractionSettings(
        postURI: post.uri,
        rootPostURI: targetRootURI,
        settings: localSettings
      )

      await MainActor.run {
        appState.toastManager.show(
          ToastItem(
            message: "Interaction settings updated",
            icon: "checkmark.circle.fill",
            duration: 2.5
          )
        )
        NotificationCenter.default.post(name: .threadUpdated, object: nil)
        NotificationCenter.default.post(name: .feedUpdated, object: nil)
        dismiss()
      }
    } catch {
      errorMessage = "Failed to update interaction settings: \(error.localizedDescription)"
      isSaving = false
    }
  }

}
