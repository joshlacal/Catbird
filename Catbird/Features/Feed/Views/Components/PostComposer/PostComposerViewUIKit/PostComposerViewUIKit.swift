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
  @Environment(\.dismiss) var dismiss
  @Environment(\.horizontalSizeClass) private var hSize
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
  @State var showingEmojiPicker = false
  @State var showingAudioRecorder = false
  @State var showingAudioVisualizerPreview = false
  @State var currentAudioURL: URL?
  @State var currentAudioDuration: TimeInterval = 0
  @State var isGeneratingVisualizerVideo = false
  @State var visualizerService: AudioVisualizerService? = nil
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
            .disabled(isSubmitting)
            .onAppear {
              pcUIKitLogger.info("PostComposerViewUIKit: View appeared")
            }
        }
      } else if let initializationError {
        ContentUnavailableView("Draft Unavailable", systemImage: "doc.text", description: Text(initializationError))
      } else {
          ProgressView().progressViewStyle(.circular)
              .onAppear {
          pcUIKitLogger.debug("PostComposerViewUIKit: Showing progress view, viewModel not ready")
      }
      }
    }
    // Identity belongs to the injected origin scene.
    .id(editingSession.sceneID)
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

      if let capturedMedia = initialCapturedMediaParam {
        switch capturedMedia {
        case .photo(let data):
          vm.ingestCapturedPhoto(data)
        case .video(let url):
          await vm.ingestCapturedVideo(url)
        }
      }
      
      guard !Task.isCancelled, vm.ownsEditingDraft else { return }
      await vm.loadUserLanguagePreference()
      guard !Task.isCancelled, vm.ownsEditingDraft else { return }
      
      if !didSetInitialFocusID {
        activeEditorFocusID = UUID()
        didSetInitialFocusID = true
        pcUIKitLogger.debug("PostComposerViewUIKit: Set initial focus ID")
      }
      startAutoSave()
    }
    .onDisappear {
      pcUIKitLogger.info("PostComposerViewUIKit: View disappearing - reason: \(String(describing: dismissReason))")
      autoSaveTask?.cancel()
      if let vm = viewModel,
         dismissReason != .submit && dismissReason != .discard,
         !suppressAutoSaveOnDismiss,
         hasContent(vm: vm), vm.ownsEditingDraft, let claim = vm.editingClaim {
        vm.saveDraftIfNeeded(claim: claim)
        _ = editingSession.minimize(claim: claim)
      }
    }
  }
  
  @ViewBuilder
  private func navigationContainer(vm: PostComposerViewModel) -> some View {
    #if os(iOS)
    NavigationStack {
      mainContent(vm: vm)
        .navigationTitle(getNavigationTitle(vm: vm))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          // Leading: X button with confirmation dialog
          ToolbarItem(placement: .cancellationAction) {
            Button(action: {
              closePlusMenu()
              if hasContent(vm: vm) {
                showingDismissAlert = true
              } else {
                dismissReason = .discard
                guard vm.discardEditingDraft() else { return }
                dismiss()
              }
            }) {
              Image(systemName: "xmark")
            }
            .accessibilityLabel("Cancel")
            .confirmationDialog(
              "Discard post?",
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
              Button("Discard", role: .destructive) {
                guard vm.discardEditingDraft() else { return }
                suppressAutoSaveOnDismiss = true
                dismissReason = .discard
                dismiss()
              }
              Button("Keep Editing", role: .cancel) { }
            } message: {
              Text("You'll lose your post if you discard now.")
            }
          }

          // Drafts button next to X on leading side
          ToolbarItem(placement: .cancellationAction) {
            if !appState.composerDraftManager.savedDrafts.isEmpty {
              Button(action: {
                closePlusMenu()
                showingDrafts = true
              }) {
                Image(systemName: "doc.text")
              }
              .accessibilityLabel("Open Drafts")
              .help("Open saved drafts")
              .nuxNudge(id: .draftsAnnouncement)
            }
          }



          // Only the 'Open Drafts' button remains visible; 'Save Draft' lives in the discard dialog.

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
                    .foregroundStyle(Color.white)
                } else {
                  Image(systemName: "arrow.up")
                    .foregroundStyle(Color.white)
                }
              }
              .disabled(!canSubmit(vm: vm) || isSubmitting)
              .opacity(isSubmitting ? 0.7 : 1)
              .keyboardShortcut(.return, modifiers: .command)
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
                  .foregroundStyle(Color.white)
              } else {
                Image(systemName: "arrow.up")
                  .foregroundStyle(Color.white)
              }
            }
            .disabled(!canSubmit(vm: vm) || isSubmitting)
            .opacity(isSubmitting ? 0.7 : 1)
            .keyboardShortcut(.return, modifiers: .command)
