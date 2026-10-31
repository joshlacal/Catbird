//
//  PostPresentationsModifier.swift
//  Catbird
//
//  The sheets, alerts and Copilot flow a post's options menu requests.
//

import Petrel
import SwiftUI

// MARK: - Post Presentations

/// Presents what a post's options menu and Copilot request through `PostState`: the report,
/// add-to-list, thread summary, interaction settings, labels and Copilot sheets, and the delete,
/// block, mute user and mute thread confirmations. It also carries out Copilot's confirmed
/// actions and hands Copilot's dedicated proposals (report, delete, add to list, compose) to
/// those presentations once its sheet closes.
///
/// `PostView` applies it to itself. A host that draws posts without `PostView` applies it
/// once with the `PostState`, `PostContextMenuViewModel` and `PostViewModel` of the post whose
/// menu is open. The environment must provide `AppState` and, for Copilot's compose
/// proposals, `SceneNavigationContext`.
struct PostPresentationsModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.moderationListFilterExemptDID) private var copilotListFilterExemptDID
  @Bindable var postState: PostState
  let contextMenuViewModel: PostContextMenuViewModel
  let viewModel: PostViewModel
  let visibilityContext: PostVisibilityContext

  func body(content: Content) -> some View {
    content
      .onChange(of: postState.isShowingCopilot) { wasShowing, isShowing in
        if wasShowing && !isShowing, let proposal = postState.pendingDedicatedProposal {
          postState.pendingDedicatedProposal = nil
          handleDedicatedProposal(proposal)
        }
      }
      .deferredPresentations(when: postState.hasPresentation) { anchor in
        anchor
          .sheet(isPresented: $postState.showingReportView) {
            if case .circle(let circle) = visibilityContext {
              CircleReportView(
                post: postState.currentPost,
                circle: circle
              )
            } else if let client = appState.atProtoClient {
              let reportingService = ReportingService(client: client)
              let subject = contextMenuViewModel.createReportSubject()
              let description = contextMenuViewModel.getReportDescription()

              ReportFormView(
                reportingService: reportingService,
                subject: subject,
                contentDescription: description
              )
            }
          }
          .sheet(isPresented: $postState.showingAddToListSheet) {
            AddToListSheet(
              userDID: postState.currentPostBox.value.author.did.didString(),
              userHandle: postState.currentPostBox.value.author.handle.description,
              userDisplayName: postState.currentPostBox.value.author.displayName
            )
          }
          .sheet(isPresented: $postState.isShowingThreadSummary) {
            ThreadSummarySheet(state: postState) {
              PostThreadSummarizer.summarize(state: postState, appState: appState)
            }
          }
          .sheet(isPresented: $postState.showingInteractionSettings) {
            PostInteractionSettingsView(
              post: postState.currentPost,
              rootPostURI: contextMenuViewModel.resolvedRootPostURI ?? postState.currentPostBox.value.uri,
              isRootAuthor: contextMenuViewModel.isRootAuthor
            )
          }
          .sheet(isPresented: $postState.showingLabelsOnPost) {
            if let client = appState.atProtoClient {
              let reportingService = ReportingService(client: client)
              let handle = postState.currentPostBox.value.author.handle.description
              LabelsOnMeView(
                labels: postState.allPostLabels,
                targetDescription: "Post by @\(handle)",
                viewerDID: appState.userDID,
                reportingService: reportingService
              )
            }
          }
          .sheet(isPresented: $postState.isShowingCopilot) {
            let activeContext = postState.copilotContextToPresent ?? postState.copilotContext
            CatbirdCopilotSheet(
              context: activeContext,
              imageModerationSource: copilotImageModerationSource,
              onConfirmedAction: { proposal in
                try await handleConfirmedCopilotAction(proposal, context: activeContext)
              },
              onDedicatedAction: { proposal in
                postState.pendingDedicatedProposal = proposal
              }
            )
          }
          .alert("Delete Post", isPresented: $postState.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
              Task { await contextMenuViewModel.deletePost(visibilityContext: visibilityContext) }
            }
          } message: {
            Text("Are you sure you want to delete this post? This action cannot be undone.")
          }
          .alert("Block User", isPresented: $postState.showBlockConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Block", role: .destructive) {
              Task { await contextMenuViewModel.blockUser() }
            }
          } message: {
            Text("Block @\(postState.currentPostBox.value.author.handle.description)? You won't see each other's posts, and they won't be able to follow you.")
          }
          .alert("Mute User", isPresented: $postState.showMuteUserConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Mute", role: .destructive) {
              Task { await contextMenuViewModel.muteUser() }
            }
          } message: {
            Text("Mute @\(postState.currentPostBox.value.author.handle.description)? You won't see their posts and replies in your feeds.")
          }
          .alert("Mute Thread", isPresented: $postState.showMuteThreadConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Mute", role: .destructive) {
              Task { await contextMenuViewModel.muteThread() }
            }
          } message: {
            Text("Mute this thread? You won't be notified about new replies.")
          }
      }
  }

  // MARK: - Copilot

  /// Re-read the actual active account and displayed post at every pixel boundary.
  /// The global lifecycle fence also invalidates a retained sheet when an account
  /// leaves and returns; a same-URI post cannot inherit its former authorization.
  @MainActor
  private var copilotImageModerationSource: CopilotImageModerationSource {
    let ageRevision = appState.ageAccess.revision
    return CopilotImageModerationSource { context, accountDID in
      let manager = AppStateManager.shared
      guard manager.lifecycle.appState === appState, !appState.isTransitioningAccounts,
            accountDID == appState.userDID,
            appState.ageAccess.revision == ageRevision,
            appState.ageAccess.allows(.generalContent) else { return nil }
      return CopilotImageModerationSnapshot.make(
        context: context, accountDID: accountDID,
        accountRevision: manager.settingsAccountContextRevision,
        clientID: appState.atProtoClient.map(ObjectIdentifier.init),
        post: postState.currentPost, policy: appState.moderationPolicy,
        revealedFilter: postState.revealedModerationFilter,
        listFilterExemptDID: copilotListFilterExemptDID)
    }
  }

  @MainActor
  private func handleConfirmedCopilotAction(_ proposal: CopilotProposal, context: CopilotContext) async throws {
    let currentURI = postState.currentPostBox.value.uri.uriString()
    let currentCID = postState.currentPostBox.value.cid.string
    let vm = viewModel
    let menuVm = contextMenuViewModel
    switch proposal {
    case .likePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !vm.isLiked {
        try await vm.toggleLike()
      }

    case .unlikePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if vm.isLiked {
        try await vm.toggleLike()
      }

    case .repostPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !vm.isReposted {
        try await vm.toggleRepost()
      }

    case .unrepostPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if vm.isReposted {
        try await vm.toggleRepost()
      }

    case .bookmarkPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !vm.isBookmarked {
        try await vm.toggleBookmark()
      }

    case .unbookmarkPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if vm.isBookmarked {
        try await vm.toggleBookmark()
      }

    case .hidePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if !menuVm.isPostHidden {
        await menuVm.hidePost()
      }

    case .unhidePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else {
        throw CopilotProposalError.staleTarget
      }
      if menuVm.isPostHidden {
        await menuVm.unhidePost()
      }

    default:
      try await CopilotProposalCoordinator.executeConfirmed(
        proposal,
        context: context,
        expectedAccountDID: appState.userDID,
        appState: appState
      )
    }
  }

  @MainActor
  private func handleDedicatedProposal(_ proposal: CopilotProposal) {
    let state = postState
    let currentURI = state.currentPostBox.value.uri.uriString()
    let currentCID = state.currentPostBox.value.cid.string
    let authorDID = state.currentPostBox.value.author.did.didString()

    switch proposal {
    case .reportPost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else { return }
      state.showingReportView = true

    case .deletePost(let uri, let cid):
      guard uri == currentURI && cid == currentCID else { return }
      guard authorDID == appState.userDID else { return }
      state.showDeleteConfirmation = true

    case .addActorToList(let actorDID):
      guard actorDID == authorDID else { return }
      state.showingAddToListSheet = true

    case .prepareReply(let uri, let cid, let text):
      guard uri == currentURI && cid == currentCID else { return }
      let replyDestination: CircleDestination
      if case .circle(let circle) = visibilityContext {
        replyDestination = .circle(circle)
      } else {
        replyDestination = .public
      }
      sceneContext.presentPostComposer(
        initialText: text, parentPost: state.currentPost, destination: replyDestination)

    case .prepareQuote(let uri, let cid, let text):
      guard uri == currentURI && cid == currentCID else { return }
      sceneContext.presentPostComposer(initialText: text, quotedPost: state.currentPost)
    case .preparePostDraft(let text):
      sceneContext.presentPostComposer(initialText: text)

    default:
      break
    }
  }
}

