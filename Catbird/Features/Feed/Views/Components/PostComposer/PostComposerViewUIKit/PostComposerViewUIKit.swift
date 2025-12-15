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
  
  // Store AppState reference locally to avoid global observation
 let appState: AppState
  
  @State var viewModel: PostComposerViewModel?
  private let initialParentPost: AppBskyFeedDefs.PostView?
  private let initialQuotedPost: AppBskyFeedDefs.PostView?
  private let restoringDraftParam: PostComposerDraft?
  
  // Link creation state
  @State var showingLinkCreation = false
  @State var selectedTextForLink: String = ""
  @State var selectedRangeForLink: NSRange = .init(location: 0, length: 0)
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
  @State var showingLanguagePicker = false
  @State var showingDismissAlert = false
  @State var showingDrafts = false
  @State var showingGifPicker = false
  @State var showingThreadgate = false
  @State var showingLabelSelector = false
  @State private var suppressAutoSaveOnDismiss = false
  @State var activeEditorFocusID = UUID()
  @State var didSetInitialFocusID = false
  @State var mentionOverlayCooldownUntil: Date = .distantPast
  
  @State var autoSaveTask: Task<Void, Never>?
  @State var dismissReason: DismissReason = .none
  
  init(parentPost: AppBskyFeedDefs.PostView? = nil,
       quotedPost: AppBskyFeedDefs.PostView? = nil,
       appState: AppState) {
    self.appState = appState
    self.initialParentPost = parentPost
    self.initialQuotedPost = quotedPost
    self.restoringDraftParam = nil
  }
  
  init(restoringFromDraft draft: PostComposerDraft,
       appState: AppState) {
    self.appState = appState
    self.initialParentPost = nil
    self.initialQuotedPost = nil
    self.restoringDraftParam = draft
  }

  var body: some View {
    Group {
      if let vm = viewModel {
        GeometryReader { proxy in
          navigationContainer(vm: vm)
            .onChange(of: vm.mentionSuggestions.count) {
              pcUIKitLogger.debug("PostComposerViewUIKit: Mention suggestions count changed to \(vm.mentionSuggestions.count)")
              updateMentionOverlay(vm: vm, proxy: proxy)
            }
            .onChange(of: vm.mentionSuggestions.map { $0.did.didString() }) {
              pcUIKitLogger.debug("PostComposerViewUIKit: Mention suggestions content changed")
              updateMentionOverlay(vm: vm, proxy: proxy)
            }
            .onChange(of: vm.postText) { 
              pcUIKitLogger.debug("PostComposerViewUIKit: Post text changed, length: \(vm.postText.count)")
              updateMentionOverlay(vm: vm, proxy: proxy)
            }
            .onAppear {
                pcUIKitLogger.debug("PostComposerViewUIKit: Rendering with viewModel")

              pcUIKitLogger.info("PostComposerViewUIKit: View appeared")
              updateMentionOverlay(vm: vm, proxy: proxy)
            }
            .overlay(mentionOverlayView(vm: vm, proxy: proxy))
        }
      } else {
          ProgressView().progressViewStyle(.circular)
              .onAppear {
          pcUIKitLogger.debug("PostComposerViewUIKit: Showing progress view, viewModel not ready")
      }
      }
    }
    // Root-level stable identity: recreate composer only on account switch
    .id(appState.userDID ?? "composer-unknown-user")
    .task {
      guard viewModel == nil else { 
        pcUIKitLogger.debug("PostComposerViewUIKit: Task skipped, viewModel already exists")
        return 
      }
      pcUIKitLogger.info("PostComposerViewUIKit: Initializing composer - parentPost: \(initialParentPost != nil), quotedPost: \(initialQuotedPost != nil), draft: \(restoringDraftParam != nil), currentDraft: \(appState.composerDraftManager.currentDraft != nil)")
      let vm = PostComposerViewModel(parentPost: initialParentPost, quotedPost: initialQuotedPost, appState: appState)
      
      // Restore from parameter draft or current draft (e.g., after account switch)
      if let draft = restoringDraftParam {
        pcUIKitLogger.info("PostComposerViewUIKit: Restoring draft from parameter")
        vm.restoreDraftState(draft)
      } else if let currentDraft = appState.composerDraftManager.currentDraft {
        pcUIKitLogger.info("PostComposerViewUIKit: Restoring current draft (likely from account switch)")
        vm.restoreDraftState(currentDraft)
      }
      
      viewModel = vm
      
      await vm.loadUserLanguagePreference()
      
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
         hasContent(vm: vm) {
        pcUIKitLogger.info("PostComposerViewUIKit: Auto-saving draft on disappear")
        Task { await MainActor.run { vm.saveDraftIfNeeded() } }
      } else {
        pcUIKitLogger.debug("PostComposerViewUIKit: Skipping auto-save - submit/discard or no content")
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
              if !vm.postText.isEmpty || !vm.mediaItems.isEmpty || vm.videoItem != nil {
                showingDismissAlert = true
              } else {
                dismissReason = .discard
                appState.composerDraftManager.clearDraft()
                vm.clearAll()
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
                guard let vm = viewModel else { return }
                suppressAutoSaveOnDismiss = true
                let draft = vm.saveDraftState()
                
                Task {
                  await appState.composerDraftManager.createSavedDraftAndWait(draft)
                  await MainActor.run {
                    appState.composerDraftManager.clearDraft()
                    vm.clearAll()
                    dismissReason = .discard
                    dismiss()
                  }
                }
              }
              Button("Discard", role: .destructive) {
                suppressAutoSaveOnDismiss = true
                dismissReason = .discard
                appState.composerDraftManager.clearDraft()
                if let vm = viewModel {
                  vm.clearAll()
                }
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
              Button(action: { showingDrafts = true }) {
                Image(systemName: "doc.text")
              }
              .accessibilityLabel("Open Drafts")
              .help("Open saved drafts")
            }
          }



          // Only the 'Open Drafts' button remains visible; 'Save Draft' lives in the discard dialog.

          // Trailing: Post button with glass effect
          ToolbarItem(placement: .primaryAction) {
            if #available(iOS 26.0, macOS 26.0, *) {
              Button(action: { submitAction(vm: vm) }) {
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
              Button(action: { submitAction(vm: vm) }) {
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
              .accessibilityLabel(vm.isThreadMode ? "Post All" : "Post")
            }
          }
        }
        // Force toolbar re-render when drafts count changes
        .id("toolbar-\(appState.composerDraftManager.savedDrafts.count)")
    }
    #else
    mainContent(vm: vm)
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
            mediaAttachmentsSection(vm: vm)
            metadataSection(vm: vm)
          }
          threadEntriesSection(vm: vm)
        }
        .padding(.top, 8)
      }
      .background(Color.systemBackground)
    )
  }
  
  @ViewBuilder
  private func composerEditorSection(vm: PostComposerViewModel) -> some View {
    HStack(alignment: .top, spacing: 12) {
      // Tappable avatar that opens account switcher
      Button(action: {
        pcUIKitLogger.info("PostComposerViewUIKit: Avatar tapped - opening account switcher")
        if hasContent(vm: vm) {
          appState.composerDraftManager.storeDraft(from: vm)
        }
        showingAccountSwitcher = true
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
          get: { 
            pcUIKitLogger.trace("PostComposerViewUIKit: Getting richAttributedText, length: \(vm.richAttributedText.length)")
            return vm.richAttributedText 
          },
          set: { 
            pcUIKitLogger.debug("PostComposerViewUIKit: Setting richAttributedText, length: \(($0 as NSAttributedString).length)")
            vm.richAttributedText = $0 
          }
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
          pcUIKitLogger.debug("PostComposerViewUIKit: Text changed - length: \(attrString.length), cursor: \(cursorPos), linkFacets: \(linkFacets.count)")
          vm.updateFromAttributedText(attrString, cursorPosition: cursorPos)
          vm.updateManualLinkFacets(from: linkFacets)
        },
        onLinkCreationRequested: { selectedText, range in
          pcUIKitLogger.info("PostComposerViewUIKit: Link creation requested - text: '\(selectedText)', range: \(range)")
          selectedTextForLink = selectedText
          selectedRangeForLink = range
          showingLinkCreation = true
        },
        // Avoid auto-focus on every attach to prevent keyboard reloads.
        focusOnAppear: false,
        focusActivationID: activeEditorFocusID,
        onPhotosAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Photos action triggered")
          photoPickerVisible = true 
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
          withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            guard let vm = viewModel else { return }
            // Properly enter thread mode and add a new entry,
            // mirroring the legacy behavior.
            if vm.isThreadMode {
              pcUIKitLogger.debug("PostComposerViewUIKit: Adding new thread entry to existing thread")
              vm.addNewThreadEntry()
              activeEditorFocusID = UUID()
            } else {
              pcUIKitLogger.debug("PostComposerViewUIKit: Entering thread mode and adding first entry")
              vm.enterThreadMode()
              vm.addNewThreadEntry()
              activeEditorFocusID = UUID()
            }
          }
        },
        onLinkAction: { 
          pcUIKitLogger.info("PostComposerViewUIKit: Link action triggered")
          showingLinkCreation = true 
        },
        allowTenor: true,
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
  
  private func startAutoSave() {
    pcUIKitLogger.info("PostComposerViewUIKit: Starting auto-save task (30s interval)")
    autoSaveTask?.cancel()
    autoSaveTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        guard let vm = viewModel else { continue }
        if hasContent(vm: vm) {
          pcUIKitLogger.debug("PostComposerViewUIKit: Auto-save triggered - saving draft")
          await MainActor.run { vm.saveDraftIfNeeded() }
        } else {
          pcUIKitLogger.trace("PostComposerViewUIKit: Auto-save skipped - no content")
        }
      }
    }
  }
  
    func hasContent(vm: PostComposerViewModel) -> Bool {
    let hasText = !vm.postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasMedia = !vm.mediaItems.isEmpty
    let hasVideo = vm.videoItem != nil
    let hasGif = vm.selectedGif != nil
    let result = hasText || hasMedia || hasVideo || hasGif
    
    if result {
      pcUIKitLogger.trace("PostComposerViewUIKit: Has content - text: \(hasText), media: \(hasMedia), video: \(hasVideo), gif: \(hasGif)")
    }
    
    return result
  }
}
