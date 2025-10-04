import SwiftUI
import Petrel
import OSLog
import PhotosUI
import NukeUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Observable
final class EditListViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let listURI: String
  private let logger = Logger(subsystem: "blue.catbird", category: "EditListView")
  
  // Core data
  var listDetails: AppBskyGraphDefs.ListView?
  
  // Form data
  var name: String = ""
  var description: String = ""
  var selectedImage: PhotosPickerItem?
  var avatarData: Data?
  var listType: AppBskyGraphDefs.ListPurpose = .appbskygraphdefscuratelist
  
  // State
  var isLoading = false
  var isSaving = false
  var errorMessage: String?
  var showingError = false
  var hasUnsavedChanges = false
  
  // Validation
  var isFormValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  // MARK: - Computed Properties
  
  var characterCount: Int {
    name.count
  }
  
  var descriptionCharacterCount: Int {
    description.count
  }
  
  var isNameValid: Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.count <= 64
  }
  
  var isDescriptionValid: Bool {
    description.count <= 300
  }
  
  // MARK: - Initialization
  
  init(listURI: String, appState: AppState) {
    self.listURI = listURI
    self.appState = appState
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadListData() async {
    guard !isLoading else { return }
    
    isLoading = true
    errorMessage = nil
    
    do {
      listDetails = try await appState.listManager.getListDetails(listURI)
      
      // Populate form fields
      if let list = listDetails {
        name = list.name
        description = list.description ?? ""
        listType = list.purpose
      }
      
      logger.info("Loaded list data for editing: \(self.name)")
      
    } catch {
      logger.error("Failed to load list data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isLoading = false
  }
  
  // MARK: - Image Handling
  
  @MainActor
  func processSelectedImage() async {
    guard let selectedImage = selectedImage else { return }
    
    do {
      if let data = try await selectedImage.loadTransferable(type: Data.self) {
        // Resize image if needed
        if let resizedData = await ImageProcessor.resizeImageData(data, maxSize: 1000) {
          avatarData = resizedData
          hasUnsavedChanges = true
          logger.debug("Image processed and resized")
        } else {
          avatarData = data
          hasUnsavedChanges = true
          logger.debug("Image processed without resizing")
        }
      }
    } catch {
      logger.error("Failed to process selected image: \(error.localizedDescription)")
      errorMessage = "Failed to process selected image"
      showingError = true
    }
  }
  
  // MARK: - List Management
  
  @MainActor
  func saveChanges() async {
    guard isFormValid && !isSaving else { return }
    
    isSaving = true
    errorMessage = nil
    
    do {
      _ = try await appState.listManager.updateList(
        listURI: listURI,
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        description: description.isEmpty ? nil : description,
        avatar: avatarData
      )
      
      hasUnsavedChanges = false
      logger.info("Successfully updated list: \(self.name)")
      
    } catch {
      logger.error("Failed to update list: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isSaving = false
  }
  
  // MARK: - Change Tracking
  
  func markAsChanged() {
    hasUnsavedChanges = true
  }
}

struct EditListView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: EditListViewModel
  @State private var showingDiscardAlert = false
  
  let listURI: String
  
  init(listURI: String) {
    self.listURI = listURI
    self._viewModel = State(wrappedValue: EditListViewModel(listURI: listURI, appState: AppState.shared))
  }
  
  var body: some View {
    NavigationStack {
      Group {
        if viewModel.isLoading {
          loadingView
        } else {
          formView
        }
      }
      .navigationTitle("Edit List")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            if viewModel.hasUnsavedChanges {
              showingDiscardAlert = true
            } else {
              dismiss()
            }
          }
        }
        
        ToolbarItem(placement: .primaryAction) {
          Button("Save") {
            Task {
              await viewModel.saveChanges()
              if viewModel.errorMessage == nil {
                dismiss()
              }
            }
          }
          .disabled(!viewModel.isFormValid || viewModel.isSaving)
        }
      }
      .onAppear {
        viewModel = EditListViewModel(listURI: listURI, appState: appState)
        Task {
          await viewModel.loadListData()
        }
      }
      .alert("Discard Changes?", isPresented: $showingDiscardAlert) {
        Button("Discard", role: .destructive) {
          dismiss()
        }
        Button("Keep Editing", role: .cancel) {}
      } message: {
        Text("You have unsaved changes. Are you sure you want to discard them?")
      }
      .alert("Error", isPresented: $viewModel.showingError) {
        Button("OK") {
          viewModel.showingError = false
        }
      } message: {
        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
        }
      }
    }
  }
  
  // MARK: - View Components
  
  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.5)
      Text("Loading list details...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var formView: some View {
    Form {
      // Avatar Section
      Section {
        avatarSection
      } header: {
        Text("List Avatar")
      }
      
      // Basic Info Section
      Section {
        basicInfoSection
      } header: {
        Text("List Information")
      }
      
      // List Type Section
      Section {
        listTypeSection
      } header: {
        Text("List Type")
      } footer: {
        Text("The list type determines how the list can be used and discovered by others.")
      }
    }
    .onChange(of: viewModel.selectedImage) { _, _ in
      Task {
        await viewModel.processSelectedImage()
      }
    }
    .onChange(of: viewModel.name) { _, _ in
      viewModel.markAsChanged()
    }
    .onChange(of: viewModel.description) { _, _ in
      viewModel.markAsChanged()
    }
    .onChange(of: viewModel.listType) { _, _ in
      viewModel.markAsChanged()
    }
  }
  
  private var avatarSection: some View {
    HStack(spacing: 16) {
      // Current Avatar Display
      Group {
        if let avatarData = viewModel.avatarData {
          #if os(iOS)
          if let uiImage = UIImage(data: avatarData) {
            Image(uiImage: uiImage)
              .resizable()
              .scaledToFill()
          }
          #elseif os(macOS)
          if let nsImage = NSImage(data: avatarData) {
            Image(nsImage: nsImage)
              .resizable()
              .scaledToFill()
          }
          #endif
        } else if let avatarURLString = viewModel.listDetails?.avatar?.uriString(),
                   let avatarURL = URL(string: avatarURLString) {
          LazyImage(url: avatarURL) { state in
            if let image = state.image {
              image
                .resizable()
                .scaledToFill()
            } else {
              defaultAvatarPlaceholder
            }
          }
        } else {
          defaultAvatarPlaceholder
        }
      }
      .frame(width: 80, height: 80)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      
      VStack(alignment: .leading, spacing: 8) {
        Text("List Avatar")
          .font(.headline)
        
        Text("Choose an image to represent your list")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        PhotosPicker(
          selection: $viewModel.selectedImage,
          matching: .images
        ) {
          Text("Choose Photo")
            .font(.subheadline)
            .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
      }
      
      Spacer()
    }
    .padding(.vertical, 8)
  }
  
  private var defaultAvatarPlaceholder: some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(.secondary.opacity(0.3))
      .overlay {
        Image(systemName: "list.bullet.rectangle")
          .font(.title)
          .foregroundStyle(.secondary)
      }
  }
  
  private var basicInfoSection: some View {
    VStack(spacing: 16) {
      // Name Field
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Name")
          Spacer()
          Text("\(viewModel.characterCount)/64")
            .font(.caption)
            .foregroundStyle(viewModel.isNameValid ? Color.secondary : Color.red)
        }
        
        TextField("My awesome list", text: $viewModel.name)
          .textFieldStyle(.roundedBorder)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(viewModel.isNameValid ? Color.clear : Color.red, lineWidth: 1)
          )
      }
      
      // Description Field
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Description")
          Spacer()
          Text("\(viewModel.descriptionCharacterCount)/300")
            .font(.caption)
            .foregroundStyle(viewModel.isDescriptionValid ? Color.secondary : Color.red)
        }
        
        TextField(
          "A curated collection of accounts...",
          text: $viewModel.description,
          axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(3...6)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(viewModel.isDescriptionValid ? Color.clear : Color.red, lineWidth: 1)
        )
      }
    }
  }
  
  private var listTypeSection: some View {
    VStack(spacing: 12) {
      ForEach([
        AppBskyGraphDefs.ListPurpose.appbskygraphdefscuratelist,
        AppBskyGraphDefs.ListPurpose.appbskygraphdefsmodlist,
        AppBskyGraphDefs.ListPurpose.appbskygraphdefsreferencelist
      ], id: \.self) { purpose in
        ListTypeSelectionRow(
          purpose: purpose,
          isSelected: viewModel.listType == purpose
        ) {
          viewModel.listType = purpose
          viewModel.markAsChanged()
        }
      }
    }
  }
}