// MARK: - Thread Summary

/// Streams an on-device summary of a post's thread into `PostState` for `ThreadSummarySheet`.
@MainActor
enum PostThreadSummarizer {
#if canImport(FoundationModels)
  static func summarize(state: PostState, appState: AppState) {
    state.threadSummaryTask?.cancel()
    state.threadSummaryTask = nil

    state.isShowingThreadSummary = true
    state.isThreadSummaryLoading = true
    state.threadSummaryText = nil
    state.threadSummaryError = nil
    state.canRetryThreadSummary = false

    guard appState.atProtoClient != nil else {
      state.threadSummaryError = "Sign in to summarize threads."
      state.isThreadSummaryLoading = false
      state.canRetryThreadSummary = false
      return
    }

    if #available(iOS 26.0, macOS 26.0, *) {
      let agent = appState.blueskyAgent
      let targetURI = state.currentPost.uri

      state.threadSummaryTask = Task {
        do {
          var accumulatedText = ""
          let stream = await agent.streamThreadSummary(at: targetURI)

          for try await chunk in stream {
            guard !Task.isCancelled else { return }

            accumulatedText += chunk

            await MainActor.run {
              state.threadSummaryText = accumulatedText
            }
          }

          guard !Task.isCancelled else { return }

          await MainActor.run {
            let cleaned = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let squashed = cleaned
              .lowercased()
              .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)

            if cleaned.isEmpty || squashed.range(of: #"^(null)+$"#, options: .regularExpression) != nil {
            state.threadSummaryError = "The model couldn’t generate a summary for this thread."
            state.isThreadSummaryLoading = false
            state.canRetryThreadSummary = true
          } else {
            state.threadSummaryText = cleaned
            state.isThreadSummaryLoading = false
            state.canRetryThreadSummary = false
            }
          }
        } catch {
          guard !Task.isCancelled else { return }
          let (message, retryable) = errorMessage(for: error)
          await MainActor.run {
            state.threadSummaryError = message
            state.isThreadSummaryLoading = false
            state.canRetryThreadSummary = retryable
          }
        }
      }
    } else {
      state.threadSummaryError = "Thread summarization requires iOS 26 or later."
      state.isThreadSummaryLoading = false
      state.canRetryThreadSummary = false
    }
  }

  private static func errorMessage(for error: Error) -> (String, Bool) {
    if let agentError = error as? BlueskyAgentError {
      switch agentError {
      case .missingClient:
        return ("Sign in to summarize threads.", false)
      case .notAThread:
        return ("There isn’t enough conversation to summarize yet.", false)
      case .modelUnavailable:
        return ("Apple Intelligence is still preparing. Try again in a moment.", true)
      case .foundationModelsUnavailable:
        return ("Thread summarization isn’t available on this device.", false)
      case .invalidThreadURI:
        return ("This thread can’t be summarized.", false)
      case .emptyResult(let context):
        if context.contains("post may be deleted") {
          return ("That post isn’t available anymore, so this thread can’t be summarized.", false)
        }
        if context.hasPrefix("thread fetch") || context.contains("thread (no data") || context.contains("thread (empty") {
          return ("Couldn’t load this thread to summarize. Try again.", true)
        }
        if context.contains("no valid posts") {
          return ("There isn’t enough conversation to summarize yet.", false)
        }
        return ("Couldn’t generate a summary for this thread. Try again.", true)
      case .contextLimitExceeded:
        return ("This thread is too long to summarize.", false)
      case .underlying(let underlying):
        let message = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
        return (message, true)
      }
    }

    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    return (message, true)
  }
#else
  /// Without FoundationModels nothing offers a thread summary, so the sheet never opens.
  static func summarize(state: PostState, appState: AppState) {}
#endif
}
