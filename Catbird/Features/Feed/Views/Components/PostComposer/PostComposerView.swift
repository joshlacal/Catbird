//
//  PostComposerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import AVFoundation
import Foundation
import NukeUI
import Petrel
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PostComposerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
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
    
    // Audio recording state
    @State private var showingAudioRecorder = false
    @State private var showingAudioVisualizerPreview = false
    @State private var currentAudioURL: URL?
    @State private var currentAudioDuration: TimeInterval = 0
    
    // Minimize functionality
    @State private var dragOffset: CGFloat = 0
    private let minimizeThreshold: CGFloat = 100
    
    // Minimize callback - called when composer should be minimized
    let onMinimize: ((PostComposerViewModel) -> Void)?
    
    init(parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil, appState: AppState, onMinimize: ((PostComposerViewModel) -> Void)? = nil) {
        self._viewModel = State(
            wrappedValue: PostComposerViewModel(parentPost: parentPost, quotedPost: quotedPost, appState: appState))
        self.onMinimize = onMinimize
    }
    
    init(restoringFrom draft: ComposerDraft, parentPost: AppBskyFeedDefs.PostView?, quotedPost: AppBskyFeedDefs.PostView?, appState: AppState, onMinimize: ((PostComposerViewModel) -> Void)? = nil) {
        let viewModel = PostComposerViewModel(parentPost: parentPost, quotedPost: quotedPost, appState: appState)
        // Restore text content
        viewModel.postText = draft.text
        viewModel.richAttributedText = NSAttributedString(string: draft.text)
        // NOTE: In a full implementation, we would also restore media items, GIF selection, etc.
        // This would require serializing those components in the ComposerDraft struct
        
        self._viewModel = State(wrappedValue: viewModel)
        self.onMinimize = onMinimize
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
            .task {
                await viewModel.loadUserLanguagePreference()
            }
    }
    
    private var configuredWithModifiers: some View {
        baseMainView
            .modifier(DiscardConfirmationModifier(showingDismissAlert: $showingDismissAlert, dismiss: dismiss))
            // Media pickers
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
                matching: .any(of: [.videos, .images])
            )
            .onChange(of: videoPickerItems) {
                Task {
                    if let item = videoPickerItems.first {
                        await viewModel.processVideoSelection(item)
                        videoPickerItems.removeAll()
                    }
                }
            }
            // Sheets
            .sheet(isPresented: $viewModel.showLabelSelector, onDismiss: {
                // Restore focus when sheet dismisses
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
                            onSave: viewModel.updateAltText
                        )
                    } else if let index = viewModel.mediaItems.firstIndex(where: { $0.id == editingId }),
                              let image = viewModel.mediaItems[index].image {
                        AltTextEditorView(
                            altText: viewModel.mediaItems[index].altText,
                            image: image,
                            imageId: editingId,
                            onSave: viewModel.updateAltText
                        )
                    }
                }
            }
            // Add the threadgate options sheet
            .sheet(isPresented: $viewModel.showThreadgateOptions, onDismiss: {
                // Restore focus when threadgate sheet dismisses
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                ThreadgateOptionsView(settings: $viewModel.threadgateSettings)
            }
            // GIF picker sheet
            .sheet(isPresented: $viewModel.showingGifPicker, onDismiss: {
                // Restore focus when GIF picker dismisses
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                GifPickerView { gif in
                    viewModel.selectGif(gif)
                }
            }
            // Alerts
            .alert(item: $viewModel.alertItem) { alertItem in
                Alert(
                    title: Text(alertItem.title),
                    message: Text(alertItem.message),
                    dismissButton: .default(Text("OK")))
            }
            // ✅ CLEANED: Removed selectedImageItem handling - now using direct processing
            .emojiPicker(isPresented: $showingEmojiPicker) { emoji in
                viewModel.insertEmoji(emoji)
            }
            // Link creation sheet
            .sheet(isPresented: $showingLinkCreation, onDismiss: {
                // Restore focus when link creation sheet dismisses
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                LinkCreationDialog(
                    selectedText: selectedTextForLink,
                    onComplete: { url in
                        addLinkFacet(url: url, range: selectedRangeForLink)
                        showingLinkCreation = false
                    },
                    onCancel: {
                        showingLinkCreation = false
                    }
                )
            }
            // Audio recording sheet
            .sheet(isPresented: $showingAudioRecorder, onDismiss: {
                // Restore focus when audio recorder dismisses
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                AudioRecordingView(
                    onAudioRecorded: { audioURL in
                        handleAudioRecorded(audioURL)
                    },
                    onCancel: {
                        showingAudioRecorder = false
                    }
                )
            }
            // Audio visualizer preview sheet
            .sheet(isPresented: $showingAudioVisualizerPreview, onDismiss: {
                // Restore focus when visualizer preview dismisses
                Task { @MainActor in
                    isTextFieldFocused = true
                }
            }) {
                if let audioURL = currentAudioURL {
                    AudioVisualizerPreview(
                        audioURL: audioURL,
                        audioDuration: currentAudioDuration,
                        onVideoGenerated: { videoURL in
                            handleVideoGenerated(videoURL)
                        },
                        onCancel: {
                            showingAudioVisualizerPreview = false
                            currentAudioURL = nil
                            currentAudioDuration = 0
                        }
                    )
                }
            }
    }
    
    // MARK: - Main Content Views
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            // Drag handle for minimize gesture (only show if minimize callback is provided)
            if onMinimize != nil {
                dragHandle
            }
            
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
        .offset(y: dragOffset)
        .gesture(
            // Only add drag gesture if minimize callback is provided
            onMinimize != nil ? 
            DragGesture()
                .onChanged { value in
                    // Only allow downward drag for minimize
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > minimizeThreshold {
                        handleMinimize()
                    } else {
                        // Snap back to original position
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
            : nil
        )
    }
    
    private var dragHandle: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
            
            HStack {
                Text("Drag down to minimize")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Color.systemBackground)
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
            return "New Thread"
        } else if viewModel.parentPost == nil && viewModel.quotedPost == nil {
            return "New Post"
        } else if viewModel.quotedPost != nil {
            return "Quote Post"
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
            // Clean text editor without overlaid placeholder
            EnhancedRichTextEditor(
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
                onTextChanged: { attributedText in
                    viewModel.updateFromAttributedText(attributedText)
                },
                onLinkCreationRequested: { selectedText, range in
                    selectedTextForLink = selectedText
                    selectedRangeForLink = range
                    showingLinkCreation = true
                }
            )
            .frame(minHeight: 120)
            .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
            .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
            .focused($isTextFieldFocused)
            .task { @MainActor in
                isTextFieldFocused = true
            }
            
            // Show mention suggestions below the text editor
            mentionSuggestionsView
        }
    }
    
    private var mentionSuggestionsView: some View {
        VStack(alignment: .leading) {
            ForEach(viewModel.mentionSuggestions, id: \.did) { profile in
                Button(action: {
                    viewModel.insertMention(profile)
                }) {
                    HStack {
                        Text("@\(profile.handle.description)")
                        Text(profile.displayName ?? "")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.systemBackground)
                    .cornerRadius(8)
                }
            }
        }
        .background(Color.systemBackground)
        .cornerRadius(8)
        .shadow(radius: 2)
        .opacity(viewModel.mentionSuggestions.isEmpty ? 0 : 1)
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
                    onPaste: {
                        // ✅ CLEANED: Unified paste handling
                        Task {
                            await viewModel.handleMediaPaste([])
                        }
                    },
                    hasClipboardMedia: viewModel.hasClipboardMedia()
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
            ForEach(viewModel.detectedURLs, id: \.self) { url in
                if let card = viewModel.urlCards[url] {
                    ComposeURLCardView(
                        card: card,
                        onRemove: {
                            viewModel.removeURLCard(for: url)
                        }, willBeUsedAsEmbed: viewModel.willBeUsedAsEmbed(for: url)
                    )
                    .padding(.vertical, 4)
                }
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
        OutlineTagsView(tags: $viewModel.outlineTags)
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
                
                // Menu
                Menu {
                    Button(action: {
                        showingEmojiPicker = true
                    }) {
                        Label("Add Emoji", systemImage: "face.smiling")
                    }
                    
                    Button(action: {
                        // For now, show a simple alert - in a real implementation
                        // this would integrate with the text selection system
                        showingLinkCreation = true
                    }) {
                        Label("Create Link", systemImage: "link")
                    }
                    
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
                print("PostComposerView: Failed to create post - \(error)")
                
                // Get more specific error message
                let errorMessage: String
                if let nsError = error as NSError? {
                    errorMessage = nsError.localizedDescription
                    print("PostComposerView: NSError domain: \(nsError.domain), code: \(nsError.code)")
                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                        print("PostComposerView: Underlying error: \(underlyingError)")
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
                
                viewModel.alertItem = PostComposerViewModel.AlertItem(
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
    
    private func addLinkFacet(url: URL, range: NSRange) {
        let linkFacet = RichTextFacetUtils.LinkFacet(
            range: range,
            url: url,
            displayText: selectedTextForLink
        )
        
        linkFacets.append(linkFacet)
        
        let newAttributedText = RichTextFacetUtils.addLinkFacet(
            to: viewModel.richAttributedText,
            url: url,
            range: range
        )
        
        viewModel.richAttributedText = newAttributedText
    }
    
    private func updateFacetsInPost() {
        // Convert link facets to AT Protocol facets for post creation
        let atProtocolFacets = RichTextFacetUtils.createFacets(
            from: linkFacets,
            in: viewModel.postText
        )
        
        // Update the view model with the facets
        // This would need to be added to PostComposerViewModel
        // viewModel.linkFacets = atProtocolFacets
    }
    
    // MARK: - Audio Recording Methods
    
    private func handleAudioRecorded(_ audioURL: URL) {
        // Get audio duration
        let asset = AVURLAsset(url: audioURL)
        let duration = CMTimeGetSeconds(asset.duration)
        
        currentAudioURL = audioURL
        currentAudioDuration = duration
        showingAudioRecorder = false
        showingAudioVisualizerPreview = true
    }
    
    private func handleVideoGenerated(_ videoURL: URL) {
        // Convert the generated video to a MediaItem and add it to the composer
        Task {
            await viewModel.processGeneratedVideoFromAudio(videoURL)
            showingAudioVisualizerPreview = false
            currentAudioURL = nil
            currentAudioDuration = 0
        }
    }
}

// MARK: - Custom View Modifier for Discard Confirmation

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