#endif
          }
        }
        // Force toolbar re-render when drafts count changes
        .id("toolbar-\(appState.composerDraftManager.savedDrafts.count)")
    }
    #else
    NavigationStack {
      mainContent(vm: vm)
        .navigationTitle(getNavigationTitle(vm: vm))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              if hasContent(vm: vm) {
                showingDismissAlert = true
              } else {
                dismissReason = .discard
                guard vm.discardEditingDraft() else { return }
                dismiss()
              }
            }
            .confirmationDialog(
              "Discard post?",
              isPresented: $showingDismissAlert,
              titleVisibility: .visible
            ) {
              Button("Discard", role: .destructive) {
                suppressAutoSaveOnDismiss = true
                dismissReason = .discard
                guard vm.discardEditingDraft() else { return }
                dismiss()
              }
              Button("Keep Editing", role: .cancel) { }
            } message: {
              Text("You'll lose your post if you discard now.")
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
    }
    #endif
  }
  
  private func getNavigationTitle(vm: PostComposerViewModel) -> String {
    if vm.parentPost != nil {
      return "Reply"
    } else if vm.isThreadMode {
      return "Thread"
    } else {
      return "Post"
    }
  }
  
  @ViewBuilder
  private func mainContent(vm: PostComposerViewModel) -> some View {
    sheetModifiers(vm: vm,
      ScrollView {
        VStack(spacing: 16) {
          // Show a single editor instance.
          // In thread mode, the active editor is rendered inside threadEntriesSection.
          if !vm.isThreadMode {
            composerEditorSection(vm: vm)
            mentionSuggestionsSection(vm: vm)
            mediaAttachmentsSection(vm: vm)
            metadataSection(vm: vm)
          }
          threadEntriesSection(vm: vm)
        }
        .padding(.top, 8)
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

  private func composerAccessoryStack(vm: PostComposerViewModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
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
        }
      )

      ComposerAccessoryBar(
        isPlusMenuOpen: $showingPlusMenu,
        characterCount: vm.postText.count,
        allowTenor: appState.appSettings.externalMediaConsent(for: .tenor) != .hide,
        threadgateValue: vm.interactionSettings.summary,
        languageValue: languageSummary(vm: vm),
        actions: ComposerBarActions(
          onPhotos: { presentPhotoPicker(vm: vm) },
          onVideo: { videoPickerVisible = true },
          onGif: { showingGifPicker = true },
          onAudio: { showingAudioRecorder = true },
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
    }
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 8)
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

  private func closePlusMenu() {
    guard showingPlusMenu else { return }
    withAnimation(ComposerAccessoryBar.menuAnimation(reduceMotion: reduceMotion)) {
      showingPlusMenu = false
    }
  }
  
  @ViewBuilder
  private func composerEditorSection(vm: PostComposerViewModel) -> some View {
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
          size: 40,
          avatarURL: appState.currentUserProfile?.finalAvatarURL()
        )
        .frame(width: 40, height: 40)
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
          .frame(width: 40, height: 40)
          .clipShape(Circle())
        } else {
          Circle().fill(Color.systemGray5).frame(width: 40, height: 40)
        }
        #endif
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Switch account")
      .accessibilityHint("Tap to switch between accounts")
      
      RichEditorContainer(
        attributedText: Binding(
          get: { vm.richAttributedText },
          set: { vm.richAttributedText = $0 }
        ),
        linkFacets: $linkFacets,
        pendingSelectionRange: $pendingSelectionRange,
        placeholder: vm.parentPost != nil ? "Write your reply..." : "What's on your mind?",
        onImagePasted: { image in
          pcUIKitLogger.info("PostComposerViewUIKit: Image pasted into editor")
          #if os(iOS)
          Task {
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
          showingAudioRecorder = true 
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
        		allowTenor: appState.appSettings.externalMediaConsent(for: .tenor) != .hide,
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
    return vm.hasContent
  }
}
