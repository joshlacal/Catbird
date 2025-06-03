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
            .onChange(of: viewModel.selectedImageItem) {
                Task {
                    await viewModel.loadSelectedImage()
                }
            }
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
                bottomToolbar
            }
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
            VStack(alignment: .leading, spacing: 12) {
                textEditorSection
                quotedPostSection
                mediaSection
                urlCardsSection
                languageSection
            }
            .padding()
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
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.3))
                                .frame(width: 2, height: 16)
                                .offset(x: -140) // Align with avatar position
                        }
                        
                        // Thread preview posts
                        ThreadPreviewPostView(
                            entry: entry,
                            isCurrentPost: index == viewModel.currentThreadEntryIndex,
                            onTap: {
                                // Save current post content before switching
                                viewModel.updateCurrentThreadEntry()
                                viewModel.currentThreadEntryIndex = index
                            }
                        )
                        .padding(.horizontal, 16)
                        
                        // Thread connection line (bottom)
                        if index < viewModel.threadEntries.count - 1 {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.3))
                                .frame(width: 2, height: 16)
                                .offset(x: -140) // Align with avatar position
                        }
                    }
                }
                
                // Add new post button at bottom
                Button(action: {
                    viewModel.addNewThreadEntry()
                }) {
                    HStack {
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
            .padding(.vertical, 16)
        }
    }
    
    // MARK: - Existing UI Components
    
    private var textEditorSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Background TextEditor for actual text input - no visible styling
                TextEditor(text: $viewModel.postText)
                    .focused($isTextFieldFocused)
                    .task { @MainActor in
                        isTextFieldFocused = true
                    }
                    .frame(minHeight: 120)
                    .padding(12)
                    .background(Color.clear) // Remove background styling
                    .onChange(of: viewModel.postText) {
                        viewModel.updatePostContent()
                    }
                
                // Placeholder text
                if viewModel.postText.isEmpty {
                    Text("What's on your mind?")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
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
                        Task {
                            await viewModel.handlePasteFromClipboard()
                        }
                    },
                    hasClipboardMedia: viewModel.hasClipboardMedia()
                )
                .padding(.vertical, 8)
            } else if let image = viewModel.selectedImage {
                singleImageView(image)
            } else {
                //        mediaButtonsView
                EmptyView()
            }
        }
    }
    
    private func selectedGifView(_ gif: TenorGif) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                LazyImage(url: gifPreviewURL(for: gif)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if state.isLoading {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                            .frame(height: 150)
                            .overlay(
                                ProgressView()
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray5))
                            .frame(height: 150)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                
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
    
    private func gifPreviewURL(for gif: TenorGif) -> URL? {
        // Use best quality animated GIF for preview - prioritize actual GIF format over MP4
        if let gif = gif.media_formats.gif {
            return URL(string: gif.url)
        } else if let mediumgif = gif.media_formats.mediumgif {
            return URL(string: mediumgif.url)
        } else if let tinygif = gif.media_formats.tinygif {
            return URL(string: tinygif.url)
        }
        return nil
    }

    private func singleImageView(_ image: Image) -> some View {
        VStack(alignment: .trailing) {
            ZStack(alignment: .topTrailing) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                
                Button(action: {
                    viewModel.selectedImageItem = nil
                    viewModel.selectedImage = nil
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
        }
    }
    
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
                ScrollView(Axis.Set.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(viewModel.selectedLanguages, id: \.self) { lang in
                            HStack {
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
                                        .appFont(AppTextRole.caption)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color(.systemGray5))
                            .cornerRadius(12)
                        }
                    }
                }
            }
            
            if let suggestedLang = viewModel.suggestedLanguage,
               !viewModel.selectedLanguages.contains(suggestedLang) {
                Button(action: {
                    viewModel.toggleLanguage(suggestedLang)
                }) {
                    Label(
                        "Add \(Locale.current.localizedString(forLanguageCode: suggestedLang.lang.languageCode?.identifier ?? "") ?? suggestedLang.lang.minimalIdentifier)",
                        systemImage: "plus.circle"
                    )
                    .appFont(AppTextRole.footnote)
                }
                .padding(.vertical, 4)
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
    
    // Modified bottom toolbar to include reply controls
    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            // Character count indicator at top
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    // Visual indicator circle
                    Circle()
                        .fill(characterCountColor)
                        .frame(width: 8, height: 8)
                    
                    // Countdown display
                    Text("\(remainingCharacters)")
                        .appFont(AppTextRole.footnote)
                        .fontWeight(.medium)
                        .foregroundColor(characterCountColor)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // Main toolbar
            HStack(spacing: 16) {
                // Media upload group
                HStack(spacing: 12) {
                    Button(action: {
                        photoPickerVisible = true
                    }) {
                        Image(systemName: "photo")
                            .appFont(size: 22)
                            .foregroundStyle(.primary)
                    }
                    
                    Button(action: {
                        videoPickerVisible = true
                    }) {
                        Image(systemName: "video")
                            .appFont(size: 22)
                            .foregroundStyle(.primary)
                    }
                    
                    if appState.appSettings.allowTenor {
                        Button(action: {
                            viewModel.showingGifPicker = true
                        }) {
                            Image(systemName: "gift")
                                .appFont(size: 22)
                                .foregroundStyle(viewModel.selectedGif != nil ? Color.accentColor : Color.primary)
                        }
                    }
                    
                    Button(action: {
                        Task {
                            await viewModel.handlePasteFromClipboard()
                        }
                    }) {
                        Image(systemName: "doc.on.clipboard")
                            .appFont(size: 22)
                            .foregroundStyle(viewModel.hasClipboardMedia() ? Color.accentColor : Color.primary)
                    }
                    .disabled(!viewModel.hasClipboardMedia())
                }
                
                // Separator
                Rectangle()
                    .frame(width: 1, height: 20)
                    .foregroundColor(.gray.opacity(0.3))
                
                // Text enhancement group
                HStack(spacing: 12) {
                    Button(action: {
                        showingEmojiPicker = true
                    }) {
                        Image(systemName: "face.smiling")
                            .appFont(size: 22)
                            .foregroundStyle(.primary)
                    }
                    
                    Menu {
                        ForEach(getAvailableLanguages(), id: \.self) { langContainer in
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
                        Image(systemName: "globe")
                            .appFont(size: 22)
                            .foregroundStyle(.primary)
                    }
                }
                
                Spacer()
                
                // Post settings group (right side)
                HStack(spacing: 12) {
                    // Thread toggle button (only show if not replying)
                    if viewModel.parentPost == nil {
                        Button(action: {
                            if viewModel.isThreadMode {
                                viewModel.disableThreadMode()
                            } else {
                                viewModel.enableThreadMode()
                            }
                        }) {
                            Image(
                                systemName: viewModel.isThreadMode
                                ? "minus.circle.fill" : "plus.circle.fill"
                            )
                            .appFont(size: 22)
                            .foregroundStyle(viewModel.isThreadMode ? Color.orange : Color.accentColor)
                        }
                    }
                    
                    // Add reply controls button (threadgate)
                    if viewModel.parentPost == nil {
                        Button(action: {
                            viewModel.showThreadgateOptions = true
                        }) {
                            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                                .appFont(size: 22)
                                .foregroundStyle(.primary)
                        }
                    }
                    
                    // Labels button
                    Button(action: {
                        viewModel.showLabelSelector = true
                    }) {
                        Image(systemName: "tag")
                            .appFont(size: 22)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.gray.opacity(0.3)),
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

struct ThreadPreviewPostView: View {
    let entry: ThreadEntry
    let isCurrentPost: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            postContentView
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var postContentView: some View {
        HStack(alignment: .top, spacing: 12) {
            avatarView
            VStack(alignment: .leading, spacing: 8) {
                authorInfoView
                textContentView
                mediaIndicatorsView
                characterCountView
            }
            Spacer()
        }
        .padding(12)
        .background(backgroundView)
        .overlay(borderView)
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
            
            if isCurrentPost {
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
    
    private var textContentView: some View {
        Group {
            if !entry.text.isEmpty {
                Text(entry.text)
                    .appFont(AppTextRole.body)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            } else {
                Text("Empty post")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }
    
    private var mediaIndicatorsView: some View {
        Group {
            if !entry.mediaItems.isEmpty || entry.videoItem != nil {
                HStack(spacing: 8) {
                    if !entry.mediaItems.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .appFont(size: 12)
                            Text("\(entry.mediaItems.count)")
                                .appFont(AppTextRole.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    if entry.videoItem != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "video")
                                .appFont(size: 12)
                            Text("1")
                                .appFont(AppTextRole.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    private var characterCountView: some View {
        HStack {
            Spacer()
            Text("\(entry.text.count)/300")
                .appFont(AppTextRole.caption2)
                .foregroundColor(entry.text.count > 300 ? .red : .secondary)
        }
    }
    
    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isCurrentPost ? Color.orange.opacity(0.1) : Color(.systemGray6))
    }
    
    private var borderView: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                isCurrentPost ? Color.orange.opacity(0.5) : Color.clear,
                lineWidth: 2
            )
    }
}
