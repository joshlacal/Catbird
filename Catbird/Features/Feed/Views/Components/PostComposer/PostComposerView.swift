//
//  PostComposerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import AVFoundation
import Foundation
import NukeUI
import os
import Petrel
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let postComposerLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Catbird", category: "PostComposer")

struct PostComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    // Store AppState reference locally to avoid global observation
    private let appState: AppState
    
    @State private var viewModel: PostComposerViewModel
    @FocusState private var isTextFieldFocused: Bool
    @State private var showingDismissAlert = false

    // Separate pickers for photos and videos
    @State private var photoPickerVisible = false
    @State private var videoPickerVisible = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var videoPickerItems: [PhotosPickerItem] = []
    
    // Thread UI state
    @State private var showThreadOptions: Bool = false
    @State private var isSubmitting = false
    @State private var showingEmojiPicker = false
    @State private var showingLinkCreation = false
    @State private var selectedTextForLink = ""
    @State private var selectedRangeForLink = NSRange()
    @State private var linkFacets: [RichTextFacetUtils.LinkFacet] = []
    
    // iOS 26+ AttributedString and TextEditor support (store as Any? to avoid availability on stored properties)
    @State private var attributedTextSelectionStorage: Any?

    // Convenience accessors for iOS 26+
    @available(iOS 26.0, macOS 15.0, *)
    private var attributedTextSelection: AttributedTextSelection? {
        get { attributedTextSelectionStorage as? AttributedTextSelection }
        set { attributedTextSelectionStorage = newValue }
    }
    
    // Audio recording state
    @State private var showingAudioRecorder = false
    @State private var showingAudioVisualizerPreview = false
    @State private var currentAudioURL: URL?
    @State private var currentAudioDuration: TimeInterval = 0
    // Visualizer generation progress
    @State private var isGeneratingVisualizerVideo = false
    @State private var visualizerService = AudioVisualizerService()
    
    // Account switching state
    @State private var showingAccountSwitcher = false
    
    // Minimize via button only (gesture removed)
    
    // Minimize callback - called when composer should be minimized
    let onMinimize: ((PostComposerViewModel) -> Void)?
    
    init(parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil, appState: AppState, onMinimize: ((PostComposerViewModel) -> Void)? = nil) {
        self.appState = appState
        self._viewModel = State(
            wrappedValue: PostComposerViewModel(parentPost: parentPost, quotedPost: quotedPost, appState: appState))
        self.onMinimize = onMinimize
        
        if #available(iOS 26.0, macOS 15.0, *) {
            self._attributedTextSelectionStorage = State(wrappedValue: AttributedTextSelection())
        } else {
            self._attributedTextSelectionStorage = State(wrappedValue: nil)
        }
    }
    
    
    init(restoringFromDraft draft: PostComposerDraft, appState: AppState, onMinimize: ((PostComposerViewModel) -> Void)? = nil) {
        self.appState = appState
        let viewModel = PostComposerViewModel(parentPost: nil, quotedPost: nil, appState: appState)
        // Restore full draft state
        viewModel.restoreDraftState(draft)
        
        self._viewModel = State(wrappedValue: viewModel)
        self.onMinimize = onMinimize
        
        if #available(iOS 26.0, macOS 15.0, *) {
            self._attributedTextSelectionStorage = State(wrappedValue: AttributedTextSelection())
        } else {
            self._attributedTextSelectionStorage = State(wrappedValue: nil)
        }
    }
    
    var body: some View {
        NavigationStack {
            configuredMainView
        }
    }
    
    private var configuredMainView: some View {
        configuredWithModifiers
    }
    
    private var baseMainView: some View {
        mainContentView
            #if os(iOS)
            .interactiveDismissDisabled(true)
            #endif
            .navigationTitle(getNavigationTitle())
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // User profile button for account switching
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        showingAccountSwitcher = true
                    }) {
                        #if os(iOS)
                        UIKitAvatarView(
                            did: appState.userDID,
                            client: appState.atProtoClient,
                            size: 32
                        )
                        #else
                        AvatarView(
                            did: appState.userDID,
                            client: appState.atProtoClient,
                            size: 32
                        )
                        #endif
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        // Show confirmation if there's content that would be lost
                        if !viewModel.postText.isEmpty || !viewModel.mediaItems.isEmpty || viewModel.videoItem != nil {
                            showingDismissAlert = true
                        } else {
                            dismiss() // Dismiss immediately if nothing to lose
                        }
                    }
                }
                
                // Minimize button (only show if minimize callback is provided)
                if onMinimize != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Minimize") {
                            handleMinimize()
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: createPost) {
                        Text(getPostButtonText())
                            .appFont(AppTextRole.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    #if os(iOS)
                    .adaptiveGlassEffect(
                        style: .accentTinted,
                        in: Capsule(),
                        interactive: true
                    )
                    #else
                    .background(Color.accentColor, in: Capsule())
                    #endif
                    .disabled(viewModel.isPostButtonDisabled || isSubmitting)
                    .opacity(isSubmitting ? 0.5 : 1)
                    .overlay(
                        Group {
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                        }
                    )
                }
            }
            // Navigation background uses default appearance again
            .task {
                await viewModel.loadUserLanguagePreference()
            }
            .id(appState.userDID)
    }
    
    private var configuredWithModifiers: some View {
        baseViewWithSafeArea
            .modifier(DiscardConfirmationModifier(showingDismissAlert: $showingDismissAlert, dismiss: dismiss))
            .modifier(MediaPickersModifier(
                photoPickerVisible: $photoPickerVisible,
                photoPickerItems: $photoPickerItems,
                videoPickerVisible: $videoPickerVisible,
                videoPickerItems: $videoPickerItems,
                viewModel: viewModel
            ))
            .modifier(SheetsModifier(
                viewModel: viewModel,
                isTextFieldFocused: Binding(
                    get: { isTextFieldFocused },
                    set: { isTextFieldFocused = $0 }
                ),
                showingAccountSwitcher: $showingAccountSwitcher,
                showingEmojiPicker: $showingEmojiPicker,
                showingLinkCreation: $showingLinkCreation,
                showingAudioRecorder: $showingAudioRecorder,
                isGeneratingVisualizerVideo: $isGeneratingVisualizerVideo,
                selectedTextForLink: selectedTextForLink,
                selectedRangeForLink: selectedRangeForLink,
                addLinkFacet: addLinkFacet,
                handleAudioRecorded: handleAudioRecorded,
                visualizerService: visualizerService
            ))
            .modifier(NotificationsModifier(handleLinkCreation: handleLinkCreation))
            .modifier(DraftSavingModifier(viewModel: viewModel))
    }
    
    private var baseViewWithSafeArea: some View {
        baseMainView
            .safeAreaInset(edge: .top) {
                if let reason = viewModel.videoUploadBlockedReason {
                    HStack(spacing: 10) {
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
    }
    
    // MARK: - Main Content Views
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            // Main content area with scrollable content
            ZStack {
                Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
                    .platformIgnoresSafeArea()
                
                VStack(spacing: 0) {
                    parentPostReplySection
                    mainComposerArea
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Toolbar pinned to bottom
            keyboardToolbar
        }
        // Drag-to-minimize gesture intentionally removed
    }
    
    @ViewBuilder
    private var parentPostReplySection: some View {
        if viewModel.parentPost != nil {
            ReplyingToView(parentPost: viewModel.parentPost!)
                .padding(.horizontal)
                .padding(.top)
        }
    }
    
    @ViewBuilder
    private var mainComposerArea: some View {
        if viewModel.isThreadMode {
            threadVerticalView
        } else {
            singlePostEditor
        }
    }
    
    private var singlePostEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                textEditorSection
                quotedPostSection
                mediaSection
                urlCardsSection
                outlineTagsSection
                languageSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
    
    @ViewBuilder
    private var quotedPostSection: some View {
        if let quotedPost = viewModel.quotedPost {
            VStack(alignment: .leading, spacing: 8) {
                // Remove quote button
                Button(action: {
                    viewModel.quotedPost = nil
                }) {
                    Text("Remove Quote")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.accentColor)
                }

                // Simplified post preview to avoid complex type resolution
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("@\(quotedPost.author.handle.description)")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    if case .knownType(let record) = quotedPost.record,
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


    // MARK: - New Thread UI Components

    // Get appropriate navigation title based on compose mode
    private func getNavigationTitle() -> String {
        if viewModel.isThreadMode {
            return "Thread"
        } else if viewModel.parentPost == nil && viewModel.quotedPost == nil {
            return "Post"
        } else if viewModel.quotedPost != nil {
            return "Quote"
        } else {
            return "Reply"
        }
    }
    
    // MARK: - Vertical Thread View
    
    private var threadVerticalView: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(Array(viewModel.threadEntries.enumerated()), id: \.offset) { index, entry in
                    VStack(spacing: 0) {
                        // Thread post editor/preview with card background
                        ThreadPostEditorView(
                            entry: entry,
                            entryIndex: index,
                            isCurrentPost: index == viewModel.currentThreadEntryIndex,
                            isEditing: index == viewModel.currentThreadEntryIndex,
                            viewModel: viewModel,
                            onTap: {
                                // Save current post content before switching
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    viewModel.updateCurrentThreadEntry()
                                    viewModel.currentThreadEntryIndex = index
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
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(index == viewModel.currentThreadEntryIndex ?
                                      Color.accentColor.opacity(0.05) :
                                      Color.systemBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(index == viewModel.currentThreadEntryIndex ?
                                               Color.accentColor.opacity(0.3) :
                                               Color.systemGray5, lineWidth: 1)
                                )
                        )
                        .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 2)
                        .padding(.horizontal, 16)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.currentThreadEntryIndex)
                        
                        // Thread connection line (only between posts, not after the last one)
                        if index < viewModel.threadEntries.count - 1 {
                            threadConnectionLine
                                .padding(.vertical, 12)
                        }
                    }
                }
                
                // Add new post button at bottom
                addNewPostButton
                    .padding(.top, 8)
            }
            .padding(.vertical, 20)
        }
    }
    
    private var threadConnectionLine: some View {
        HStack {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 4, height: 4)
                
                Rectangle()
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [
                            Color.accentColor.opacity(0.4),
                            Color.accentColor.opacity(0.2)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 3, height: 20)
                
                Circle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 4, height: 4)
            }
            
            Spacer()
        }
        .padding(.leading, 56) // Align with avatar center (40px/2 + 36px margin)
    }
    
    private var addNewPostButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                viewModel.addNewThreadEntry()
            }
        }) {
            HStack(spacing: 16) {
                // User avatar with plus overlay
                ZStack {
                    if let profile = appState.currentUserProfile,
                       let avatarURL = profile.avatar {
                        AsyncImage(url: URL(string: avatarURL.description)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle()
                                .fill(Color.systemGray5)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                        .opacity(0.6)
                    } else {
                        Circle()
                            .fill(Color.systemGray5)
                            .frame(width: 32, height: 32)
                    }
                    
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "plus")
                                .appFont(size: 12)
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                        )
                        .offset(x: 8, y: 8)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add another post")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.primary)
                        .fontWeight(.medium)
                    
                    Text("Continue this thread")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .appFont(size: 14)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.systemGray6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.systemGray5, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Existing UI Components
    
    private var textEditorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Modern SwiftUI TextEditor with AttributedString (iOS 26+) or legacy fallback
            ModernEnhancedRichTextEditor(
                attributedText: $viewModel.richAttributedText,
                linkFacets: $linkFacets,
                placeholder: "What's on your mind?",
                onImagePasted: { image in
                    Task {
                        let provider = NSItemProvider(object: image)
                        await viewModel.handleMediaPaste([provider])
                    }
                },
                onGenmojiDetected: { genmojiStrings in
                    Task {
                        // Process each genmoji string
                        for genmojiString in genmojiStrings {
                            if let genmojiData = genmojiString.data(using: .utf8) {
                                await viewModel.processDetectedGenmoji(genmojiData)
                            }
                        }
                    }
                },
                onTextChanged: nil,
                onAttributedTextChanged: { attributed in
                    if #available(iOS 26.0, macOS 15.0, *) {
                        viewModel.updateFromAttributedString(attributed)
                    } else {
                        viewModel.updateFromAttributedText(NSAttributedString(attributed))
                    }
                },
                onLinkCreationRequested: { selectedText, range in
                    logger.debug("📝 PostComposer: Link creation requested with text: '\(selectedText)' range: \(range)")
                    selectedTextForLink = selectedText
                    selectedRangeForLink = range
                    showingLinkCreation = true
                }
            )
            .frame(minHeight: 120)
            .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
            .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
            .focused($isTextFieldFocused)
            // Route URL taps to the in-app handler
            .environment(\.openURL, OpenURLAction { url in
                appState.urlHandler.handle(url)
            })
            .task { @MainActor in
                isTextFieldFocused = true
            }
            
            // Show mention suggestions below the text editor for all iOS versions
            // Note: When iOS 26+ ships built-in suggestions for TextEditor, this can be scoped to older OS versions.
            mentionSuggestionsView
        }
    }
    
    private var mentionSuggestionsView: some View {
        Group {
            if !viewModel.mentionSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.mentionSuggestions.enumerated()), id: \.element.did) { index, profile in
                        Button(action: {
                            _ = viewModel.insertMention(profile)
                        }) {
                            HStack(spacing: 12) {
                                // Avatar
                                Group {
                                    if let avatarURL = profile.avatar {
                                        AsyncImage(url: URL(string: avatarURL.description)) { image in
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Circle()
                                                .fill(Color.secondary.opacity(0.3))
                                        }
                                    } else {
                                        Circle()
                                            .fill(Color.secondary.opacity(0.3))
                                    }
                                }
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                                
                                // Profile info
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.displayName ?? profile.handle.description)
                                        .appFont(AppTextRole.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    
                                    Text("@\(profile.handle.description)")
                                        .appFont(AppTextRole.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .background(
                            Rectangle()
                                .fill(Color.clear)
                                .onTapGesture {
                                    _ = viewModel.insertMention(profile)
                                }
                        )
                        
                        // Divider between items (except last)
                        if index < viewModel.mentionSuggestions.count - 1 {
                            Divider()
                                .padding(.leading, 60) // Align with text content
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                // Ensure the content actually clips to rounded shape
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
            }
        }
    }
    
    private var mediaSection: some View {
        Group {
            if let selectedGif = viewModel.selectedGif {
                selectedGifView(selectedGif)
            } else if viewModel.videoItem != nil {
                // Fix the VideoPickerView call by providing all required parameters
                VideoPickerView(
                    videoItem: $viewModel.videoItem,
                    isUploading: $viewModel.isVideoUploading,
                    mediaUploadManager: viewModel.mediaUploadManager,
                    onEditAlt: viewModel.beginEditingAltText
                )
                .padding(.vertical, 8)
            } else if !viewModel.mediaItems.isEmpty {
                MediaGalleryView(
                    mediaItems: $viewModel.mediaItems,
                    currentEditingMediaId: $viewModel.currentEditingMediaId,
                    isAltTextEditorPresented: $viewModel.isAltTextEditorPresented,
                    maxImagesAllowed: viewModel.maxImagesAllowed,
                    onAddMore: { photoPickerVisible = true },
                    onMoveLeft: { id in viewModel.moveMediaItemLeft(id: id) },
                    onMoveRight: { id in viewModel.moveMediaItemRight(id: id) },
                    onCropSquare: { id in viewModel.cropMediaItemToSquare(id: id) },
                    onPaste: {
                        Task {
                            await viewModel.handleMediaPaste([])
                        }
                    },
                    hasClipboardMedia: viewModel.hasClipboardMedia(),
                    onReorder: { from, to in viewModel.moveMediaItem(from: from, to: to) }
                    // onExternalImageDrop is iOS-only and optional; omitted here
                )
                .padding(.vertical, 8)
            } else {
                // ✅ CLEANED: Removed legacy selectedImage fallback - all images now in mediaItems
                EmptyView()
            }
        }
    }
    
    private func selectedGifView(_ gif: TenorGif) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Use GifVideoView for animated preview
                GifVideoView(gif: gif, onTap: {})
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false) // Prevent interfering with remove button
                
                Button(action: {
                    viewModel.removeSelectedGif()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .appFont(AppTextRole.title1)
                        .foregroundStyle(.white, Color.systemGray3)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.3))
                        )
                }
                .padding(8)
            }
            
            // GIF info
            HStack {
                Image(systemName: "gift.fill")
                    .foregroundColor(.accentColor)
                
                Text(gif.title.isEmpty ? "GIF" : gif.title)
                    .appFont(AppTextRole.caption)
                    .lineLimit(2)
                
                Spacer()
                
                Text("via Tenor")
                    .appFont(AppTextRole.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 8)
    }
    

    // ✅ CLEANED: Removed singleImageView - no longer needed with unified mediaItems system
    
    private var urlCardsSection: some View {
        Group {
            // Only show the card for the selected embed URL (first URL detected)
            if let embedURL = viewModel.selectedEmbedURL, let card = viewModel.urlCards[embedURL] {
                ComposeURLCardView(
                    card: card,
                    onRemove: {
                        viewModel.removeURLCard(for: embedURL)
                    },
                    willBeUsedAsEmbed: viewModel.willBeUsedAsEmbed(for: embedURL),
                    onRemoveURLFromText: {
                        viewModel.removeURLFromText(for: embedURL)
                    }
                )
                .padding(.vertical, 4)
            }
            
            if viewModel.isLoadingURLCard {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            }
        }
    }
    
    private var languageSection: some View {
        Group {
            if !viewModel.selectedLanguages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "globe")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                        Text("Languages")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.selectedLanguages, id: \.self) { lang in
                                HStack(spacing: 6) {
                                    Text(
                                        Locale.current.localizedString(
                                            forLanguageCode: lang.lang.languageCode?.identifier ?? "")
                                        ?? lang.lang.minimalIdentifier
                                    )
                                    .appFont(AppTextRole.caption)
                                    
                                    Button(action: {
                                        viewModel.toggleLanguage(lang)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .appFont(AppTextRole.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundColor(.accentColor)
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 1) // Prevent clipping
                    }
                }
            }
        }
    }
    
    private var outlineTagsSection: some View {
        OutlineTagsView(tags: $viewModel.outlineTags, compact: true)
    }
    
    // Helper computed properties for character count
    private var remainingCharacters: Int {
        viewModel.maxCharacterCount - viewModel.characterCount
    }
    
    private var characterCountColor: Color {
        let remaining = remainingCharacters
        if remaining < 0 {
            return .red
        } else if remaining < 20 {
            return .orange
        } else if remaining < 50 {
            return .yellow
        } else {
            return .secondary
        }
    }
    
    
    private var keyboardToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 16) {
                // Character count
                HStack(spacing: 6) {
                    Circle()
                        .fill(characterCountColor)
                        .frame(width: 6, height: 6)
                    Text("\(remainingCharacters)")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .foregroundColor(characterCountColor)
                }
                
                Spacer()
                
                // Media buttons
                Button(action: {
                    photoPickerVisible = true
                }) {
                    Image(systemName: "photo")
                        .appFont(size: 22)
                        .foregroundStyle(Color.accentColor)
                }
                
                Button(action: {
                    videoPickerVisible = true
                }) {
                    Image(systemName: "video")
                        .appFont(size: 22)
                        .foregroundStyle(Color.accentColor)
                }
                
                // Audio/Microphone button
                Button(action: {
                    showingAudioRecorder = true
                }) {
                    Image(systemName: "mic")
                        .appFont(size: 22)
                        .foregroundStyle(Color.accentColor)
                }
                
                // GIF button
                if appState.appSettings.allowTenor {
                    Button(action: {
                        viewModel.showingGifPicker = true
                    }) {
                        Text("GIF")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor, lineWidth: 1.5)
                            )
                    }
                    .simultaneousGesture(TapGesture().onEnded { _ in
                        isTextFieldFocused = true
                    })
                }
                
                // Modern rich text formatting (iOS 26+)
                if #available(iOS 26.0, macOS 15.0, *) {
                    richTextFormattingButtons
                }
                
                // Menu
                Menu {
                    Button(action: {
                        showingEmojiPicker = true
                    }) {
                        Label("Add Emoji", systemImage: "face.smiling")
                    }
                    
                    Button(action: {
                        handleLinkCreation()
                    }) {
                        Label("Create Link", systemImage: "link")
                    }
                    .keyboardShortcut("l", modifiers: .command)
                    
                    Divider()
                    
                    Menu {
                        ForEach(getAvailableLanguages().prefix(8), id: \.self) { langContainer in
                            Button(action: {
                                viewModel.toggleLanguage(langContainer)
                            }) {
                                let displayName = Locale.current.localizedString(
                                    forLanguageCode: langContainer.lang.languageCode?.identifier ?? ""
                                ) ?? langContainer.lang.minimalIdentifier
                                
                                if viewModel.selectedLanguages.contains(langContainer) {
                                    Label(displayName, systemImage: "checkmark")
                                } else {
                                    Text(displayName)
                                }
                            }
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                    
                    if viewModel.parentPost == nil {
                        Divider()
                        
                        Button(action: {
                            if viewModel.isThreadMode {
                                viewModel.exitThreadMode()
                            } else {
                                viewModel.enterThreadMode()
                            }
                        }) {
                            Label(
                                viewModel.isThreadMode ? "Exit Thread Mode" : "Create Thread",
                                systemImage: viewModel.isThreadMode ? "minus.circle" : "plus.circle"
                            )
                        }
                        
                        Button(action: {
                            viewModel.showThreadgateOptions = true
                        }) {
                            Label("Reply Controls", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                        }
                    }
                    
                    Button(action: {
                        viewModel.showLabelSelector = true
                    }) {
                        Label("Content Labels", systemImage: "tag")
                    }
                    // Account switching available via avatar button in the navigation bar
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .appFont(size: 22)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.secondarySystemBackground)
        }
        .background(Color.secondarySystemBackground)
        .id("postComposerToolbar") // Stable identity to prevent SwiftUI from recreating
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private var richTextFormattingButtons: some View {
        HStack(spacing: 12) {
            // Link button (links-only policy)
            Button(action: {
                requestLinkCreation()
            }) {
                Image(systemName: "link")
                    .appFont(size: 18)
                    .foregroundStyle(Color.accentColor)
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }
    
    // MARK: - iOS 26+ Text Formatting Methods
    
    @Environment(\.fontResolutionContext) private var fontResolutionContext
    
    @available(iOS 26.0, macOS 15.0, *)
    private var isBoldSelected: Bool {
        guard let attributedTextSelection = attributedTextSelection else { return false }
        let indices = attributedTextSelection.indices(in: viewModel.attributedPostText)
        
        switch indices {
        case .insertionPoint:
            // Could use typingAttributes(in:) for insertion point; default to false for now
            return false
        case .ranges(let rangeSet):
            if let firstRange = rangeSet.ranges.first, !firstRange.isEmpty {
                let attributes = viewModel.attributedPostText[firstRange]
                if let font = attributes.font {
                    let resolved = font.resolve(in: fontResolutionContext)
                    return resolved.isBold
                }
            }
            return false
        }
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private var isItalicSelected: Bool {
        guard let attributedTextSelection = attributedTextSelection else { return false }
        let indices = attributedTextSelection.indices(in: viewModel.attributedPostText)
        
        switch indices {
        case .insertionPoint:
            return false
        case .ranges(let rangeSet):
            if let firstRange = rangeSet.ranges.first, !firstRange.isEmpty {
                let attributes = viewModel.attributedPostText[firstRange]
                if let font = attributes.font {
                    let resolved = font.resolve(in: fontResolutionContext)
                    return resolved.isItalic
                }
            }
            return false
        }
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private var isUnderlineSelected: Bool {
        guard let attributedTextSelection = attributedTextSelection else { return false }
        let indices = attributedTextSelection.indices(in: viewModel.attributedPostText)
        
        switch indices {
        case .insertionPoint:
            return false
        case .ranges(let rangeSet):
            if let firstRange = rangeSet.ranges.first, !firstRange.isEmpty {
                let attributes = viewModel.attributedPostText[firstRange]
                return attributes.underlineStyle != nil && attributes.underlineStyle != .none
            }
            return false
        }
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private func toggleBold() {
        guard var selection = attributedTextSelection else { return }
        viewModel.attributedPostText.transformAttributes(in: &selection) { container in
            let currentFont = container.font ?? .body
            let resolved = currentFont.resolve(in: fontResolutionContext)
            container.font = currentFont.bold(!resolved.isBold)
        }
        attributedTextSelectionStorage = selection
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private func toggleItalic() {
        guard var selection = attributedTextSelection else { return }
        viewModel.attributedPostText.transformAttributes(in: &selection) { container in
            let currentFont = container.font ?? .body
            let resolved = currentFont.resolve(in: fontResolutionContext)
            container.font = currentFont.italic(!resolved.isItalic)
        }
        attributedTextSelectionStorage = selection
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private func toggleUnderline() {
        guard var selection = attributedTextSelection else { return }
        viewModel.attributedPostText.transformAttributes(in: &selection) { container in
            let currentStyle = container.underlineStyle ?? .none
            container.underlineStyle = currentStyle == .none ? .single : .none
        }
        attributedTextSelectionStorage = selection
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private func requestLinkCreation() {
        guard let attributedTextSelection = attributedTextSelection else { return }
        let indices = attributedTextSelection.indices(in: viewModel.attributedPostText)
        
        switch indices {
        case .insertionPoint(let caret):
            // Allow link insertion at caret; use URL as display text
            let location = viewModel.attributedPostText.utf16.distance(from: viewModel.attributedPostText.startIndex, to: caret)
            selectedTextForLink = ""
            selectedRangeForLink = NSRange(location: location, length: 0)
            showingLinkCreation = true
        case .ranges(let rangeSet):
            if let range = rangeSet.ranges.first {
                let selectedText = String(viewModel.attributedPostText[range].characters)
                let location = viewModel.attributedPostText.utf16.distance(from: viewModel.attributedPostText.startIndex, to: range.lowerBound)
                let length = viewModel.attributedPostText.utf16.distance(from: range.lowerBound, to: range.upperBound)
                let nsRange = NSRange(location: location, length: length)
                
                logger.debug("📝 PostComposer: Link creation requested with text: '\(selectedText)' range: \(nsRange)")
                selectedTextForLink = selectedText
                selectedRangeForLink = nsRange
                showingLinkCreation = true
            } else {
                logger.debug("📝 PostComposer: No selection range found for link creation")
            }
        }
    }
    
    // MARK: - Link Creation Methods
    
    /// Unified link creation handler that works across iOS versions
    private func handleLinkCreation() {
        if #available(iOS 26.0, macOS 15.0, *) {
            requestLinkCreation()
        } else {
            // For legacy versions, trigger link creation at current cursor position
            selectedTextForLink = ""
            selectedRangeForLink = NSRange(location: viewModel.postText.count, length: 0)
            showingLinkCreation = true
        }
    }
    
    // Get the appropriate text for the post button
    private func getPostButtonText() -> String {
        if viewModel.isThreadMode {
            return "Post" // Post thread is too wide on small devices. It's pretty clear that it's a thread post when you see the thread indicator above
        } else if viewModel.parentPost != nil {
            return "Reply"
        } else {
            return "Post"
        }
    }
    
    // MARK: - Post Creation
    
    // Create post or thread based on current mode
    private func createPost() {
        guard !isSubmitting else { return } // Prevent multiple submissions
        
        isSubmitting = true
        
        Task {
            do {
                if viewModel.isThreadMode {
                    try await viewModel.createThread()
                } else {
                    try await viewModel.createPost()
                }
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                logger.debug("PostComposerView: Failed to create post - \(error)")
                
                // Get more specific error message
                let errorMessage: String
                if let nsError = error as NSError? {
                    errorMessage = nsError.localizedDescription
                    logger.debug("PostComposerView: NSError domain: \(nsError.domain), code: \(nsError.code)")
                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                        logger.debug("PostComposerView: Underlying error: \(underlyingError)")
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
                
                viewModel.alertItem = AlertItem(
                    title: "Failed to Create Post",
                    message: errorMessage
                )
            }
        }
    }
    
    // MARK: - Minimize Functionality
    
    private func handleMinimize() {
        onMinimize?(viewModel)
        dismiss()
    }
    
    // ✅ CLEANED: Removed legacy handleImagePaste() and handleVideoPaste() methods
    // All paste handling is now unified through viewModel.handleMediaPaste()
    
    // MARK: - Link Facet Methods
    
    private func addLinkFacet(url: URL, displayText: String?, range: NSRange) {
        logger.debug("Composer.addLinkFacet url=\(url.absoluteString) range=\(range.debugDescription)")
        
        // Use modern approach for iOS 26+ and legacy approach for older versions
        if #available(iOS 26.0, macOS 15.0, *) {
            // Convert NSRange to AttributedString range
            let start = viewModel.attributedPostText.index(
                viewModel.attributedPostText.startIndex,
                offsetByCharacters: range.location
            )
            let end = viewModel.attributedPostText.index(
                start,
                offsetByCharacters: range.length
            )
            let attrRange = start..<end
            
            let display = (displayText?.isEmpty == false) ? displayText : nil
            viewModel.insertLinkWithAttributedString(url: url, displayText: display, at: attrRange)
            
        } else {
            // Legacy: apply NSAttributedString attributes or insert when at caret
            let newAttributedText = RichTextFacetUtils.addOrInsertLinkFacet(
                to: viewModel.richAttributedText,
                url: url,
                range: range,
                displayText: displayText
            )
            viewModel.richAttributedText = newAttributedText
            
            // Update the plain text from the attributed text
            viewModel.postText = newAttributedText.string
            
            // Maintain local tracking for older flow if needed
            let effectiveRange = range.length == 0 ? NSRange(location: range.location, length: (displayText?.count ?? 0)) : range
            let linkFacet = RichTextFacetUtils.LinkFacet(
                range: effectiveRange,
                url: url,
                displayText: displayText ?? ""
            )
            linkFacets.append(linkFacet)
            logger.debug("Composer.legacy linkFacets count=\(linkFacets.count)")
        }
    }
    
    
    private func updateFacetsInPost() {
        // Modern flow uses Petrel's AttributedString.toFacets(); legacy can use utility fallback
        if #available(iOS 26.0, macOS 15.0, *) {
            // Facets are computed inside updateFromAttributedString/updatePostContent
            return
        } else {
            _ = RichTextFacetUtils.createFacets(from: linkFacets, in: viewModel.postText)
        }
    }
    
    // MARK: - Audio Recording Methods
    
    private func handleAudioRecorded(_ audioURL: URL) {
        // Get audio duration
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
        // Convert the generated video to a MediaItem and add it to the composer
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
            await MainActor.run {
                self.currentAudioURL = nil
                self.currentAudioDuration = 0
                self.isGeneratingVisualizerVideo = false
            }
            postComposerLogger.debug("Visualizer generation failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Custom View Modifiers

struct DiscardConfirmationModifier: ViewModifier {
    @Binding var showingDismissAlert: Bool
    let dismiss: DismissAction
    
    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Discard post?",
                isPresented: $showingDismissAlert,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {
                    // Just close the dialog and continue editing
                }
            } message: {
                Text("You'll lose your post if you discard now.")
            }
    }
}

struct MediaPickersModifier: ViewModifier {
    @Binding var photoPickerVisible: Bool
    @Binding var photoPickerItems: [PhotosPickerItem]
    @Binding var videoPickerVisible: Bool
    @Binding var videoPickerItems: [PhotosPickerItem]
    let viewModel: PostComposerViewModel
    
    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $photoPickerVisible,
                selection: $photoPickerItems,
                maxSelectionCount: viewModel.maxImagesAllowed,
                matching: .images
            )
            .onChange(of: photoPickerItems) {
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
            .onChange(of: videoPickerItems) {
                Task {
                    if let item = videoPickerItems.first {
                        await viewModel.processVideoSelection(item)
                        videoPickerItems.removeAll()
                    }
                }
            }
    }
}

struct SheetsModifier: ViewModifier {
    @Bindable var viewModel: PostComposerViewModel
    @Binding var isTextFieldFocused: Bool
    @Binding var showingAccountSwitcher: Bool
    @Binding var showingEmojiPicker: Bool
    @Binding var showingLinkCreation: Bool
    @Binding var showingAudioRecorder: Bool
    @Binding var isGeneratingVisualizerVideo: Bool
    let selectedTextForLink: String
    let selectedRangeForLink: NSRange
    let addLinkFacet: (URL, String?, NSRange) -> Void
    let handleAudioRecorded: (URL) -> Void
    let visualizerService: AudioVisualizerService
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showLabelSelector, onDismiss: {
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                LabelSelectorView(selectedLabels: $viewModel.selectedLabels)
            }
            .sheet(isPresented: $viewModel.isAltTextEditorPresented) {
                if let editingId = viewModel.currentEditingMediaId {
                    if let videoItem = viewModel.videoItem, videoItem.id == editingId,
                       let image = videoItem.image {
                        AltTextEditorView(
                            altText: videoItem.altText,
                            image: image,
                            imageId: videoItem.id,
                            imageData: videoItem.rawData,
                            onSave: viewModel.updateAltText
                        )
                    } else if let index = viewModel.mediaItems.firstIndex(where: { $0.id == editingId }),
                              let image = viewModel.mediaItems[index].image {
                        AltTextEditorView(
                            altText: viewModel.mediaItems[index].altText,
                            image: image,
                            imageId: editingId,
                            imageData: viewModel.mediaItems[index].rawData,
                            onSave: viewModel.updateAltText
                        )
                    }
                }
            }
            .sheet(isPresented: $viewModel.showThreadgateOptions, onDismiss: {
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                ThreadgateOptionsView(settings: $viewModel.threadgateSettings)
            }
            .sheet(isPresented: $viewModel.showingGifPicker, onDismiss: {
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                GifPickerView { gif in
                    viewModel.selectGif(gif)
                }
            }
            .alert(item: $viewModel.alertItem) { alertItem in
                Alert(
                    title: Text(alertItem.title),
                    message: Text(alertItem.message),
                    dismissButton: .default(Text("OK")))
            }
            .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
                viewModel.insertEmoji(emoji)
            }
            .sheet(isPresented: $showingLinkCreation, onDismiss: {
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                LinkCreationDialog(
                    selectedText: selectedTextForLink,
                    onComplete: { url, display in
                        addLinkFacet(url, display, selectedRangeForLink)
                        showingLinkCreation = false
                    },
                    onCancel: {
                        showingLinkCreation = false
                    }
                )
            }
            .sheet(isPresented: $showingAudioRecorder, onDismiss: {
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                PostComposerAudioRecordingView(
                    onAudioRecorded: { audioURL in
                        handleAudioRecorded(audioURL)
                    },
                    onCancel: {
                        showingAudioRecorder = false
                    }
                )
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
            .sheet(isPresented: $showingAccountSwitcher, onDismiss: {
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                // Pass current draft when switching accounts from composer
                AccountSwitcherView(draftToTransfer: viewModel.saveDraftState())
            }
    }
}

struct NotificationsModifier: ViewModifier {
    let handleLinkCreation: () -> Void
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .init("CreateLinkKeyboardShortcut"))) { _ in
                handleLinkCreation()
            }
    }
}

struct DraftSavingModifier: ViewModifier {
    let viewModel: PostComposerViewModel
    
    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.selectedLabels) { _, _ in
                viewModel.saveDraftIfNeeded()
            }
            .onChange(of: viewModel.threadgateSettings.allowEverybody) { _, _ in
                viewModel.saveDraftIfNeeded()
            }
            .onChange(of: viewModel.threadgateSettings.allowMentioned) { _, _ in
                viewModel.saveDraftIfNeeded()
            }
            .onChange(of: viewModel.threadgateSettings.allowFollowing) { _, _ in
                viewModel.saveDraftIfNeeded()
            }
            .onChange(of: viewModel.threadgateSettings.allowLists) { _, _ in
                viewModel.saveDraftIfNeeded()
            }
            .onChange(of: viewModel.threadgateSettings.selectedLists) { _, _ in
                viewModel.saveDraftIfNeeded()
            }
    }
}
