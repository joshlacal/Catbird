//
//  PostComposerViewUIKit.swift
//  Catbird
//
//  A SwiftUI composer that embeds a UIKit-based text editor (UITextView)
//  for rich text editing and link creation, while reusing the existing
//  PostComposerViewModel and infrastructure.
//

import SwiftUI
import PhotosUI
import os
import Petrel
import AVFoundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

private let pcUIKitLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposerUIKit")

struct PostComposerViewUIKit: View {
  static let composerAvatarSize = DesignTokens.Size.avatarXL

  @Environment(\.dismiss) var dismiss
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(\.verticalSizeClass) private var vSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  
  // Store AppState reference locally to avoid global observation
  let appState: AppState
  let editingSession: SceneComposerEditingSession
  private let initialEditingClaim: ComposerDraftClaim?
  
  @State var viewModel: PostComposerViewModel?
  private let initialParentPost: AppBskyFeedDefs.PostView?
  private let initialQuotedPost: AppBskyFeedDefs.PostView?
  private let initialTextParam: String?
  private let restoringDraftParam: PostComposerDraft?
  private let initialCapturedMediaParam: CapturedMedia?
  // Link creation state
  @State var showingLinkCreation = false
  @State var linkSelection: ComposerLinkEdit.Selection?
  @State var linkFacets: [RichTextFacetUtils.LinkFacet] = []
  @State var pendingSelectionRange: NSRange? = nil

  // Submission
  @State var isSubmitting = false

  // Media pickers & sheets
  @State var photoPickerVisible = false
  @State var videoPickerVisible = false
  @State var photoPickerItems: [PhotosPickerItem] = []
  @State var videoPickerItems: [PhotosPickerItem] = []
  @State var pendingPasteCount = 0
  @State var showingEmojiPicker = false
  @State var showingAudioRecorder = false
  @State var showingAudioVisualizerPreview = false
  @State var showingAccountSwitcher = false
  @State var accountSwitchSnapshot: ComposerEditingSnapshot?
  @State private var initializationError: String?
  @State var showingLanguagePicker = false
  @State var showingDismissAlert = false
  @State var showingDrafts = false
  @State var showingGifPicker = false
  @State var showingThreadgate = false
  @State var showingLabelSelector = false
  @State var showingOutlineTagsEditor = false
  @State var showingPlusMenu = false
  @State var suppressAutoSaveOnDismiss = false
  @State var activeEditorFocusID = UUID()
  @State var didSetInitialFocusID = false
  private struct ReplyEditorPosition: Hashable {
    let claim: ComposerDraftClaim?
    let sourceURI: String?
  }
  @State private var positionedReply: ReplyEditorPosition?
  @State private var userScrolledReplyClaim: ComposerDraftClaim?
  /// The scroll view's unobscured height (after navigation, keyboard and footer
  /// insets). The reply area fills exactly this so the editor can sit at the top
  /// without leaving scrollable blank space below it.
  @State private var replyVisibleHeight: CGFloat = 0
  @State private var replySourcePath = NavigationPath()
  @State private var replySourceSelectedTab = 0
  @State var mentionOverlayCooldownUntil: Date = .distantPast

  @State var autoSaveTask: Task<Void, Never>?
  @State var dismissReason: DismissReason = .none
  
  init(parentPost: AppBskyFeedDefs.PostView? = nil,
       quotedPost: AppBskyFeedDefs.PostView? = nil,
       initialText: String? = nil,
       appState: AppState,
       editingSession: SceneComposerEditingSession,
       editingClaim: ComposerDraftClaim? = nil) {
    self.appState = appState
    self.editingSession = editingSession
    self.initialEditingClaim = editingClaim
    self.initialParentPost = parentPost
    self.initialQuotedPost = quotedPost
    self.initialTextParam = initialText
    self.restoringDraftParam = nil
    self.initialCapturedMediaParam = nil
  }
  