// MARK: - Supporting Views

struct ListTypeSelectionRow: View {
  let purpose: AppBskyGraphDefs.ListPurpose
  let isSelected: Bool
  let onTap: () -> Void
  
  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 12) {
        Image(systemName: iconForPurpose(purpose))
          .font(.title2)
          .foregroundStyle(isSelected ? .blue : .secondary)
          .frame(width: 24)
        
        VStack(alignment: .leading, spacing: 2) {
          Text(titleForPurpose(purpose))
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
          
          Text(descriptionForPurpose(purpose))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        
        Spacer()
        
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.blue)
        }
      }
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
  }
  
  private func iconForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> String {
    switch purpose {
    case .appbskygraphdefscuratelist:
      return "star.circle"
    case .appbskygraphdefsmodlist:
      return "shield.lefthalf.filled"
    case .appbskygraphdefsreferencelist:
      return "bookmark.circle"
    default:
      return "questionmark.circle"
    }
  }
  
  private func titleForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> String {
    switch purpose {
    case .appbskygraphdefscuratelist:
      return "Curated List"
    case .appbskygraphdefsmodlist:
      return "Moderation List"
    case .appbskygraphdefsreferencelist:
      return "Reference List"
    default:
      return "Unknown"
    }
  }
  
  private func descriptionForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> String {
    switch purpose {
    case .appbskygraphdefscuratelist:
      return "A collection of accounts you recommend to others"
    case .appbskygraphdefsmodlist:
      return "A list used for moderation and filtering content"
    case .appbskygraphdefsreferencelist:
      return "A personal reference collection for your own use"
    default:
      return "Unknown list type"
    }
  }
}

// MARK: - Image Processing Helper

actor ImageProcessor {
  static func resizeImageData(_ data: Data, maxSize: CGFloat) async -> Data? {
    guard let image = PlatformImage(data: data) else { return nil }
    
    let size = image.size
    let aspectRatio = size.width / size.height
    
    // Calculate new size
    let newSize: CGSize
    if size.width > size.height {
      newSize = CGSize(width: maxSize, height: maxSize / aspectRatio)
    } else {
      newSize = CGSize(width: maxSize * aspectRatio, height: maxSize)
    }
    
    // Only resize if image is larger than target
    guard size.width > maxSize || size.height > maxSize else { return data }
    
    // Resize image
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    let resizedImage = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }
    return resizedImage.jpegData(compressionQuality: 0.8)
    #elseif os(macOS)
    let resizedImage = NSImage(size: newSize, flipped: false) { rect in
      image.draw(in: rect)
      return true
    }
    
    guard let tiffData = resizedImage.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData) else {
      return nil
    }
    return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    #endif
  }
}
