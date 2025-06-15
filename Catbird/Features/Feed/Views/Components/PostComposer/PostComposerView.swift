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

func getAvailableLanguages() -> [LanguageCodeContainer] {
  // Define a curated list of common language tags following BCP 47
  let commonLanguageTags = [
    // Common language codes (ISO 639-1)
    "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
    "nl", "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh",

    // Common regional variants
    "en-US", "en-GB", "es-ES", "es-MX", "pt-BR", "pt-PT",
    "zh-CN", "zh-TW", "fr-FR", "fr-CA", "de-DE", "de-AT", "de-CH"
  ]

  // Create a dictionary to track unique languages with their full tags
  var uniqueLanguages: [String: LanguageCodeContainer] = [:]
  
  // Process each tag and keep only one entry per base language
  for tag in commonLanguageTags {
    let container = LanguageCodeContainer(languageCode: tag)
    let baseLanguageCode = container.lang.languageCode?.identifier ?? container.lang.minimalIdentifier
    
    // Either add this as a new language or replace if it's a regional variant
    // Prefer tags with regions (longer tags)
    if uniqueLanguages[baseLanguageCode] == nil || tag.count > uniqueLanguages[baseLanguageCode]!.lang.minimalIdentifier.count {
      uniqueLanguages[baseLanguageCode] = container
    }
  }
  
  // Sort the unique languages by their localized names
  return uniqueLanguages.values.sorted(by: { (a: LanguageCodeContainer, b: LanguageCodeContainer) -> Bool in
    let aName = Locale.current.localizedString(forLanguageCode: a.lang.languageCode?.identifier ?? "") ?? a.lang.minimalIdentifier
    let bName = Locale.current.localizedString(forLanguageCode: b.lang.languageCode?.identifier ?? "") ?? b.lang.minimalIdentifier
    return aName < bName
  })
}

// Helper function to get a properly formatted display name including region
func getDisplayName(for locale: Locale) -> String {
  let languageName = Locale.current.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? locale.identifier
  
  // If there's a region code, add it to the display name
  if let regionCode = locale.region?.identifier {
    let regionName = Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
    return "\(languageName) (\(regionName))"
  }
  
  return languageName
}

extension Sequence where Element: Hashable {
  func uniqued() -> [Element] {
    var set = Set<Element>()
    return filter { set.insert($0).inserted }
  }
}

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
    @State private var isKeyboardVisible = false
    
    init(parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil, appState: AppState) {
        self._viewModel = State(
            wrappedValue: PostComposerViewModel(parentPost: parentPost, quotedPost: quotedPost, appState: appState))
    }
    
    var body: some View {
        NavigationStack {
            mainContentView
            .interactiveDismissDisabled(true)
            .navigationTitle(getNavigationTitle())
            .navigationBarTitleDisplayMode(.inline)
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

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createPost) {
                        Text(getPostButtonText())
                            .appFont(AppTextRole.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(viewModel.isPostButtonDisabled || isSubmitting ? Color.accentColor.opacity(0.5) : Color.accentColor)
                            )
                    }
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
                
                ToolbarItemGroup(placement: .keyboard) {
                    keyboardToolbarContent
                }
            }
            .task {
                await viewModel.loadUserLanguagePreference()
            }
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
                matching: .videos
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
            .sheet(isPresented: $viewModel.showLabelSelector) {
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
            .sheet(isPresented: $viewModel.showThreadgateOptions) {
                ThreadgateOptionsView(settings: $viewModel.threadgateSettings)
            }
            // GIF picker sheet
            .sheet(isPresented: $viewModel.showingGifPicker) {
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
        }
    }
    
    // MARK: - Main Content Views
    
    private var mainContentView: some View {
        ZStack {
            // Use theme background for entire view
            Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                parentPostReplySection
                mainComposerArea
                
                // Show toolbar at bottom when keyboard is not visible
                if !isKeyboardVisible {
                    keyboardToolbarContent
                }
            }
            
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
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
                languageSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
    
    @ViewBuilder
    private var quotedPostSection: some View {
        if viewModel.quotedPost != nil {
            quotedPostPreview
        }
    }
    
    // MARK: - Quoted Post View

    private var quotedPostPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Remove quote button
            Button(action: {
                viewModel.quotedPost = nil
            }) {
                Text("Remove Quote")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.accentColor)
            }

            // PostView
            PostView(post: viewModel.quotedPost!, grandparentAuthor: nil, isParentPost: false, isSelectable: false, path: .constant(NavigationPath()), appState: appState)