  init(restoringFromDraft draft: PostComposerDraft,
       appState: AppState,
       editingSession: SceneComposerEditingSession,
       editingClaim: ComposerDraftClaim? = nil) {
    self.appState = appState
    self.editingSession = editingSession
    self.initialEditingClaim = editingClaim
    self.initialParentPost = nil
    self.initialQuotedPost = nil
    self.initialTextParam = nil
    self.restoringDraftParam = draft
    self.initialCapturedMediaParam = nil
  }

  init(initialCapturedMedia: CapturedMedia,
       appState: AppState,
       editingSession: SceneComposerEditingSession,
       editingClaim: ComposerDraftClaim? = nil) {
    self.appState = appState
    self.editingSession = editingSession
    self.initialEditingClaim = editingClaim
    self.initialParentPost = nil
    self.initialQuotedPost = nil
    self.initialTextParam = nil
    self.restoringDraftParam = nil
    self.initialCapturedMediaParam = initialCapturedMedia
  }

  var body: some View {
    Group {
      if let vm = viewModel {
        GeometryReader { _ in
          navigationContainer(vm: vm)
            .disabled(isSubmitting || vm.isPreparingPendingAudio)
            .onAppear {
              pcUIKitLogger.info("PostComposerViewUIKit: View appeared")
            }
        }
      } else if let initializationError {
        ContentUnavailableView {
          Label("Draft Unavailable", systemImage: "doc.text")
        } description: {
          Text(initializationError)
        } actions: {
          Button("Close") { dismiss() }
            .buttonStyle(.borderedProminent)
        }
      } else {
          ProgressView().progressViewStyle(.circular)
              .onAppear {
          pcUIKitLogger.debug("PostComposerViewUIKit: Showing progress view, viewModel not ready")
      }
      }
    }
    // Identity belongs to the injected origin scene.
    .id(editingSession.sceneID)
    .interactiveDismissDisabled(hasPendingMediaIntent || isSubmitting)
    .task {
      guard viewModel == nil else { 
        pcUIKitLogger.debug("PostComposerViewUIKit: Task skipped, viewModel already exists")
        return 
      }
      let vm = PostComposerViewModel(
        parentPost: initialParentPost,
        quotedPost: initialQuotedPost,
        appState: appState,
        editingSession: editingSession
      )
      if let initialText = initialTextParam, !initialText.isEmpty {
        vm.postText = initialText
      }
      do {
        try vm.startEditing(restoring: restoringDraftParam, claim: initialEditingClaim)
      } catch {
        initializationError = error.localizedDescription
        return
      }

      viewModel = vm

      // Request focus before any asynchronous media or preference load can
      // finish after the user has already started reading the source post.
      if !didSetInitialFocusID {
        activeEditorFocusID = UUID()
        didSetInitialFocusID = true
      }

      if let capturedMedia = initialCapturedMediaParam {
        switch capturedMedia {
        case .photo(let data):
          vm.ingestCapturedPhoto(data)
        case .video(let url):
          await vm.ingestCapturedVideo(url)
        }
      }
      
      guard !Task.isCancelled, vm.ownsEditingDraft else { return }
      if restoringDraftParam == nil && initialEditingClaim == nil && vm.selectedLanguages.isEmpty {
        await vm.loadUserLanguagePreference()
      }
      guard !Task.isCancelled, vm.ownsEditingDraft else { return }
      
      startAutoSave()
    }
    .onDisappear {
      pcUIKitLogger.info("PostComposerViewUIKit: View disappearing - reason: \(String(describing: dismissReason))")
      autoSaveTask?.cancel()
      if let vm = viewModel,
         dismissReason != .submit && dismissReason != .discard,
         !suppressAutoSaveOnDismiss,
         (hasContent(vm: vm) || vm.isReply), vm.ownsEditingDraft {
        if hasPendingMediaIntent {
          vm.saveDraftIfNeeded()
        } else {
          _ = vm.minimizeEditingDraft()
        }
      }
    }
  }
  
