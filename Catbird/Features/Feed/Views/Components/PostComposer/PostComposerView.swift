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
    "zh-CN", "zh-TW", "fr-FR", "fr-CA", "de-DE", "de-AT", "de-CH",
  ]

  return commonLanguageTags.compactMap { tag in
    let locale = Locale(identifier: tag)
    return LanguageCodeContainer(lang: locale.language)
  }.sorted { lhs, rhs in
    // Sort by language name in the user's current locale
    let lhsName =
      Locale.current.localizedString(forLanguageCode: lhs.lang.languageCode?.identifier ?? "")
      ?? lhs.lang.minimalIdentifier
    let rhsName =
      Locale.current.localizedString(forLanguageCode: rhs.lang.languageCode?.identifier ?? "")
      ?? rhs.lang.minimalIdentifier
    return lhsName < rhsName
  }
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

  // Separate pickers for photos and videos
  @State private var photoPickerVisible = false
  @State private var videoPickerVisible = false
  @State private var photoPickerItems: [PhotosPickerItem] = []
  @State private var videoPickerItems: [PhotosPickerItem] = []

  // Thread UI state
  @State private var showThreadOptions: Bool = false

  init(parentPost: AppBskyFeedDefs.PostView? = nil, appState: AppState) {
    self._viewModel = State(
      wrappedValue: PostComposerViewModel(parentPost: parentPost, appState: appState))
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
      .navigationTitle(getNavigationTitle())
      .navigationBarTitleDisplayMode(.inline)
      .task {
        await viewModel.loadUserLanguagePreference()
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
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
            let image = videoItem.image
          {
            AltTextEditorView(
              altText: videoItem.altText,
              image: image,
              imageId: videoItem.id,
              onSave: viewModel.updateAltText
            )
          } else if let index = viewModel.mediaItems.firstIndex(where: { $0.id == editingId }),
            let image = viewModel.mediaItems[index].image
          {
            AltTextEditorView(
              altText: viewModel.mediaItems[index].altText,
              image: image,
              imageId: editingId,
              onSave: viewModel.updateAltText
            )
          }
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
    }
  }

  // MARK: - New Thread UI Components

  // Get appropriate navigation title based on compose mode
  private func getNavigationTitle() -> String {
    if viewModel.isThreadMode {
      return "New Thread"
    } else if viewModel.parentPost == nil {
      return "New Post"
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
            .cancel(),
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
          onAddMore: { photoPickerVisible = true }
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
        !viewModel.selectedLanguages.contains(suggestedLang)
      {
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

  // Modified bottom toolbar to include thread toggle
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
              ? "arrow.triangle.branch.filled" : "arrow.triangle.branch"
          )
          .font(.system(size: 20))
          .foregroundStyle(.primary)
        }
      }

      // Language button
      Menu {
        ForEach(getAvailableLanguages(), id: \.self) { lang in
          Button(action: {
            viewModel.toggleLanguage(lang)
          }) {
            Label(
              Locale.current.localizedString(
                forLanguageCode: lang.lang.languageCode?.identifier ?? "")
                ?? lang.lang.minimalIdentifier,
              systemImage: viewModel.selectedLanguages.contains(lang) ? "checkmark" : ""
            )
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

      // Post button with dynamic text
      Button(action: createPost) {
        Text(getPostButtonText())
          .font(.headline)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(
            viewModel.isPostButtonDisabled ? Color.accentColor.opacity(0.5) : Color.accentColor
          )
          .foregroundColor(.white)
          .clipShape(Capsule())
      }
      .disabled(viewModel.isPostButtonDisabled)
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
      return "Post Thread"
    } else if viewModel.parentPost != nil {
      return "Reply"
    } else {
      return "Post"
    }
  }

  // MARK: - Post Creation

  // Create post or thread based on current mode
  private func createPost() {
    Task {
      do {
        if viewModel.isThreadMode {
          try await viewModel.createThread()
        } else {
          try await viewModel.createPost()
        }
        dismiss()
      } catch {
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
    }
    .font(.subheadline)
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(Color(.systemGray5))
    .cornerRadius(8)
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
    ComAtprotoLabelDefs.LabelValue(rawValue: "graphic-media"),  // This one isn't in predefined values
  ]

  var body: some View {
    NavigationStack {
      List(allowedSelfLabels, id: \.self) { label in
        Button(action: { toggleLabel(label) }) {
          HStack {
            Text(label.rawValue)
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

struct AlertItem: Identifiable {
  let id = UUID()
  let title: String
  let message: String
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