//            PostEmbed(embed: .appBskyEmbedRecordView(.init(record: .appBskyEmbedRecordViewRecord(.init(uri: <#T##ATProtocolURI#>, cid: <#T##CID#>, author: <#T##AppBskyActorDefs.ProfileViewBasic#>, value: <#T##ATProtocolValueContainer#>, labels: <#T##[ComAtprotoLabelDefs.Label]?#>, replyCount: <#T##Int?#>, repostCount: <#T##Int?#>, likeCount: <#T##Int?#>, quoteCount: <#T##Int?#>, embeds: , indexedAt: <#T##ATProtocolDate#>)))), labels: <#T##[ComAtprotoLabelDefs.Label]?#>, path: <#T##Binding<NavigationPath>#>)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
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
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.threadEntries.enumerated()), id: \.offset) { index, entry in
                    VStack(spacing: 0) {
                        // Thread connection line (top)
                        if index > 0 {
                            threadConnectionLine
                        }
                        
                        // Thread post editor/preview
                        ThreadPostEditorView(
                            entry: entry,
                            entryIndex: index,
                            isCurrentPost: index == viewModel.currentThreadEntryIndex,
                            isEditing: index == viewModel.currentThreadEntryIndex,
                            viewModel: viewModel,
                            onTap: {
                                // Save current post content before switching
                                viewModel.updateCurrentThreadEntry()
                                viewModel.currentThreadEntryIndex = index
                                viewModel.loadEntryState()
                            },
                            onDelete: {
                                if viewModel.threadEntries.count > 1 {
                                    viewModel.removeThreadEntry(at: index)
                                }
                            }
                        )
                        .padding(.horizontal, 16)
                        
                        // Thread connection line (bottom)
                        if index < viewModel.threadEntries.count - 1 {
                            threadConnectionLine
                        }
                    }
                }
                
                // Add new post button at bottom
                addNewPostButton
            }
            .padding(.vertical, 16)
        }
    }
    
    private var threadConnectionLine: some View {
        HStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: 2, height: 16)
            Spacer()
        }
        .padding(.leading, 38) // Align with avatar center
    }
    
    private var addNewPostButton: some View {
        Button(action: {
            viewModel.addNewThreadEntry()
        }) {
            HStack(spacing: 12) {
                // User avatar placeholder
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "plus")
                            .appFont(size: 16)
                            .foregroundColor(.accentColor)
                    )
                
                Text("Add another post")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.accentColor)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Existing UI Components
    
    private var textEditorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Clean text editor without overlaid placeholder
            RichTextEditor(
                attributedText: $viewModel.richAttributedText,
                placeholder: "What's on your mind?",
                onImagePasted: { _ in
                    Task {
                        await viewModel.handleMediaPaste()
                    }
                },
                onGenmojiDetected: { genmojis in
                    Task {
                        await viewModel.processDetectedGenmoji(genmojis)
                    }
                },
                onTextChanged: { attributedText in
                    viewModel.updateFromAttributedText(attributedText)
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
                    .background(Color(.systemBackground))
                    .cornerRadius(8)
                }
            }
        }
        .background(Color(.systemBackground))
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
                            await viewModel.handleMediaPaste()
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
                        .foregroundStyle(.white, Color(.systemGray3))
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
    
    // Clean, modern keyboard toolbar with essential actions
    private var keyboardToolbarContent: some View {
        VStack(spacing: 0) {
            // Character count at top right
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(characterCountColor)
                        .frame(width: 6, height: 6)
                    Text("\(remainingCharacters)")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .foregroundColor(characterCountColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            
            // Main toolbar - essential actions only
            HStack(spacing: 24) {
                // Primary media actions
                HStack(spacing: 24) {
                    Button(action: {
                        photoPickerVisible = true
                    }) {
                        Image(systemName: "photo")
                            .appFont(size: 24)
                            .foregroundStyle(Color.accentColor)
                    }
                    
                    Button(action: {
                        videoPickerVisible = true
                    }) {
                        Image(systemName: "video")
                            .appFont(size: 24)
                            .foregroundStyle(Color.accentColor)
                    }
                    
                    // Cute monospaced GIF button (if enabled)
                    if appState.appSettings.allowTenor {
                        Button(action: {
                            viewModel.showingGifPicker = true
                        }) {
                            Text("GIF")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(viewModel.selectedGif != nil ? Color.accentColor : Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(viewModel.selectedGif != nil ? Color.accentColor : Color.accentColor, lineWidth: 1.5)
                                )
                        }
                    }
                }
                
                Spacer()
                
                // Secondary actions in overflow menu
                Menu {
                    // Emoji picker
                    Button(action: {
                        showingEmojiPicker = true
                    }) {
                        Label("Add Emoji", systemImage: "face.smiling")
                    }
                    
                    Divider()
                    
                    // Language selection submenu
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
                    
                    // Thread controls (if not replying)
                    if viewModel.parentPost == nil {
                        Divider()
                        
                        Button(action: {
                            if viewModel.isThreadMode {
                                viewModel.disableThreadMode()
                            } else {
                                viewModel.enableThreadMode()
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
                    
                    // Content labels
                    Button(action: {
                        viewModel.showLabelSelector = true
                    }) {
                        Label("Content Labels", systemImage: "tag")
                    }
                    
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .appFont(size: 24)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(Color(.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.gray.opacity(0.2)),
            alignment: .top
        )
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
                viewModel.alertItem = AlertItem(
                    title: "Error",
                    message: "Failed to create post: \(error.localizedDescription)"
                )
            }
        }
    }
    
    // ✅ CLEANED: Removed legacy handleImagePaste() and handleVideoPaste() methods
    // All paste handling is now unified through viewModel.handleMediaPaste()
    
}

struct ReplyingToView: View {
  let parentPost: AppBskyFeedDefs.PostView

  var body: some View {
    HStack {
      Text("Replying to")
        .foregroundColor(.secondary)
      Text("@\(parentPost.author.handle)")
        .fontWeight(.semibold)
        Spacer()
    }
    .appFont(AppTextRole.subheadline)
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
//    .background(Color(.systemGray5))
//    .cornerRadius(8)
  }
}

struct LabelSelectorView: View {
  @Binding var selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>
  @Environment(\.dismiss) private var dismiss

  // Define only the allowed self-labels
  private let allowedSelfLabels: [ComAtprotoLabelDefs.LabelValue] = [
    .exclamationnodashunauthenticated,
    .porn,
    .sexual,
    .nudity,
    ComAtprotoLabelDefs.LabelValue(rawValue: "graphic-media")  // This one isn't in predefined values
  ]
  
  // Display name mapping function
  private func displayName(for label: ComAtprotoLabelDefs.LabelValue) -> String {
    switch label.rawValue {
      case "!no-unauthenticated": return "Hide from Logged-out Users"
      case "porn": return "Adult Content"
      case "sexual": return "Sexual Content"
      case "nudity": return "Contains Nudity"
      case "graphic-media": return "Graphic Media"
      default: return label.rawValue.capitalized
    }
  }

  var body: some View {
    NavigationStack {
      List(allowedSelfLabels, id: \.self) { label in
        Button(action: { toggleLabel(label) }) {
          HStack {
            Text(displayName(for: label))
            Spacer()
            if selectedLabels.contains(label) {
              Image(systemName: "checkmark")
            }
          }
        }
      }
      .navigationTitle("Content Labels")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func toggleLabel(_ label: ComAtprotoLabelDefs.LabelValue) {
    if selectedLabels.contains(label) {
      selectedLabels.remove(label)
    } else {
      selectedLabels.insert(label)
    }
  }
}
// Add this extension to convert URLCardResponse to ViewExternal
extension URLCardResponse {
  func toViewExternal() -> AppBskyEmbedExternal.ViewExternal {
    // Create a URI from the URL string
    let uri = URI(self.url)

    return AppBskyEmbedExternal.ViewExternal(
      uri: uri ?? URI(""),
      title: self.title,
      description: self.description,
      thumb: URI(self.image)
    )
  }
}

// Replace URLCardView with this adapter for ExternalEmbedView
struct ComposeURLCardView: View {
  let card: URLCardResponse
  let onRemove: () -> Void
  let willBeUsedAsEmbed: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      ExternalEmbedView(
        external: card.toViewExternal(),
        shouldBlur: false,
        postID: card.id
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            willBeUsedAsEmbed ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.3),
            lineWidth: willBeUsedAsEmbed ? 2 : 1)
      )

      VStack(alignment: .trailing) {
        // Add featured badge if this will be used as embed
        if willBeUsedAsEmbed {
          Text("Featured")
            .appFont(AppTextRole.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.2))
            .foregroundColor(.accentColor)
            .cornerRadius(4)
        }

        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill")
            .appFont(AppTextRole.title3)
            .foregroundStyle(.white, Color(.systemGray3))
            .background(
              Circle()
                .fill(Color.black.opacity(0.3))
            )
        }
        .padding(8)
      }
      .padding(4)
    }
  }
}

// MARK: - Thread Components

struct ThreadPostEditorView: View {
    let entry: ThreadEntry
    let entryIndex: Int
    let isCurrentPost: Bool
    let isEditing: Bool
    @Bindable var viewModel: PostComposerViewModel
    let onTap: () -> Void
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTextFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                avatarView
                
                VStack(alignment: .leading, spacing: 8) {
                    authorInfoView
                    
                    if isEditing {
                        editingTextView
                    } else {
                        previewTextView
                    }
                    
                    if isEditing {
                        editingMediaView
                    } else {
                        previewMediaView
                    }
                    
                    characterCountView
                }
                
                Spacer()
                
                if !isEditing && viewModel.threadEntries.count > 1 {
                    deleteButton
                }
            }
            .padding(16)
            .background(backgroundView)
            .overlay(borderView)
            .onTapGesture {
                if !isEditing {
                    onTap()
                }
            }
        }
        .onChange(of: isEditing) {
            if isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFocused = true
                }
            }
        }
        .onChange(of: viewModel.postText) {
            if isEditing {
                viewModel.updatePostContent()
            }
        }
    }
    
    private var avatarView: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.3))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: "person.fill")
                    .appFont(size: 16)
                    .foregroundColor(.white)
            )
    }
    
    private var authorInfoView: some View {
        HStack {
            Text("You")
                .appFont(AppTextRole.subheadline)
                .fontWeight(.semibold)
            
            Text("@handle")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            if isEditing {
                editingIndicatorView
            }
        }
    }
    
    private var editingIndicatorView: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
            Text("editing")
                .appFont(AppTextRole.caption2)
                .foregroundColor(.orange)
        }
    }
    
    private var editingTextView: some View {
        TextField("What's happening?", text: $viewModel.postText, axis: .vertical)
            .textFieldStyle(PlainTextFieldStyle())
            .appFont(AppTextRole.body)
            .lineLimit(3...10)
            .focused($isTextFocused)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
            )
    }
    
    private var previewTextView: some View {
        Group {
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.text)
                    .appFont(AppTextRole.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Tap to add content")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    private var editingMediaView: some View {
        Group {
            if !viewModel.mediaItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.mediaItems, id: \.id) { item in
                            if let image = item.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            if let videoItem = viewModel.videoItem, let image = videoItem.image {
                HStack {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            Image(systemName: "play.circle.fill")
                                .appFont(size: 20)
                                .foregroundColor(.white)
                        )
                    Spacer()
                }
            }
        }
    }
    
    private var previewMediaView: some View {
        Group {
            if !entry.mediaItems.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .appFont(size: 12)
                        Text("\(entry.mediaItems.count)")
                            .appFont(AppTextRole.caption2)
                    }
                    .foregroundColor(.secondary)
                    Spacer()
                }
            }
            
            if entry.videoItem != nil {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "video")
                            .appFont(size: 12)
                        Text("Video")
                            .appFont(AppTextRole.caption2)
                    }
                    .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }
    
    private var characterCountView: some View {
        HStack {
            Spacer()
            let count = isEditing ? viewModel.postText.count : entry.text.count
            Text("\(count)/300")
                .appFont(AppTextRole.caption2)
                .foregroundColor(count > 300 ? .red : .secondary)
        }
    }
    
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .appFont(size: 20)
                .foregroundStyle(.white, Color(.systemGray3))
        }
        .padding(.top, 4)
    }
    
    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isCurrentPost ? Color.accentColor.opacity(0.05) : Color(.systemBackground))
    }
    
    private var borderView: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                isCurrentPost ? Color.accentColor.opacity(0.3) : Color(.systemGray5),
                lineWidth: isCurrentPost ? 2 : 1
            )
    }
}
