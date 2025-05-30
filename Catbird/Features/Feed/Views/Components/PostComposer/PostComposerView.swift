//
//  PostComposerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import AVFoundation
import Foundation
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
    
    init(parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil, appState: AppState) {
        self._viewModel = State(
            wrappedValue: PostComposerViewModel(parentPost: parentPost, quotedPost: quotedPost, appState: appState))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Thread indicator if in thread mode
                if viewModel.isThreadMode {
                    threadIndicatorView
                }
                
                // Parent post reply view if needed
                if viewModel.parentPost != nil {
                    ReplyingToView(parentPost: viewModel.parentPost!)
                        .padding(.horizontal)
                        .padding(.top)
                }
                
                // Post editor area
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        textEditorSection

                        // Quoted post preview if available
                        if viewModel.quotedPost != nil {
                            quotedPostPreview
                        }

                        mediaSection
                        urlCardsSection
                        languageSection
                    }
                    .padding()
                }
                
                // Thread navigation if in thread mode
                if viewModel.isThreadMode {
                    threadNavigationView
                }
                
                // Bottom toolbar
                bottomToolbar
            }
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
                            .font(.headline)
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
                    .font(.caption)
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
    
    // Thread indicator showing current post in thread
    private var threadIndicatorView: some View {
        HStack(spacing: 4) {
            Text("Thread")
                .font(.subheadline)
                .fontWeight(.medium)
            
            Text("\(viewModel.currentThreadEntryIndex + 1)/\(viewModel.threadEntries.count)")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.2))
                .foregroundColor(.accentColor)
                .cornerRadius(10)
            
            Spacer()
            
            Button(action: {
                showThreadOptions.toggle()
            }) {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.accentColor)
            }
            .actionSheet(isPresented: $showThreadOptions) {
                ActionSheet(
                    title: Text("Thread Options"),
                    buttons: [
                        .default(Text("Remove this post")) {
                            viewModel.removeThreadEntry(at: viewModel.currentThreadEntryIndex)
                        },
                        .destructive(Text("Exit thread mode")) {
                            viewModel.disableThreadMode()
                        },
                        .cancel()
                    ]
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 2)
    }
    
    // Thread navigation buttons for moving between thread posts
    private var threadNavigationView: some View {
        HStack {
            Button(action: {
                viewModel.previousThreadEntry()
            }) {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Previous")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(8)
            }
            .disabled(viewModel.currentThreadEntryIndex == 0)
            .opacity(viewModel.currentThreadEntryIndex == 0 ? 0.5 : 1)
            
            Spacer()
            
            Button(action: {
                viewModel.nextThreadEntry()
            }) {
                HStack {
                    Text(
                        viewModel.currentThreadEntryIndex < viewModel.threadEntries.count - 1
                        ? "Next" : "Add Post")
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.05), radius: 2, y: -2)
    }
    
    // MARK: - Existing UI Components
    
    private var textEditorSection: some View {
        ZStack(alignment: .topLeading) {
            // Background TextEditor for actual text input
            TextEditor(text: $viewModel.postText)
                .focused($isTextFieldFocused)
                .task { @MainActor in
                    isTextFieldFocused = true
                }
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(.systemBackground))
                .onChange(of: viewModel.postText) {
                    viewModel.updatePostContent()
                }
                // Note: onPasteCommand is macOS only, iOS uses the paste button in toolbar
                .opacity(viewModel.postText.isEmpty ? 1 : 0.1) // Make nearly transparent when there's text
            
            // Overlay with highlighted attributed text
            if !viewModel.postText.isEmpty {
                VStack(alignment: .leading) {
                    Text(viewModel.attributedPostText)
                        .frame(minHeight: 120, alignment: .topLeading)
                        .padding(8)
                        .multilineTextAlignment(.leading)
                        .allowsHitTesting(false) // Allow touches to pass through to TextEditor
                    
                    Spacer()
                }
            }
            
            // Placeholder text
            if viewModel.postText.isEmpty {
                Text("What's on your mind?")
                    .foregroundColor(.gray)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
            
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
            if viewModel.videoItem != nil {
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
                        .font(.title)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(viewModel.selectedLanguages, id: \.self) { lang in
                            HStack {
                                Text(
                                    Locale.current.localizedString(
                                        forLanguageCode: lang.lang.languageCode?.identifier ?? "")
                                    ?? lang.lang.minimalIdentifier
                                )
                                .font(.caption)
                                
                                Button(action: {
                                    viewModel.toggleLanguage(lang)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
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
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    // Modified bottom toolbar to include reply controls
    private var bottomToolbar: some View {
        HStack {
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
                        ? "x.circle.fill" : "plus.circle"
                    )
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                }
            }
            
            // Add reply controls button (threadgate)
            if viewModel.parentPost == nil {
                Button(action: {
                    viewModel.showThreadgateOptions = true
                }) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                }
            }
            
            // Language button
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
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
            }
            
            // Labels button
            Button(action: {
                viewModel.showLabelSelector = true
            }) {
                Image(systemName: "tag")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
            }
            
            // Paste button
            Button(action: {
                Task {
                    await viewModel.handlePasteFromClipboard()
                }
            }) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 20))
                    .foregroundStyle(viewModel.hasClipboardMedia() ? Color.accentColor : Color.primary)
            }
            .disabled(!viewModel.hasClipboardMedia())
            
            // Add video button
            Button(action: {
                videoPickerVisible = true
            }) {
                Image(systemName: "video")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
            }
            
            // Add photo button
            Button(action: {
                photoPickerVisible = true
            }) {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
            }
            
            Spacer()

            // Character count
            Text("\(viewModel.characterCount)/\(viewModel.maxCharacterCount)")
                .font(.footnote)
                .foregroundColor(viewModel.isOverCharacterLimit ? .red : .secondary)
        }
        .padding()
        .background(
            Color(.systemBackground)
                .shadow(color: .black.opacity(0.1), radius: 3, y: -2)
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
    .font(.subheadline)
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
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.2))
            .foregroundColor(.accentColor)
            .cornerRadius(4)
        }

        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
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
