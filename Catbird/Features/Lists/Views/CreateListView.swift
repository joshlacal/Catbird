import SwiftUI
import Petrel
import OSLog
import PhotosUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Observable
final class CreateListViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let logger = Logger(subsystem: "blue.catbird", category: "CreateListView")
  
  // Form fields
  var name: String = ""
  var description: String = ""
  var purpose: AppBskyGraphDefs.ListPurpose = .appbskygraphdefscuratelist
  var avatarImage: PlatformImage?
  var avatarData: Data?
  
  // State
  var isCreating = false
  var errorMessage: String?
  var showingError = false
  
  // Validation
  var isValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  // MARK: - Initialization
  
  init(appState: AppState) {
    self.appState = appState
  }
  
  // MARK: - Avatar Management
  
  func setAvatar(_ image: PlatformImage) {
    avatarImage = image
    
    // Convert to JPEG data for upload using cross-platform method
    #if os(iOS)
    if let jpegData = image.jpegData(compressionQuality: 0.8) {
      avatarData = jpegData
      logger.debug("Avatar image set and converted to JPEG data")
    } else {
      logger.error("Failed to convert avatar image to JPEG data")
    }
    #elseif os(macOS)
    if let jpegData = image.jpegImageData(compressionQuality: 0.8) {
      avatarData = jpegData
      logger.debug("Avatar image set and converted to JPEG data")
    } else {
      logger.error("Failed to convert avatar image to JPEG data")
    }
    #endif
  }
  
  func clearAvatar() {
    avatarImage = nil
    avatarData = nil
    logger.debug("Avatar cleared")
  }
  
  // MARK: - List Creation
  
  @MainActor
  func createList() async {
    guard isValid else {
      errorMessage = "Please enter a name for your list"
      showingError = true
      return
    }
    
    isCreating = true
    errorMessage = nil
    
    do {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
      
      logger.info("Creating list: \(trimmedName)")
      
      let _ = try await appState.listManager.createList(
        name: trimmedName,
        description: trimmedDescription.isEmpty ? nil : trimmedDescription,
        purpose: purpose,
        avatar: avatarData
      )
      
      logger.info("Successfully created list: \(trimmedName)")
      
      // Reset form
      resetForm()
      
    } catch {
      logger.error("Failed to create list: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isCreating = false
  }
  
  private func resetForm() {
    name = ""
    description = ""
    purpose = .appbskygraphdefscuratelist
    clearAvatar()
  }
}

struct CreateListView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: CreateListViewModel
  @State private var showingPhotoPicker = false
  @State private var photoPickerItem: PhotosPickerItem?
  @FocusState private var isNameFieldFocused: Bool
  
  // Character limits
  private let maxNameLength = 64
  private let maxDescriptionLength = 300
  
  init() {
    // We'll initialize viewModel in onAppear since we need AppState
    self._viewModel = State(wrappedValue: CreateListViewModel(appState: AppState.shared))
  }
  
  var body: some View {
    NavigationStack {
      formContent
        .navigationTitle("Create List")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          toolbarContent
        }
        .onAppear {
          setupView()
        }
        .alert("Error", isPresented: $viewModel.showingError) {
          errorAlertButton
        } message: {
          errorMessage
        }
        .photosPicker(
          isPresented: $showingPhotoPicker,
          selection: $photoPickerItem,
          matching: .images
        )
        .onChange(of: photoPickerItem) { _, newItem in
          handlePhotoSelection(newItem)
        }
        .overlay {
          loadingOverlay
        }
    }
  }
  
  // MARK: - View Components
  
  @ViewBuilder
  private var formContent: some View {
    Form {
      basicInformationSection
      listTypeSection  
      avatarSection
    }
  }
  
  @ViewBuilder
  private var basicInformationSection: some View {
    Section {
      nameFieldSection
      descriptionFieldSection
    } header: {
      Text("Basic Information")
    }
  }
  
  @ViewBuilder
  private var listTypeSection: some View {
    Section {
      Picker("List Type", selection: $viewModel.purpose) {
        Text("Curated List").tag(AppBskyGraphDefs.ListPurpose.appbskygraphdefscuratelist)
        Text("Moderation List").tag(AppBskyGraphDefs.ListPurpose.appbskygraphdefsmodlist)
        Text("Reference List").tag(AppBskyGraphDefs.ListPurpose.appbskygraphdefsreferencelist)
      }
      .pickerStyle(.menu)
      
      listTypeDescriptionSection
    } header: {
      Text("List Type")
    }
  }
  
  @ViewBuilder
  private var avatarSection: some View {
    Section {
      HStack {
        avatarPreview
        avatarControls
        Spacer()
      }
    } header: {
      Text("Avatar")
    }
  }
  
  @ViewBuilder
  private var avatarPreview: some View {
    Group {
      if let avatarImage = viewModel.avatarImage {
        #if os(iOS)
        Image(uiImage: avatarImage)
          .resizable()
          .scaledToFill()
          .frame(width: 60, height: 60)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        #elseif os(macOS)
        Image(nsImage: avatarImage)
          .resizable()
          .scaledToFill()
          .frame(width: 60, height: 60)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        #endif
      } else {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.gray.opacity(0.3))
          .frame(width: 60, height: 60)
          .overlay {
            Image(systemName: "photo")
              .foregroundStyle(.secondary)
          }
      }
    }
  }
  
  @ViewBuilder
  private var avatarControls: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("List Avatar")
        .font(.headline)
      Text("Choose an image to represent your list")
        .font(.caption)
        .foregroundStyle(.secondary)
      
      HStack {
        Button("Choose Photo") {
          showingPhotoPicker = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        
        if viewModel.avatarImage != nil {
          Button("Remove") {
            viewModel.clearAvatar()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .foregroundStyle(.red)
        }
      }
    }
  }
  
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button("Cancel") {
        dismiss()
      }
    }
    
    ToolbarItem(placement: .primaryAction) {
      Button("Create") {
        Task {
          await viewModel.createList()
          if !viewModel.showingError {
            dismiss()
          }
        }
      }
      .disabled(!viewModel.isValid || viewModel.isCreating)
      .fontWeight(.semibold)
    }
  }
  
  @ViewBuilder
  private var loadingOverlay: some View {
    if viewModel.isCreating {
      Color.black.opacity(0.3)
        .ignoresSafeArea()
        .overlay {
          VStack(spacing: 16) {
            ProgressView()
              .scaleEffect(1.5)
            Text("Creating list...")
              .font(.headline)
              .foregroundStyle(.white)
          }
          .padding(24)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
  }
  
  @ViewBuilder
  private var errorAlertButton: some View {
    Button("OK") {
      viewModel.showingError = false
    }
  }
  
  @ViewBuilder
  private var errorMessage: some View {
    if let errorMessage = viewModel.errorMessage {
      Text(errorMessage)
    }
  }
  
  // MARK: - Helper Methods
  
  private func setupView() {
    viewModel = CreateListViewModel(appState: appState)
    isNameFieldFocused = true
  }
  
  private func handlePhotoSelection(_ newItem: PhotosPickerItem?) {
    Task {
      if let newItem = newItem,
         let data = try? await newItem.loadTransferable(type: Data.self),
         let image = PlatformImage(data: data) {
        viewModel.setAvatar(image)
      }
      photoPickerItem = nil
    }
  }

  // MARK: - Form Field Components
  
  @ViewBuilder
  private var nameFieldSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("List name", text: $viewModel.name)
          .focused($isNameFieldFocused)
          .onChange(of: viewModel.name) { _, newValue in
            let trimmedValue = newValue.count > maxNameLength ? String(newValue.prefix(maxNameLength)) : newValue
            viewModel.name = trimmedValue
          }
        
        Spacer()
        
        Text("\(viewModel.name.count)/\(maxNameLength)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
  
  @ViewBuilder
  private var descriptionFieldSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        TextField("Description (optional)", text: $viewModel.description, axis: .vertical)
          .lineLimit(3...6)
          .onChange(of: viewModel.description) { _, newValue in
            let trimmedValue = newValue.count > maxDescriptionLength ? String(newValue.prefix(maxDescriptionLength)) : newValue
            viewModel.description = trimmedValue
          }
        
        Spacer()
        
        VStack {
          Text("\(viewModel.description.count)/\(maxDescriptionLength)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
    }
  }
  
  @ViewBuilder
  private var listTypeDescriptionSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch viewModel.purpose {
      case .appbskygraphdefscuratelist:
        listTypeDescription(title: "Curated List", subtitle: "A list of accounts you find interesting or want to follow as a group")
      case .appbskygraphdefsmodlist:
        listTypeDescription(title: "Moderation List", subtitle: "A list used for blocking or muting multiple accounts at once")
      case .appbskygraphdefsreferencelist:
        listTypeDescription(title: "Reference List", subtitle: "A list used as a reference for other features")
      default:
        EmptyView()
      }
    }
  }
  
  @ViewBuilder
  private func listTypeDescription(title: String, subtitle: String) -> some View {
    Text(title)
      .font(.caption)
      .fontWeight(.medium)
    Text(subtitle)
      .font(.caption2)
      .foregroundStyle(.secondary)
  }
}