  @ViewBuilder
  private func navigationContainer(vm: PostComposerViewModel) -> some View {
    #if os(iOS)
    NavigationStack(path: $replySourcePath) {
      mainContent(vm: vm)
        .navigationTitle(getNavigationTitle(vm: vm))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          // Leading: X button with confirmation dialog
          ToolbarItem(placement: .topBarLeading) {
            Button(action: {
              closePlusMenu()
              if hasContent(vm: vm) {
                showingDismissAlert = true
              } else {
                let ended = vm.isReply ? vm.minimizeEditingDraft() : vm.discardEditingDraft()
                guard ended else { return }
                dismissReason = .discard
                dismiss()
              }
            }) {
              Image(systemName: "xmark")
            }
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("composer-close")
            .confirmationDialog(
              "Discard Post?",
              isPresented: $showingDismissAlert,
              titleVisibility: .visible
            ) {
              Button("Save Draft") {
                guard let snapshot = vm.captureEditingSnapshot() else { return }
                do {
                  _ = try editingSession.stash(snapshot)
                  suppressAutoSaveOnDismiss = true
                  vm.clearAll()
                  dismissReason = .discard
                  dismiss()
                } catch {
                  appState.toastManager.show(
                    ToastItem(message: error.localizedDescription, icon: "exclamationmark.triangle.fill")
                  )
                }
              }
              .disabled(hasPendingMediaIntent)
              Button("Discard", role: .destructive) {
                guard vm.discardEditingDraft() else { return }
                suppressAutoSaveOnDismiss = true
                dismissReason = .discard
                dismiss()
              }
              Button("Keep Editing", role: .cancel) { }
            } message: {
              Text("You’ll lose your post if you discard now.")
            }
          }

          if !appState.composerDraftManager.savedDrafts.isEmpty {
            #if compiler(>=6.2)
            if #available(iOS 26.0, macOS 26.0, *) {
              ToolbarSpacer(.fixed, placement: .topBarLeading)
            }
            #endif
            ToolbarItem(placement: .topBarLeading) {
              Button(action: {
                closePlusMenu()
                showingDrafts = true
              }) {
                Image(systemName: "doc.text")
              }
              .accessibilityLabel("Open Drafts")
              .accessibilityIdentifier("composer-drafts")
              .disabled(hasPendingMediaIntent)
              .help("Open saved drafts")
              .nuxNudge(id: .draftsAnnouncement)
            }
          }

          // Trailing: Post button with glass effect
          ToolbarItem(placement: .primaryAction) {
#if compiler(>=6.2)
            if #available(iOS 26.0, macOS 26.0, *) {
              Button(action: {
                closePlusMenu()
                submitAction(vm: vm)
              }) {
                if isSubmitting {
                  ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                } else {
                  Image(systemName: "arrow.up")
                }
              }
              .disabled(!canSubmit(vm: vm) || isSubmitting)
              .opacity(isSubmitting ? 0.7 : 1)
              .buttonStyle(.glassProminent)
              .keyboardShortcut(.return, modifiers: .command)
              .accessibilityLabel(vm.isThreadMode ? "Post All" : "Post")
            } else {
              Button(action: {
                closePlusMenu()
                submitAction(vm: vm)
              }) {
                if isSubmitting {
                  ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                } else {
                  Image(systemName: "arrow.up")
                }
              }
              .disabled(!canSubmit(vm: vm) || isSubmitting)
              .opacity(isSubmitting ? 0.7 : 1)
              .buttonStyle(.borderedProminent)
              .buttonBorderShape(.capsule)
              .keyboardShortcut(.return, modifiers: .command)
              .accessibilityLabel(vm.isThreadMode ? "Post All" : "Post")
            }
#else
            Button(action: {
              closePlusMenu()
              submitAction(vm: vm)
            }) {
              if isSubmitting {
                ProgressView()
                  .progressViewStyle(.circular)
                  .tint(.white)
              } else {
                Image(systemName: "arrow.up")
              }
            }
            .disabled(!canSubmit(vm: vm) || isSubmitting)
            .opacity(isSubmitting ? 0.7 : 1)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(vm.isThreadMode ? "Post All" : "Post")
#endif
          }
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(destination, path: $replySourcePath,
                                               appState: appState, selectedTab: $replySourceSelectedTab)
        }
    }
    #else
    NavigationStack(path: $replySourcePath) {
      mainContent(vm: vm)
        .navigationTitle(getNavigationTitle(vm: vm))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              if hasContent(vm: vm) {
                showingDismissAlert = true
              } else {
                let ended = vm.isReply ? vm.minimizeEditingDraft() : vm.discardEditingDraft()
                guard ended else { return }
                dismissReason = .discard
                dismiss()
              }
            }
            .confirmationDialog(
              "Discard Post?",
              isPresented: $showingDismissAlert,
              titleVisibility: .visible
            ) {
              Button("Discard", role: .destructive) {
                suppressAutoSaveOnDismiss = true
                guard vm.discardEditingDraft() else { return }
                dismissReason = .discard
                dismiss()
              }
              Button("Keep Editing", role: .cancel) { }
            } message: {
              Text("You’ll lose your post if you discard now.")
            }
          }
          ToolbarItem(placement: .primaryAction) {
            Button(action: { submitAction(vm: vm) }) {
              if isSubmitting {
                ProgressView().progressViewStyle(.circular)
              } else {
                Image(systemName: "arrow.up")
              }
            }
            .disabled(!canSubmit(vm: vm) || isSubmitting)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(vm.isThreadMode ? "Post All" : "Post")
          }
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(destination, path: $replySourcePath,
                                               appState: appState, selectedTab: $replySourceSelectedTab)
        }
    }
    #endif
  }
  
  private func getNavigationTitle(vm: PostComposerViewModel) -> String {
    if vm.isReply {
      return "Reply"
    } else if vm.isThreadMode {
      return "Thread"
    } else {
      return "Post"
    }
  }
  
  @ViewBuilder
  private func mainContent(vm: PostComposerViewModel) -> some View {
    let compactReply = usesCompactReplyLayout(vm: vm)
    let initialPosition = ReplyEditorPosition(claim: vm.editingClaim, sourceURI: vm.parentPost?.uri.uriString())
    sheetModifiers(vm: vm,
      GeometryReader { geometry in
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              if let parent = vm.parentPost {
                let avatarSize = compactReply && !vm.isThreadMode
                  ? DesignTokens.Size.avatarMD : Self.composerAvatarSize
                ReplySourcePostView(post: parent, avatarSize: avatarSize, path: $replySourcePath)
                  .padding(.horizontal, 16)
                  .padding(.bottom, 16)
                  .background(alignment: .topLeading) {
                    Rectangle()
                      .fill(Color.systemGray4)
                      .frame(width: 2)
                      .padding(.top, avatarSize + 4)
                      // Match the gap below the source avatar so the line stops short of the reply avatar.
                      .padding(.bottom, 4)
                      .padding(.leading, 16 + (avatarSize - 2) / 2)
                      .allowsHitTesting(false)
                      .accessibilityHidden(true)
                  }
              } else if vm.isReply {
                ReplySourceUnavailableView(vm: vm)
              }

              VStack(spacing: 16) {
                if !vm.isThreadMode {
                  composerEditorSection(vm: vm)
                    .id("reply-editor")
                  mentionSuggestionsSection(vm: vm)
                  mediaAttachmentsSection(vm: vm)
                  metadataSection(vm: vm)
                }
                threadEntriesSection(vm: vm)
              }
              .frame(minHeight: vm.isReply ? replyMinimumHeight(fallback: geometry.size.height) : nil,
                     alignment: .top)
            }
            .padding(.top, compactReply ? 0 : 8)
          }
          .accessibilityIdentifier("reply-composer-scroll")
          .onScrollGeometryChange(for: CGFloat.self) { scrollGeometry in
            scrollGeometry.containerSize.height - scrollGeometry.contentInsets.top
              - scrollGeometry.contentInsets.bottom
          } action: { _, visibleHeight in
            replyVisibleHeight = max(0, visibleHeight)
          }
          .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting || phase == .decelerating {
              userScrolledReplyClaim = vm.editingClaim
            }
          }
          .task(id: initialPosition) {
            guard let uri = initialPosition.sourceURI, positionedReply != initialPosition,
                  userScrolledReplyClaim != vm.editingClaim else { return }
            await Task.yield()
            guard !Task.isCancelled, vm.parentPost?.uri.uriString() == uri,
                  initialPosition.claim == vm.editingClaim,
                  userScrolledReplyClaim != vm.editingClaim else { return }
            scrollToReplyEditor(proxy, vm: vm)
            positionedReply = initialPosition
          }
          .onChange(of: vm.currentThreadIndex) { _, _ in
            if vm.isThreadMode { scrollToReplyEditor(proxy, vm: vm) }
          }
        }
      }
      .background(Color.systemBackground)
      .overlay {
        if showingPlusMenu {
          Button(action: closePlusMenu) {
            Color.black.opacity(0.12)
              .ignoresSafeArea()
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Dismiss menu")
        }
      }
      .safeAreaInset(edge: .bottom) {
        composerAccessoryStack(vm: vm)
      }
      .onChange(of: showingPlusMenu) { _, isOpen in
        #if os(iOS)
        if isOpen {
          vm.activeRichTextView?.resignFirstResponder()
        } else if !isPresentingFromPlusMenu {
          activeEditorFocusID = UUID()
        }
        #endif
      }
    )
  }

  private func usesCompactReplyLayout(vm: PostComposerViewModel) -> Bool {
    #if os(iOS)
    return vm.parentPost != nil && vSize == .compact
    #else
    return false
    #endif
  }

  private func replyMinimumHeight(fallback: CGFloat) -> CGFloat {
    replyVisibleHeight > 1 ? min(replyVisibleHeight, fallback) : fallback
  }

  private func scrollToReplyEditor(_ proxy: ScrollViewProxy, vm: PostComposerViewModel) {
    if vm.isThreadMode, vm.threadEntries.indices.contains(vm.currentThreadIndex) {
      proxy.scrollTo(vm.threadEntries[vm.currentThreadIndex].id, anchor: .top)
    } else {
      proxy.scrollTo("reply-editor", anchor: .top)
    }
  }

  private func composerAccessoryStack(vm: PostComposerViewModel) -> some View {
    let compactReply = usesCompactReplyLayout(vm: vm)
    let layout = compactReply
      ? AnyLayout(HStackLayout(spacing: 8))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
    return layout {
      ComposerChipsStrip(
        outlineTags: vm.outlineTags,
        selectedLanguages: vm.selectedLanguages,
        selectedLabels: vm.selectedLabels,
        interactionSettings: vm.interactionSettings,
        suggestedLanguage: vm.suggestedLanguage,
        hasText: !vm.postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        onRemoveTag: { tag in
          closePlusMenu()
          vm.outlineTags.removeAll { $0 == tag }
        },
        onToggleLanguage: { language in
          closePlusMenu()
          vm.toggleLanguage(language)
        },
        onApplySuggestedLanguage: {
          closePlusMenu()
          vm.applySuggestedLanguage()
        },
        onEditInteractionSettings: {
          closePlusMenu()
          showingThreadgate = true
        },
        onEditLabels: {
          closePlusMenu()
          showingLabelSelector = true
        },
        showsInteractionSettings: !vm.isReply
      )
      .frame(maxWidth: compactReply ? .infinity : nil, alignment: .leading)

      ComposerAccessoryBar(
        isPlusMenuOpen: $showingPlusMenu,
        characterCount: vm.postText.count,
        allowTenor: appState.appSettings.externalMediaConsent(for: .klipy) != .hide,
        isAddToThreadDisabled: hasPendingMediaIntent,
        showsThreadgate: !vm.isReply,
        threadgateValue: vm.interactionSettings.summary,
        languageValue: languageSummary(vm: vm),
        actions: ComposerBarActions(
          onPhotos: { presentPhotoPicker(vm: vm) },
          onVideo: { videoPickerVisible = true },
          onGif: { showingGifPicker = true },
          onAudio: {
            if vm.pendingAudioURL != nil { showingAudioVisualizerPreview = true }
            else { showingAudioRecorder = true }
          },
          onLink: { presentLinkCreation(vm: vm) },
          onThreadgate: { showingThreadgate = true },
          onLanguage: { showingLanguagePicker = true },
          onTags: { showingOutlineTagsEditor = true },
          onLabels: { showingLabelSelector = true },
          onAddToThread: {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
              if vm.isThreadMode {
                vm.addNewThreadEntry()
              } else {
                vm.enterThreadMode()
                vm.addNewThreadEntry()
              }
              activeEditorFocusID = UUID()
            }
          }
        )
      )
      .disabled(hasPendingMediaIntent)
      .fixedSize(horizontal: compactReply, vertical: compactReply)
    }
    .padding(.horizontal, 16)
    .padding(.top, compactReply ? 0 : 4)
    .padding(.bottom, compactReply ? 0 : 8)
  }

  private func languageSummary(vm: PostComposerViewModel) -> String {
    if vm.selectedLanguages.isEmpty {
      let code = Locale.current.language.languageCode?.identifier ?? "en"
      return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    return vm.selectedLanguages
      .map { ComposerChipsStrip.languageDisplayName($0) }
      .joined(separator: ", ")
  }

  private var isPresentingFromPlusMenu: Bool {
    photoPickerVisible || videoPickerVisible || showingGifPicker
      || showingAudioRecorder || showingLinkCreation || showingThreadgate
      || showingLanguagePicker || showingOutlineTagsEditor
      || showingLabelSelector || showingDrafts || showingAccountSwitcher
      || showingDismissAlert
  }

  var hasPendingMediaIntent: Bool {
    photoPickerVisible || videoPickerVisible || showingGifPicker || showingAudioRecorder
      || showingAudioVisualizerPreview || !photoPickerItems.isEmpty || !videoPickerItems.isEmpty
      || pendingPasteCount > 0 || viewModel?.isPreparingPendingAudio == true
  }

  private func closePlusMenu() {
    guard showingPlusMenu else { return }
    withAnimation(ComposerAccessoryBar.menuAnimation(reduceMotion: reduceMotion)) {
      showingPlusMenu = false
    }
  }
  
  @ViewBuilder
  private func composerEditorSection(vm: PostComposerViewModel) -> some View {
    let avatarSize = usesCompactReplyLayout(vm: vm) ? DesignTokens.Size.avatarMD : Self.composerAvatarSize
    HStack(alignment: .top, spacing: 12) {
      // Tappable avatar that opens account switcher
      Button(action: {
        pcUIKitLogger.info("PostComposerViewUIKit: Avatar tapped - opening account switcher")
        if hasContent(vm: vm) {
          vm.saveDraftIfNeeded()
        }
        accountSwitchSnapshot = vm.captureEditingSnapshot()
        showingAccountSwitcher = accountSwitchSnapshot != nil
      }) {
        #if os(iOS)
        UIKitAvatarView(
          did: appState.userDID,
          client: appState.atProtoClient,
          size: avatarSize,
          avatarURL: appState.currentUserProfile?.finalAvatarURL()
        )
        .frame(width: avatarSize, height: avatarSize)
        .contentShape(Circle())
        .clipShape(Circle())
        .clipped()
        #else
        if let profile = appState.currentUserProfile, let avatarURL = profile.avatar {
          AsyncImage(url: URL(string: avatarURL.description)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
          } placeholder: {
            Circle().fill(Color.systemGray5)
          }
          .frame(width: avatarSize, height: avatarSize)
          .clipShape(Circle())
        } else {
          Circle().fill(Color.systemGray5)
            .frame(width: avatarSize, height: avatarSize)
        }
        #endif
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Switch account")
      .accessibilityHint("Tap to switch between accounts")
      .disabled(hasPendingMediaIntent)
      
      RichEditorContainer(
        attributedText: Binding(
          get: { vm.richAttributedText },
          set: { vm.richAttributedText = $0 }
        ),
        linkFacets: $linkFacets,
        pendingSelectionRange: $pendingSelectionRange,
        placeholder: vm.isReply ? "Write your reply…" : "What’s on your mind?",
        onImagePasted: { image in
          pcUIKitLogger.info("PostComposerViewUIKit: Image pasted into editor")
          #if os(iOS)
          pendingPasteCount += 1
          Task {
            defer { pendingPasteCount -= 1 }
            await vm.handleMediaPaste([NSItemProvider(object: image)])
          }
          #endif
        },
        onGenmojiDetected: { emojis in
          pcUIKitLogger.info("PostComposerViewUIKit: Detected genmoji: \(emojis)")
        },
        onTextChanged: { attrString, cursorPos in
          vm.updateFromAttributedText(attrString, cursorPosition: cursorPos)
          vm.updateManualLinkFacets(from: linkFacets)
        },
        onLinkCreationRequested: { selectedText, range in
          pcUIKitLogger.info("PostComposerViewUIKit: Link creation requested - text: '\(selectedText)', range: \(range)")
          presentLinkCreation(vm: vm, suggestedRange: range)
        },
        // Avoid auto-focus on every attach to prevent keyboard reloads.
        focusOnAppear: false,
        focusActivationID: activeEditorFocusID,
        onPhotosAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Photos action triggered")
          presentPhotoPicker(vm: vm)
        },
        onVideoAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Video action triggered")
          videoPickerVisible = true 
        },
        onAudioAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Audio action triggered")
          if vm.pendingAudioURL != nil { showingAudioVisualizerPreview = true }
          else { showingAudioRecorder = true } 
        },
        onGifAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: GIF action triggered")
          showingGifPicker = true
        },
        onLabelsAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Labels action triggered")
          showingLabelSelector = true
        },
        onThreadgateAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Threadgate action triggered")
          showingThreadgate = true
        },
        onLanguageAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Language action triggered")
          showingLanguagePicker = true 
        },
        onThreadAction: { 
          guard !hasPendingMediaIntent else { return }
          pcUIKitLogger.info("PostComposerViewUIKit: Thread action triggered - isThreadMode: \(viewModel?.isThreadMode ?? false)")
          guard let vm = viewModel else { return }
          withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            // Properly enter thread mode and add a new entry,
            // mirroring the legacy behavior.
            if vm.isThreadMode {
              pcUIKitLogger.debug("PostComposerViewUIKit: Adding new thread entry to existing thread")
              vm.addNewThreadEntry()
              activeEditorFocusID = UUID()
            } else {
              pcUIKitLogger.debug("PostComposerViewUIKit: Entering thread mode and adding first entry")
              vm.enterThreadMode()
              if vm.isThreadMode {
                vm.addNewThreadEntry()
                activeEditorFocusID = UUID()
              }
            }
          }
        },
        onLinkAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Link action triggered")
          presentLinkCreation(vm: vm)
        },
        		allowTenor: appState.appSettings.externalMediaConsent(for: .klipy) != .hide,
        onTextViewCreated: { textView in
          pcUIKitLogger.debug("PostComposerViewUIKit: Text view created")
          #if os(iOS)
          vm.activeRichTextView = textView
          #endif
        }
      )
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .onAppear {
        pcUIKitLogger.debug("PostComposerViewUIKit: Rendering composer editor section")
    }
  }
  
  func startAutoSave() {
    autoSaveTask?.cancel()
    guard let vm = viewModel, let claim = vm.editingClaim else { return }
    autoSaveTask = Task { @MainActor in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled, vm.ownsEditingDraft, vm.editingClaim == claim else { return }
        vm.saveDraftIfNeeded(claim: claim)
      }
    }
  }

  func hasContent(vm: PostComposerViewModel) -> Bool {
    return vm.hasMeaningfulDraftContent || hasPendingMediaIntent
  }
}
