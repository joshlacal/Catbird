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
    let appState = AppState.shared
    @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var hSize

  @State private var viewModel: PostComposerViewModel

  // Link creation state
  @State private var showingLinkCreation = false
  @State private var selectedTextForLink: String = ""
  @State private var selectedRangeForLink: NSRange = .init(location: 0, length: 0)
  @State private var linkFacets: [RichTextFacetUtils.LinkFacet] = []
  // When set, the UIKit editor will move the caret to this range, then clear it
  @State private var pendingSelectionRange: NSRange? = nil

  // Submission
  @State private var isSubmitting = false

  // Media pickers & sheets
  @State private var photoPickerVisible = false
  @State private var videoPickerVisible = false
  @State private var photoPickerItems: [PhotosPickerItem] = []
  @State private var videoPickerItems: [PhotosPickerItem] = []
  @State private var showingEmojiPicker = false
  @State private var showingAudioRecorder = false
  @State private var showingAudioVisualizerPreview = false
  @State private var currentAudioURL: URL?
  @State private var currentAudioDuration: TimeInterval = 0
  // Visualizer generation progress
  @State private var isGeneratingVisualizerVideo = false
  @State private var visualizerService = AudioVisualizerService()
  @State private var showingAccountSwitcher = false
  @State private var showingLanguagePicker = false
  @State private var showingDismissAlert = false
  // Focus control for UIKit editor
  @State private var activeEditorFocusID = UUID()

  // Keyboard tracking for bottom toolbar positioning
  // Removed: handled by inputAccessoryView; no separate bottom toolbar

  // Track how the view was dismissed to decide draft persistence
  private enum DismissReason { case none, discard, submit }
  @State private var dismissReason: DismissReason = .none

  init(parentPost: AppBskyFeedDefs.PostView? = nil,
       quotedPost: AppBskyFeedDefs.PostView? = nil,
       appState: AppState) {
    self._viewModel = State(wrappedValue: PostComposerViewModel(parentPost: parentPost, quotedPost: quotedPost, appState: appState))
  }

  init(restoringFromDraft draft: PostComposerDraft,
       appState: AppState) {
    let vm = PostComposerViewModel(parentPost: nil, quotedPost: nil, appState: appState)
    vm.restoreDraftState(draft)
    self._viewModel = State(wrappedValue: vm)
  }

  var body: some View {
    NavigationStack { configured }
      .safeAreaInset(edge: .top) {
        if let reason = viewModel.videoUploadBlockedReason {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Video upload unavailable: \(reason)")
              .appFont(AppTextRole.caption)
              .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button("Check Again") {
              Task { await viewModel.checkVideoUploadEligibility(force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            if viewModel.videoUploadBlockedCode == "unconfirmed_email" {
              Button("Resend Email") {
                Task { await viewModel.resendVerificationEmail() }
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.mini)
            }
          }
          .padding(10)
          .background(.thinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .padding(.horizontal)
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      #if os(macOS)
      .safeAreaInset(edge: .bottom) {
        macOSBottomToolbar
      }
      #endif
      .ignoresSafeArea(.keyboard, edges: .bottom)
  }

  private var configured: some View {
    let nav = content
      .navigationTitle(getNavigationTitle())
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        // X mark (Cancel)
        ToolbarItem(placement: .cancellationAction) {
          Button(action: {
            if !viewModel.postText.isEmpty || !viewModel.mediaItems.isEmpty || viewModel.videoItem != nil {
              showingDismissAlert = true
            } else {
              dismissReason = .discard
              appState.composerDraftManager.clearDraft()
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
            Button("Discard", role: .destructive) {
              dismissReason = .discard
              appState.composerDraftManager.clearDraft()
              dismiss()
            }
            Button("Keep Editing", role: .cancel) { }
          } message: {
            Text("You'll lose your post if you discard now.")
          }

        }

          
        // Up arrow (Post/Reply)
        ToolbarItem(placement: .primaryAction) {
            if #available(iOS 26.0, macOS 26.0, *) {
                Button(action: { submit() }) {
                    Group {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(viewModel.isPostButtonDisabled || isSubmitting)
                .opacity(isSubmitting ? 0.7 : 1)
                .buttonStyle(.glassProminent)
                .accessibilityLabel(getPostButtonText())
            } else {
                Button(action: { submit() }) {
                  Group {
                    if isSubmitting {
                      ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    } else {
                      Image(systemName: "arrow.up")
                    }
                  }
                  .foregroundColor(.white)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(viewModel.isPostButtonDisabled || isSubmitting)
                .opacity(isSubmitting ? 0.7 : 1)
                .accessibilityLabel(getPostButtonText())

            }
        }
      }
      // Allow swipe-to-dismiss and decide persistence on disappear
      .interactiveDismissDisabled(false)
      .onDisappear { handleAutoPersistOnDismiss() }
      .onAppear { activeEditorFocusID = UUID() }

    let alerts = nav.alert(item: $viewModel.alertItem) { item in
      Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
    }

    let sheetsPrimary = alerts
      .sheet(isPresented: $showingLinkCreation) {
        LinkCreationDialog(
          selectedText: selectedTextForLink,
          onComplete: { url, display in
            // Use the dialog's chosen display text when provided
            addLinkFacet(url: url, displayText: display, range: selectedRangeForLink)
            showingLinkCreation = false
          },
          onCancel: { showingLinkCreation = false }
        )
      }
      .sheet(isPresented: $viewModel.showLabelSelector) {
        LabelSelectorView(selectedLabels: $viewModel.selectedLabels)
      }
      .sheet(isPresented: $viewModel.isAltTextEditorPresented) {
        if let editingId = viewModel.currentEditingMediaId {
          if let videoItem = viewModel.videoItem, videoItem.id == editingId, let image = videoItem.image {
            AltTextEditorView(altText: videoItem.altText, image: image, imageId: videoItem.id, onSave: viewModel.updateAltText)
          } else if let index = viewModel.mediaItems.firstIndex(where: { $0.id == editingId }), let image = viewModel.mediaItems[index].image {
            AltTextEditorView(altText: viewModel.mediaItems[index].altText, image: image, imageId: editingId, onSave: viewModel.updateAltText)
          }
        }
      }
      .sheet(isPresented: $viewModel.showThreadgateOptions) {
        ThreadgateOptionsView(settings: $viewModel.threadgateSettings)
      }
      .sheet(isPresented: $showingLanguagePicker) {
        LanguagePickerSheet(selectedLanguages: $viewModel.selectedLanguages)
      }

    let tasks = sheetsPrimary
      .task { await viewModel.loadUserLanguagePreference() }
      // Defer thumbnail pre-upload slightly to avoid blocking keyboard/show animation
      .task { try? await Task.sleep(nanoseconds: 250_000_000); await viewModel.preUploadThumbnails() }
      .onChange(of: Array(viewModel.urlCards.keys).sorted()) { _, _ in
        Task { await viewModel.preUploadThumbnails() }
      }
      // Keyboard notifications no longer needed without a custom bottom toolbar

    let pickers = tasks
      .photosPicker(
        isPresented: $photoPickerVisible,
        selection: $photoPickerItems,
        maxSelectionCount: viewModel.maxImagesAllowed,
        matching: .images
      )
      .onChange(of: photoPickerItems) { _, _ in
        Task {
          if !photoPickerItems.isEmpty {
            await viewModel.processPhotoSelection(photoPickerItems)
            photoPickerItems = []
          }
        }
      }
      .photosPicker(
        isPresented: $videoPickerVisible,
        selection: $videoPickerItems,
        maxSelectionCount: 1,
        matching: .any(of: [.videos])
      )
      .onChange(of: videoPickerItems) { _, _ in
        Task {
          if let item = videoPickerItems.first {
            await viewModel.processVideoSelection(item)
            videoPickerItems.removeAll()
          }
        }
      }
      .sheet(isPresented: $viewModel.showingGifPicker) {
        GifPickerView { gif in
          viewModel.selectGif(gif)
        }
      }
      .sheet(isPresented: $showingAudioRecorder) {
        PostComposerAudioRecordingView(
          onAudioRecorded: { audioURL in
            handleAudioRecorded(audioURL)
          },
          onCancel: { showingAudioRecorder = false }
        )
      }
      // Removed secondary preview screen per request; generate directly
      .sheet(isPresented: $showingAccountSwitcher) {
        AccountSwitcherView()
      }
      .sheet(isPresented: $isGeneratingVisualizerVideo) {
        VStack(spacing: 24) {
          Spacer()
          VStack(spacing: 16) {
            ProgressView(value: visualizerService.progress, total: 1.0)
              .progressViewStyle(CircularProgressViewStyle(tint: Color.accentColor))
              .scaleEffect(1.4)
            Text("Generating Video…")
              .font(.title3)
              .fontWeight(.semibold)
            Text("This may take a few seconds depending on length.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding()
        .presentationDetents([.fraction(0.35)])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
      }

    return pickers
  }

  private var content: some View {
    Group {
      if viewModel.isThreadMode {
        threadComposerStack
      } else {
        editorPane
      }
    }
  }

  private var editorPane: some View {
    // Predeclare closures with explicit types to help type checker
    let onImagePasted: (PlatformImage) -> Void = { image in
      #if os(iOS)
      Task { await viewModel.handleMediaPaste([NSItemProvider(object: image)]) }
      #endif
    }
    let onGenmojiDetected: ([String]) -> Void = { genmojiStrings in
      Task {
        for s in genmojiStrings {
          if let d = s.data(using: .utf8) { await viewModel.processDetectedGenmoji(d) }
        }
      }
    }
    let onTextChanged: (NSAttributedString) -> Void = { ns in
      viewModel.updateFromAttributedText(ns)
      // Keep manual link facets in sync for legacy inline links
      viewModel.updateManualLinkFacets(from: linkFacets)
    }
    let onLinkCreationRequested: (String, NSRange) -> Void = { selectedText, range in
      pcUIKitLogger.debug("UIKit composer: link creation requested text='\(selectedText)' range=\(range)")
      selectedTextForLink = selectedText
      selectedRangeForLink = range
      showingLinkCreation = true
    }

    // Precompute UTType identifiers to avoid inline generic inference
    let dropTypes: [String] = [
      UTType.image.identifier,
      UTType.url.identifier,
      UTType.fileURL.identifier,
      UTType.plainText.identifier
    ]

    return ScrollView {
      VStack(spacing: 0) {
        // Replying to parent post (if any)
        if let parent = viewModel.parentPost {
          ReplyingToView(parentPost: parent)
            .padding(.horizontal)
            .padding(.top, 8)
        }

        // Avatar next to the text editor
        HStack(alignment: .top, spacing: 12) {
          Button(action: { showingAccountSwitcher = true }) {
            AvatarView(
              did: appState.currentUserDID,
              client: appState.atProtoClient,
              size: 60
            )
            .id("avatar:\(appState.currentUserDID ?? "unknown"):\(appState.currentUserProfile?.avatar?.description ?? "")")
            .frame(width: 60, height: 60)
          }
          .accessibilityLabel("Switch account")
          .accessibilityHint("Tap to switch between accounts")

          // UIKit-based text editor with link selection + creation
          EnhancedRichTextEditor(
            attributedText: $viewModel.richAttributedText,
            linkFacets: $linkFacets,
            pendingSelectionRange: $pendingSelectionRange,
            placeholder: "What's on your mind?",
            onImagePasted: onImagePasted,
            onGenmojiDetected: onGenmojiDetected,
            onTextChanged: onTextChanged,
            onLinkCreationRequested: onLinkCreationRequested,
            focusOnAppear: true,
            focusActivationID: activeEditorFocusID,
            onPhotosAction: { photoPickerVisible = true },
            onVideoAction: { videoPickerVisible = true },
            onAudioAction: { showingAudioRecorder = true },
            onGifAction: { viewModel.showingGifPicker = true },
            onLabelsAction: { viewModel.showLabelSelector = true },
            onThreadgateAction: { viewModel.showThreadgateOptions = true },
            onLanguageAction: { showingLanguagePicker = true },
            onThreadAction: {
              if viewModel.isThreadMode {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                  viewModel.addNewThreadEntry()
                  activeEditorFocusID = UUID()
                }
              } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                  viewModel.enterThreadMode()
                  viewModel.addNewThreadEntry()
                  activeEditorFocusID = UUID()
                }
              }
            },
            onLinkAction: {
              selectedTextForLink = ""
              selectedRangeForLink = NSRange(location: viewModel.postText.count, length: 0)
              showingLinkCreation = true
            },
            allowTenor: appState.appSettings.allowTenor
          )
          .frame(minHeight: 140)
          .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .onDrop(of: dropTypes, isTargeted: nil) { providers in
          handleDrop(providers)
        }

        // @-mention suggestions below the editor (parity with SwiftUI composer)
        if !viewModel.mentionSuggestions.isEmpty {
          UserMentionSuggestionViewResolver(
            suggestions: viewModel.mentionSuggestions.map { MentionSuggestion(profile: $0) },
            onSuggestionSelected: { suggestion in
              viewModel.insertMention(suggestion.profile)
              // Move caret to end of inserted mention + ensure typing continues after it
              pendingSelectionRange = NSRange(location: viewModel.postText.count, length: 0)
              activeEditorFocusID = UUID()
            },
            onDismiss: {
              // Clear suggestions if needed; viewModel clears on insert/update already
              viewModel.mentionSuggestions = []
            }
          )
          .padding(.horizontal, 16)
          .padding(.top, 8)
        }

        // Thread list shown inline only on compact width - now in scrollable area
        if hSize != .regular {
          if viewModel.isThreadMode {
            threadVerticalView
              .padding(.top, 8)
          }
        }

        // Quoted post (if present)
        quotedPostSection

      // Media preview (hidden until media exists)
      Group {
        if let gif = viewModel.selectedGif {
          selectedGifView(gif)
        } else if let videoItem = viewModel.videoItem, let image = videoItem.image {
          // Simple video preview thumbnail with remove
          HStack(spacing: 12) {
            image
              .resizable()
              .scaledToFit()
              .frame(height: 120)
              .cornerRadius(10)
              .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.systemGray5, lineWidth: 1))
            Spacer()
            Button("Remove") { viewModel.videoItem = nil }
          }
          .padding(.horizontal)
          .padding(.vertical, 8)
        } else if !viewModel.mediaItems.isEmpty {
          // Images grid only when there are images
          #if os(iOS)
          MediaGalleryView(
            mediaItems: $viewModel.mediaItems,
            currentEditingMediaId: $viewModel.currentEditingMediaId,
            isAltTextEditorPresented: $viewModel.isAltTextEditorPresented,
            maxImagesAllowed: viewModel.maxImagesAllowed,
            onAddMore: { photoPickerVisible = true },
            onMoveLeft: { id in viewModel.moveMediaItemLeft(id: id) },
            onMoveRight: { id in viewModel.moveMediaItemRight(id: id) },
            onCropSquare: { id in viewModel.cropMediaItemToSquare(id: id) },
            onPaste: nil,
            hasClipboardMedia: false,
            onReorder: { from, to in viewModel.moveMediaItem(from: from, to: to) },
            onExternalImageDrop: { datas in
              let providers: [NSItemProvider] = datas.compactMap { data in
                #if os(iOS)
                if let image = UIImage(data: data) { return NSItemProvider(object: image) }
                #endif
                return nil
              }
              if !providers.isEmpty { Task { await viewModel.handleMediaPaste(providers) } }
            }
          )
          .padding(.top, 8)
          #else
          MediaGalleryView(
            mediaItems: $viewModel.mediaItems,
            currentEditingMediaId: $viewModel.currentEditingMediaId,
            isAltTextEditorPresented: $viewModel.isAltTextEditorPresented,
            maxImagesAllowed: viewModel.maxImagesAllowed,
            onAddMore: { photoPickerVisible = true },
            onMoveLeft: { id in viewModel.moveMediaItemLeft(id: id) },
            onMoveRight: { id in viewModel.moveMediaItemRight(id: id) },
            onCropSquare: { id in viewModel.cropMediaItemToSquare(id: id) },
            onPaste: nil,
            hasClipboardMedia: false,
            onReorder: { from, to in viewModel.moveMediaItem(from: from, to: to) }
          )
          .padding(.top, 8)
          #endif
        }
      }

      // URL cards (if any detected)
      urlCardsSection

      // Outline hashtags editor
      outlineTagsSection

      // Language chips
      languageSection
        .contextMenu {
          Button(action: { showingLanguagePicker = true }) { Label("Add Language", systemImage: "plus") }
        }

        // Character count
        characterCountView
        
        // Add some bottom padding for scrolling
        Spacer(minLength: 100)
      }
    }
  }

  // MARK: - Unified Liquid Glass Toolbar
  @available(iOS 26.0, macOS 26.0, *)
  private var unifiedLiquidGlassToolbar: some View {
    GlassEffectContainer(spacing: 12) {
      HStack(spacing: 16) {
        // Cancel button
        Button("Cancel") {
          if !viewModel.postText.isEmpty || !viewModel.mediaItems.isEmpty || viewModel.videoItem != nil {
            showingDismissAlert = true
          } else {
            dismissReason = .discard
            appState.composerDraftManager.clearDraft()
            dismiss()
          }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(.secondary)
        .glassEffect(.regular.interactive())

        // Media and formatting buttons
        HStack(spacing: 12) {
          Button(action: { photoPickerVisible = true }) {
            Image(systemName: "photo")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Add photos")
          .glassEffect(.regular.interactive())

          Button(action: { videoPickerVisible = true }) {
            Image(systemName: "video")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Add video")
          .disabled(viewModel.videoUploadBlockedReason != nil)
          .glassEffect(.regular.interactive())

          Button(action: { showingAudioRecorder = true }) {
            Image(systemName: "mic")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Record audio")
          .glassEffect(.regular.interactive())

          Button(action: { viewModel.showingGifPicker = true }) {
            Image(systemName: "gift")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Add GIF")
          .disabled(!appState.appSettings.allowTenor)
          .glassEffect(.regular.interactive())

          Button(action: {
            selectedTextForLink = ""
            selectedRangeForLink = NSRange(location: viewModel.postText.count, length: 0)
            showingLinkCreation = true
          }) {
            Image(systemName: "link")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Add link")
          .glassEffect(.regular.interactive())
        }
        .foregroundColor(.accentColor)

        Spacer()

        // Additional options
        HStack(spacing: 12) {
          Button(action: { viewModel.showLabelSelector = true }) {
            Image(systemName: "tag")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Add labels")
          .glassEffect(.regular.interactive())

          Button(action: { viewModel.showThreadgateOptions = true }) {
            Image(systemName: "person.2")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Thread settings")
          .glassEffect(.regular.interactive())

          Button(action: { showingLanguagePicker = true }) {
            Image(systemName: "globe")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Set language")
          .glassEffect(.regular.interactive())

          Button(action: {
            if viewModel.isThreadMode {
              withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                viewModel.addNewThreadEntry()
                activeEditorFocusID = UUID()
              }
            } else {
              withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                viewModel.enterThreadMode()
                viewModel.addNewThreadEntry()
                activeEditorFocusID = UUID()
              }
            }
          }) {
            Image(systemName: "plus.bubble")
              .font(.system(size: 18))
          }
          .accessibilityLabel("Add to thread")
          .glassEffect(.regular.interactive())
        }
        .foregroundColor(.accentColor)

        // Post/Submit button
        Button(action: { submit() }) {
          HStack(spacing: 6) {
            if isSubmitting {
              ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(0.8)
            } else {
              Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
            }
            Text(getPostButtonText())
              .font(.system(size: 16, weight: .semibold))
          }
          .foregroundColor(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }
        .disabled(viewModel.isPostButtonDisabled || isSubmitting)
        .opacity(isSubmitting ? 0.7 : 1)
        .accessibilityLabel(getPostButtonText())
        .keyboardShortcut(.return, modifiers: .command)
        .glassEffect(.regular.tint(.accentColor).interactive())
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  // Fallback for iOS 18+ and macOS 13+ compatibility
  @available(iOS, introduced: 18.0, obsoleted: 26.0)
  @available(macOS, introduced: 13.0, obsoleted: 26.0)
  private var legacyMaterialToolbar: some View {
    HStack(spacing: 16) {
      // Cancel button
      Button("Cancel") {
        if !viewModel.postText.isEmpty || !viewModel.mediaItems.isEmpty || viewModel.videoItem != nil {
          showingDismissAlert = true
        } else {
          dismissReason = .discard
          appState.composerDraftManager.clearDraft()
          dismiss()
        }
      }
      .font(.system(size: 16, weight: .medium))
      .foregroundColor(.secondary)

      // Media and formatting buttons
      HStack(spacing: 12) {
        Button(action: { photoPickerVisible = true }) {
          Image(systemName: "photo")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Add photos")

        Button(action: { videoPickerVisible = true }) {
          Image(systemName: "video")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Add video")
        .disabled(viewModel.videoUploadBlockedReason != nil)

        Button(action: { showingAudioRecorder = true }) {
          Image(systemName: "mic")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Record audio")

        Button(action: { viewModel.showingGifPicker = true }) {
          Image(systemName: "gift")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Add GIF")
        .disabled(!appState.appSettings.allowTenor)

        Button(action: {
          selectedTextForLink = ""
          selectedRangeForLink = NSRange(location: viewModel.postText.count, length: 0)
          showingLinkCreation = true
        }) {
          Image(systemName: "link")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Add link")
      }
      .foregroundColor(.accentColor)

      Spacer()

      // Additional options
      HStack(spacing: 12) {
        Button(action: { viewModel.showLabelSelector = true }) {
          Image(systemName: "tag")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Add labels")

        Button(action: { viewModel.showThreadgateOptions = true }) {
          Image(systemName: "person.2")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Thread settings")

        Button(action: { showingLanguagePicker = true }) {
          Image(systemName: "globe")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Set language")

        Button(action: {
          if viewModel.isThreadMode {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
              viewModel.addNewThreadEntry()
              activeEditorFocusID = UUID()
            }
          } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
              viewModel.enterThreadMode()
              viewModel.addNewThreadEntry()
              activeEditorFocusID = UUID()
            }
          }
        }) {
          Image(systemName: "plus.bubble")
            .font(.system(size: 18))
        }
        .accessibilityLabel("Add to thread")
      }
      .foregroundColor(.accentColor)

      // Post/Submit button
      Button(action: { submit() }) {
        HStack(spacing: 6) {
          if isSubmitting {
            ProgressView()
              .progressViewStyle(.circular)
              .tint(.white)
              .scaleEffect(0.8)
          } else {
            Image(systemName: "arrow.up")
              .font(.system(size: 16, weight: .semibold))
          }
          Text(getPostButtonText())
            .font(.system(size: 16, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.tint)
        .cornerRadius(8)
      }
      .disabled(viewModel.isPostButtonDisabled || isSubmitting)
      .opacity(isSubmitting ? 0.7 : 1)
      .accessibilityLabel(getPostButtonText())
      .keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.regularMaterial)
    .overlay(
      Rectangle()
        .frame(height: 0.5)
        .foregroundColor(.separator),
      alignment: .top
    )
  }

  // MARK: - macOS Bottom Toolbar
  #if os(macOS)
  private var macOSBottomToolbar: some View {
    KeyboardToolbarView(
      onPhotos: { photoPickerVisible = true },
      onVideo: { videoPickerVisible = true },
      onAudio: { showingAudioRecorder = true },
      onGif: { viewModel.showingGifPicker = true },
      onLabels: { viewModel.showLabelSelector = true },
      onThreadgate: { viewModel.showThreadgateOptions = true },
      onLanguage: { showingLanguagePicker = true },
      onThread: {
        if viewModel.isThreadMode {
          withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            viewModel.addNewThreadEntry()
            activeEditorFocusID = UUID()
          }
        } else {
          withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            viewModel.enterThreadMode()
            viewModel.addNewThreadEntry()
            activeEditorFocusID = UUID()
          }
        }
      },
      onLink: {
        selectedTextForLink = ""
        selectedRangeForLink = NSRange(location: viewModel.postText.count, length: 0)
        showingLinkCreation = true
      },
      allowTenor: appState.appSettings.allowTenor
    )
    .background(.regularMaterial)
    .overlay(
      Rectangle()
        .frame(height: 0.5)
        .foregroundColor(.separator),
      alignment: .top
    )
  }
  #endif

  // MARK: - Thread Composer Stack
  private var threadComposerStack: some View {
    // Hoist closures to stabilize UIViewRepresentable identity
    let onImagePasted: (PlatformImage) -> Void = { image in
      #if os(iOS)
      Task { await viewModel.handleMediaPaste([NSItemProvider(object: image)]) }
      #endif
    }
    let onGenmojiDetected: ([String]) -> Void = { genmojiStrings in
      Task { for s in genmojiStrings { if let d = s.data(using: .utf8) { await viewModel.processDetectedGenmoji(d) } } }
    }
    let onTextChanged: (NSAttributedString) -> Void = { ns in
      viewModel.updateFromAttributedText(ns)
      viewModel.updateManualLinkFacets(from: linkFacets)
    }
    let onLinkCreationRequested: (String, NSRange) -> Void = { selectedText, range in
      pcUIKitLogger.debug("UIKit composer: link creation requested text='\(selectedText)' range=\(range)")
      selectedTextForLink = selectedText
      selectedRangeForLink = range
      showingLinkCreation = true
    }

    return ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(viewModel.threadEntries.enumerated()), id: \.offset) { index, entry in
          VStack(spacing: 6) {
            // Row: avatar + text editor or preview
            HStack(alignment: .top, spacing: 12) {
              AvatarView(
                did: appState.currentUserDID,
                client: appState.atProtoClient,
                size: 60
              )
              .id("avatar:\(appState.currentUserDID ?? "unknown"):\(appState.currentUserProfile?.avatar?.description ?? "")")
              .frame(width: 60, height: 60)

              if index == viewModel.currentThreadIndex {
                // Active entry uses the full editor
                EnhancedRichTextEditor(
                  attributedText: $viewModel.richAttributedText,
                  linkFacets: $linkFacets,
                  pendingSelectionRange: $pendingSelectionRange,
                  placeholder: "What's on your mind?",
                  onImagePasted: onImagePasted,
                  onGenmojiDetected: onGenmojiDetected,
                  onTextChanged: onTextChanged,
                  onLinkCreationRequested: onLinkCreationRequested,
                  focusOnAppear: true,
                  focusActivationID: activeEditorFocusID,
                  onPhotosAction: { photoPickerVisible = true },
                  onVideoAction: { videoPickerVisible = true },
                  onAudioAction: { showingAudioRecorder = true },
                  onGifAction: { viewModel.showingGifPicker = true },
                  onLabelsAction: { viewModel.showLabelSelector = true },
                  onThreadgateAction: { viewModel.showThreadgateOptions = true },
                  onLanguageAction: { showingLanguagePicker = true },
                  onThreadAction: {
                    if viewModel.isThreadMode {
                      withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.addNewThreadEntry()
                        activeEditorFocusID = UUID()
                      }
                    } else {
                      withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.enterThreadMode()
                        viewModel.addNewThreadEntry()
                        activeEditorFocusID = UUID()
                      }
                    }
                  },
                  onLinkAction: {
                    selectedTextForLink = ""
                    selectedRangeForLink = NSRange(location: viewModel.postText.count, length: 0)
                    showingLinkCreation = true
                  },
                  allowTenor: appState.appSettings.allowTenor
                )
                .frame(minHeight: 120)
                .frame(maxWidth: .infinity)
              } else {
                // Inactive entry preview (no gray box background), left-aligned
                Text(entry.text.isEmpty ? "Write post \(index + 1)…" : entry.text)
                  .appFont(AppTextRole.body)
                  .foregroundColor(entry.text.isEmpty ? .secondary : .primary)
                  .multilineTextAlignment(.leading)
                  .lineLimit(6)
                  .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                  .padding(.vertical, 12)
              }

              // Delete for non-first when inactive or active
              if viewModel.threadEntries.count > 1 {
                Button(action: { viewModel.removeThreadEntry(at: index) }) {
                  Image(systemName: "xmark.circle.fill")
                    .appFont(size: 20)
                    .foregroundStyle(.white, Color.systemGray3)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
              }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onTapGesture {
              withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.updateCurrentThreadEntry()
                viewModel.currentThreadIndex = index
                viewModel.loadEntryState()
                activeEditorFocusID = UUID()
              }
            }

            // Media section per entry
            if index == viewModel.currentThreadIndex {
              // Active: live media from view model state
              activeEntryMediaSection
            } else {
              inactiveEntryMediaSection(entry)
            }

            // Separator under the textbox area (align with editor: padding 16 + avatar 60 + spacing 12 = 88)
            if index < viewModel.threadEntries.count - 1 {
              Divider().padding(.leading, 88)
            }
          }
          .opacity(index == viewModel.currentThreadIndex ? 1.0 : 0.55)
        }

        // Active entry URL cards (if any)
        urlCardsSection

        // Language chips and character count
        languageSection
        characterCountView

        // Bottom spacer for comfortable scrolling above keyboard
        Spacer(minLength: 80)
      }
    }
  }

  // MARK: - Per-Entry Media Sections
  @ViewBuilder
  private var activeEntryMediaSection: some View {
    Group {
      if let gif = viewModel.selectedGif {
        selectedGifView(gif)
      } else if let videoItem = viewModel.videoItem, let image = videoItem.image {
        HStack(spacing: 12) {
          image
            .resizable()
            .scaledToFit()
            .frame(height: 120)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.systemGray5, lineWidth: 1))
          Spacer()
          Button("Remove") { viewModel.videoItem = nil }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
      } else if !viewModel.mediaItems.isEmpty {
        #if os(iOS)
        MediaGalleryView(
          mediaItems: $viewModel.mediaItems,
          currentEditingMediaId: $viewModel.currentEditingMediaId,
          isAltTextEditorPresented: $viewModel.isAltTextEditorPresented,
          maxImagesAllowed: viewModel.maxImagesAllowed,
          onAddMore: { photoPickerVisible = true },
          onMoveLeft: { id in viewModel.moveMediaItemLeft(id: id) },
          onMoveRight: { id in viewModel.moveMediaItemRight(id: id) },
          onCropSquare: { id in viewModel.cropMediaItemToSquare(id: id) },
          onPaste: nil,
          hasClipboardMedia: false,
          onReorder: { from, to in viewModel.moveMediaItem(from: from, to: to) },
          onExternalImageDrop: { datas in
            let providers: [NSItemProvider] = datas.compactMap { data in
              #if os(iOS)
              if let image = UIImage(data: data) { return NSItemProvider(object: image) }
              #endif
              return nil
            }
            if !providers.isEmpty { Task { await viewModel.handleMediaPaste(providers) } }
          }
        )
        .padding(.top, 8)
        #else
        MediaGalleryView(
          mediaItems: $viewModel.mediaItems,
          currentEditingMediaId: $viewModel.currentEditingMediaId,
          isAltTextEditorPresented: $viewModel.isAltTextEditorPresented,
          maxImagesAllowed: viewModel.maxImagesAllowed,
          onAddMore: { photoPickerVisible = true },
          onMoveLeft: { id in viewModel.moveMediaItemLeft(id: id) },
          onMoveRight: { id in viewModel.moveMediaItemRight(id: id) },
          onCropSquare: { id in viewModel.cropMediaItemToSquare(id: id) },
          onPaste: nil,
          hasClipboardMedia: false,
          onReorder: { from, to in viewModel.moveMediaItem(from: from, to: to) }
        )
        .padding(.top, 8)
        #endif
      }
    }
  }

  @ViewBuilder
  private func inactiveEntryMediaSection(_ entry: ThreadEntry) -> some View {
    Group {
      if let gif = entry.selectedGif {
        GifVideoView(gif: gif, onTap: {})
          .frame(maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .allowsHitTesting(false)
          .padding(.horizontal)
          .padding(.vertical, 8)
      } else if let videoItem = entry.videoItem {
        if let image = videoItem.image {
          HStack(spacing: 12) {
            image
              .resizable()
              .scaledToFit()
              .frame(height: 120)
              .cornerRadius(10)
              .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.systemGray5, lineWidth: 1))
            Spacer()
          }
          .padding(.horizontal)
          .padding(.vertical, 8)
        }
      } else if !entry.mediaItems.isEmpty {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
          ForEach(entry.mediaItems.prefix(4), id: \.id) { item in
            if let image = item.image {
              image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
              RoundedRectangle(cornerRadius: 12)
                .fill(Color.systemGray5)
                .frame(height: 120)
                .overlay(Image(systemName: "photo").foregroundColor(.secondary))
            }
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
      }
    }
  }

  // MARK: - Quoted Post Section
  @ViewBuilder
  private var quotedPostSection: some View {
    if let quoted = viewModel.quotedPost {
      VStack(alignment: .leading, spacing: 8) {
        Button("Remove Quote") { viewModel.quotedPost = nil }
          .appFont(AppTextRole.caption)
          .foregroundColor(.accentColor)

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("@\(quoted.author.handle.description)")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
            Spacer()
          }
          if case .knownType(let record) = quoted.record,
             let post = record as? AppBskyFeedPost {
            Text(post.text)
              .appFont(AppTextRole.body)
              .lineLimit(3)
          } else {
            Text("Quoted post")
              .appFont(AppTextRole.body)
              .foregroundColor(.secondary)
          }
        }
        .padding(8)
        .background(Color.systemBackground)
        .cornerRadius(8)
      }
      .padding()
      .background(Color.systemGray6)
      .cornerRadius(12)
    }
  }

  // MARK: - URL Cards
  private var urlCardsSection: some View {
    Group {
      ForEach(viewModel.detectedURLs, id: \.self) { url in
        if let card = viewModel.urlCards[url] {
          VStack(alignment: .leading, spacing: 6) {
            ComposeURLCardView(card: card, onRemove: { viewModel.removeURLCard(for: url) }, willBeUsedAsEmbed: viewModel.willBeUsedAsEmbed(for: url))
            // Retry thumbnail upload helper
            if !viewModel.hasThumbnail(for: url) {
              Button(action: { Task { await viewModel.retryThumbnailUpload(for: url) } }) {
                Label("Retry thumbnail upload", systemImage: "arrow.clockwise")
                  .appFont(AppTextRole.caption)
              }
              .buttonStyle(.borderless)
              .padding(.leading, 8)
            }
          }
          .padding(.horizontal)
          .padding(.vertical, 4)
        }
      }

      if viewModel.isLoadingURLCard {
        HStack { Spacer(); ProgressView(); Spacer() }
          .padding()
      }
    }
  }

  // MARK: - Outline Tags
  private var outlineTagsSection: some View {
    CompactOutlineTagsView(tags: $viewModel.outlineTags)
      .padding(.horizontal)
      .padding(.top, 4)
  }

  // MARK: - Selected GIF View
  private func selectedGifView(_ gif: TenorGif) -> some View {
    VStack(alignment: .trailing, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        GifVideoView(gif: gif, onTap: {})
          .frame(maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .allowsHitTesting(false)

        Button(action: { viewModel.removeSelectedGif() }) {
          Image(systemName: "xmark.circle.fill")
            .appFont(AppTextRole.title1)
            .foregroundStyle(.white, Color.systemGray3)
            .background(Circle().fill(Color.black.opacity(0.3)))
        }
        .padding(8)
      }

      HStack {
        Image(systemName: "gift.fill").foregroundColor(.accentColor)
        Text(gif.title.isEmpty ? "GIF" : gif.title)
          .appFont(AppTextRole.caption)
          .lineLimit(2)
        Spacer()
        Text("via Tenor").appFont(AppTextRole.caption2).foregroundColor(.secondary)
      }
      .padding(.horizontal, 4)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }




  // MARK: - Language Chips
  private var languageSection: some View {
    Group {
      if !viewModel.selectedLanguages.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            Image(systemName: "globe")
              .font(.system(size: 12))
              .foregroundColor(.secondary)

            ForEach(viewModel.selectedLanguages, id: \.self) { lang in
              HStack(spacing: 4) {
                Text(Locale.current.localizedString(forLanguageCode: lang.lang.languageCode?.identifier ?? "") ?? lang.lang.minimalIdentifier)
                  .font(.system(size: 11, weight: .medium))
                Button(action: { viewModel.toggleLanguage(lang) }) {
                  Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.secondary.opacity(0.1))
              .foregroundColor(.secondary)
              .cornerRadius(6)
            }
          }
          .padding(.horizontal, 1)
        }
        .padding(.horizontal)
        .padding(.top, 2)
      }
    }
  }

  // MARK: - Character Count
  private var characterCountView: some View {
    let remaining = viewModel.maxCharacterCount - viewModel.characterCount
    let color: Color = remaining < 0 ? .red : (remaining < 20 ? .orange : (remaining < 50 ? .yellow : .secondary))
    return HStack {
      Spacer()
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 6, height: 6)
        Text("\(remaining)").appFont(AppTextRole.caption).foregroundStyle(color)
      }
      .padding(.horizontal)
      .padding(.bottom, 4)
    }
  }

  // MARK: - Actions
  private func submit() {
    guard !isSubmitting else { return }
    isSubmitting = true
    Task {
      do {
        if viewModel.isThreadMode {
          try await viewModel.createThread()
        } else {
          try await viewModel.createPost()
        }
        isSubmitting = false
        dismissReason = .submit
        appState.composerDraftManager.clearDraft()
        dismiss()
      } catch {
        isSubmitting = false
        viewModel.alertItem = PostComposerViewModel.AlertItem(title: "Failed to Create Post", message: error.localizedDescription)
      }
    }
  }

  private func handleAutoPersistOnDismiss() {
    // Decide what to do with draft based on how we left the composer
    switch dismissReason {
    case .discard:
      // Already cleared
      break
    case .submit:
      // Already cleared
      break
    case .none:
      // User likely swiped down or dismissed without explicit action; persist if any content
      let hasContent = !viewModel.postText.isEmpty || !viewModel.mediaItems.isEmpty || viewModel.videoItem != nil || viewModel.isThreadMode
      if hasContent {
        appState.composerDraftManager.storeDraft(from: viewModel)
      } else {
        appState.composerDraftManager.clearDraft()
      }
    }
  }

  private func getNavigationTitle() -> String {
    if viewModel.isThreadMode { return "Thread" }
    if viewModel.quotedPost != nil { return "Quote" }
    if viewModel.parentPost != nil { return "Reply" }
    return "Post"
  }
  
  private func getPostButtonText() -> String {
    if viewModel.isThreadMode {
      return "Post"
    } else if viewModel.parentPost != nil {
      return "Reply"
    } else {
      return "Post"
    }
  }

  // MARK: - Link Facets
  private func addLinkFacet(url: URL, displayText: String?, range: NSRange) {
    pcUIKitLogger.debug("UIKit addLinkFacet url=\(url.absoluteString) range=\(range.debugDescription)")
    if #available(iOS 26.0, macOS 15.0, *) {
      let start = viewModel.attributedPostText.index(viewModel.attributedPostText.startIndex, offsetByCharacters: range.location)
      let end = viewModel.attributedPostText.index(start, offsetByCharacters: range.length)
      let attrRange = start..<end
      let display = (displayText?.isEmpty == false) ? displayText : nil
      viewModel.insertLinkWithAttributedString(url: url, displayText: display, at: attrRange)
      // Also add to manual link facets for posting
      let effectiveRange = range.length == 0 ? NSRange(location: range.location, length: (displayText?.count ?? 0)) : range
      let linkFacet = RichTextFacetUtils.LinkFacet(range: effectiveRange, url: url, displayText: displayText ?? "")
      linkFacets.append(linkFacet)
      viewModel.updateManualLinkFacets(from: linkFacets)
      // Move caret to immediately after the inserted link to avoid extending it while typing.
      // Defer until the attributed text reflects the new link so we can derive the precise run length.
      DispatchQueue.main.async {
        if let preciseRange = self.linkRangeNearest(to: range.location) {
          self.pendingSelectionRange = NSRange(location: preciseRange.location + preciseRange.length, length: 0)
        } else {
          self.pendingSelectionRange = NSRange(location: effectiveRange.location + effectiveRange.length, length: 0)
        }
      }
    } else {
      let newAttributedText = RichTextFacetUtils.addOrInsertLinkFacet(
        to: viewModel.richAttributedText,
        url: url,
        range: range,
        displayText: displayText
      )
      viewModel.richAttributedText = newAttributedText
      let effectiveRange = range.length == 0 ? NSRange(location: range.location, length: (displayText?.count ?? 0)) : range
      let linkFacet = RichTextFacetUtils.LinkFacet(range: effectiveRange, url: url, displayText: displayText ?? "")
      linkFacets.append(linkFacet)
      // Update manual link facets immediately after adding the link
      viewModel.updateManualLinkFacets(from: linkFacets)
      // Move caret after link (use precise attribution if available)
      DispatchQueue.main.async {
        if let preciseRange = self.linkRangeNearest(to: range.location) {
          self.pendingSelectionRange = NSRange(location: preciseRange.location + preciseRange.length, length: 0)
        } else {
          self.pendingSelectionRange = NSRange(location: effectiveRange.location + effectiveRange.length, length: 0)
        }
      }
    }
  }

  // Find the link attributed run nearest to a location in the current richAttributedText
  private func linkRangeNearest(to location: Int) -> NSRange? {
    let ns = viewModel.richAttributedText
    var best: (range: NSRange, distance: Int)?
    ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
      guard value is URL else { return }
      let dist: Int
      if location >= range.location && location <= range.location + range.length {
        dist = 0
      } else if location < range.location {
        dist = range.location - location
      } else {
        dist = location - (range.location + range.length)
      }
      if let cur = best {
        if dist < cur.distance { best = (range, dist) }
      } else {
        best = (range, dist)
      }
    }
    return best?.range
  }

  // MARK: - Audio Helpers
  private func handleAudioRecorded(_ audioURL: URL) {
    let asset = AVURLAsset(url: audioURL)
    let duration = CMTimeGetSeconds(asset.duration)
    currentAudioURL = audioURL
    currentAudioDuration = duration
    showingAudioRecorder = false
    // Generate visualizer video directly (no intermediate preview screen)
    Task {
      await generateVisualizerVideoDirectly(from: audioURL, duration: duration)
    }
  }

  private func handleVideoGenerated(_ videoURL: URL) {
    Task {
      await viewModel.processGeneratedVideoFromAudio(videoURL)
      currentAudioURL = nil
      currentAudioDuration = 0
    }
  }

  private func generateVisualizerVideoDirectly(from audioURL: URL, duration: TimeInterval) async {
    let service = visualizerService
    await MainActor.run { isGeneratingVisualizerVideo = true }
    let username = appState.currentUserProfile?.handle.description ?? "user"
    let avatarURL = appState.currentUserProfile?.avatar?.description
    do {
      let videoURL = try await service.generateVisualizerVideo(
        audioURL: audioURL,
        profileImage: nil,
        username: username,
        accentColor: Color.accentColor,
        duration: duration,
        avatarURL: avatarURL
      )
      await MainActor.run {
        self.handleVideoGenerated(videoURL)
        self.isGeneratingVisualizerVideo = false
      }
    } catch {
      // If generation fails, leave audio in place and optionally notify user
      // For now, we simply reset the temporary audio state
      await MainActor.run {
        self.currentAudioURL = nil
        self.currentAudioDuration = 0
        self.isGeneratingVisualizerVideo = false
      }
      pcUIKitLogger.debug("Visualizer generation failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Drag & Drop
  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    var handled = false
    // Try images first via existing paste pipeline
    let imageTypes = [UTType.image.identifier]
    let urlTypes = [UTType.url.identifier, UTType.fileURL.identifier]
    let textTypes = [UTType.plainText.identifier]

    let imageProviders = providers.filter { p in imageTypes.contains(where: { p.hasItemConformingToTypeIdentifier($0) }) }
    if !imageProviders.isEmpty {
      handled = true
      Task { await viewModel.handleMediaPaste(imageProviders) }
    }

    // Handle URLs: append to text (end) so URL cards can form if desired
    let urlProviders = providers.filter { p in urlTypes.contains(where: { p.hasItemConformingToTypeIdentifier($0) }) }
    if !urlProviders.isEmpty {
      handled = true
      for provider in urlProviders {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
          if let url = item as? URL {
            DispatchQueue.main.async {
              self.viewModel.postText += (self.viewModel.postText.isEmpty ? "" : " ") + url.absoluteString
            }
          }
        }
      }
    }

    // Handle plain text (may include a URL); append
    let textProviders = providers.filter { p in textTypes.contains(where: { p.hasItemConformingToTypeIdentifier($0) }) }
    if !textProviders.isEmpty {
      handled = true
      for provider in textProviders {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
          if let text = item as? String {
            DispatchQueue.main.async {
              self.viewModel.postText += (self.viewModel.postText.isEmpty ? "" : " ") + text
            }
          }
        }
      }
    }

    return handled
  }

  // MARK: - Compact Outline Tags View

  private struct CompactOutlineTagsView: View {
    @Binding var tags: [String]
    @State private var newTag: String = ""
    @State private var isAddingTag: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    private let maxTagLength = 25
    private let maxTags = 10

    var body: some View {
      HStack(spacing: 8) {
          Image(systemName: "number")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                  Text("#\(tag)")
                    .font(.system(size: 11, weight: .medium))
                  Button(action: { removeTag(tag) }) {
                    Image(systemName: "xmark.circle.fill")
                      .font(.system(size: 10))
                      .foregroundColor(.secondary)
                  }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .foregroundColor(.secondary)
                .cornerRadius(6)
              }

              if isAddingTag {
                HStack(spacing: 4) {
                  TextField("hashtag", text: $newTag)
                    .focused($isTextFieldFocused)
                    .font(.system(size: 11, weight: .medium))
                    .frame(minWidth: 60)
                    .onSubmit { addTag() }

                  Button(action: addTag) {
                    Image(systemName: "checkmark.circle.fill")
                      .font(.system(size: 10))
                      .foregroundColor(.accentColor)
                  }
                  .disabled(!canAddTag)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
              } else if tags.count < maxTags {
                Button(action: { startAddingTag() }) {
                  Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
              }
            }
            .padding(.horizontal, 1)
          }
        }
        .padding(.vertical, 4)
    }

    private var canAddTag: Bool {
      let trimmedTag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmedTag.isEmpty &&
             trimmedTag.count <= maxTagLength &&
             tags.count < maxTags &&
             !tags.contains(cleanedTag(trimmedTag).lowercased())
    }

    private func startAddingTag() {
      isAddingTag = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        isTextFieldFocused = true
      }
    }

    private func addTag() {
      let trimmedTag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !trimmedTag.isEmpty else { return }
      guard trimmedTag.count <= maxTagLength else { return }
      guard tags.count < maxTags else { return }

      let cleanTag = cleanedTag(trimmedTag)

      if !tags.contains(where: { $0.lowercased() == cleanTag.lowercased() }) {
        tags.append(cleanTag.lowercased())
        newTag = ""
        isAddingTag = false
        isTextFieldFocused = false
      }
    }

    private func removeTag(_ tag: String) {
      tags.removeAll { $0 == tag }
    }

    private func cleanedTag(_ tag: String) -> String {
      var cleaned = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
      cleaned = cleaned.replacingOccurrences(of: " ", with: "")
      cleaned = cleaned.replacingOccurrences(of: "#", with: "")
      return cleaned
    }
  }

  // MARK: - Thread Vertical View
  private var threadVerticalView: some View {
    // Stack avatar + text box rows; tap to activate; inactive rows dimmed
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(viewModel.threadEntries.enumerated()), id: \.offset) { index, entry in
          ThreadPostEditorView(
            entry: entry,
            entryIndex: index,
            isCurrentPost: index == viewModel.currentThreadIndex,
            isEditing: false,
            viewModel: viewModel,
            onTap: {
              withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                viewModel.updateCurrentThreadEntry()
                viewModel.currentThreadIndex = index
                viewModel.loadEntryState()
              }
            },
            onDelete: {
              if viewModel.threadEntries.count > 1 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                  viewModel.removeThreadEntry(at: index)
                }
              }
            }
          )
          .draggable(entry.id.uuidString)
          .dropDestination(for: String.self) { items, _ in
            guard let idStr = items.first,
                  let sourceIndex = viewModel.threadEntries.firstIndex(where: { $0.id.uuidString == idStr }) else { return false }
            withAnimation(.easeInOut(duration: 0.2)) { viewModel.moveThreadEntry(from: sourceIndex, to: index) }
            return true
          }

          // Separator aligned under text box (avatar 60 + spacing 12 + horizontal padding 16 = 88)
          if index < viewModel.threadEntries.count - 1 {
            Divider()
              .padding(.leading, 88)
          }
        }

        // Add new post button at bottom
        Button(action: { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { viewModel.addNewThreadEntry() } }) {
          HStack(spacing: 16) {
            ZStack {
              if let profile = appState.currentUserProfile, let avatarURL = profile.avatar {
                AsyncImage(url: URL(string: avatarURL.description)) { image in
                  image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Circle().fill(Color.systemGray5) }
                .frame(width: 32, height: 32)
                .clipShape(Circle()).opacity(0.6)
              } else {
                Circle().fill(Color.systemGray5).frame(width: 32, height: 32)
              }
              Circle().fill(Color.accentColor).frame(width: 20, height: 20).overlay(Image(systemName: "plus").appFont(size: 12).foregroundColor(.white).fontWeight(.semibold)).offset(x: 8, y: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
              Text("Add another post").appFont(AppTextRole.subheadline).foregroundColor(.primary).fontWeight(.medium)
              Text("Continue this thread").appFont(AppTextRole.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").appFont(size: 14).foregroundColor(.secondary)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
          .background(RoundedRectangle(cornerRadius: 16).fill(Color.systemGray6).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.systemGray5, lineWidth: 1)))
          .padding(.horizontal, 16)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, 8)
      }
      .padding(.vertical, 8)
    }
  }
}
