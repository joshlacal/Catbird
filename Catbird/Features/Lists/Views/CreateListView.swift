import SwiftUI
import Petrel
import OSLog
import PhotosUI

@Observable
final class CreateListViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let logger = Logger(subsystem: "blue.catbird", category: "CreateListView")
  
  // Form fields
  var name: String = ""
  var description: String = ""
  var purpose: AppBskyGraphDefs.ListPurpose = .appbskygraphdefscuratelist
  var avatarImage: UIImage?
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
  
  func setAvatar(_ image: UIImage) {
    avatarImage = image
    
    // Convert to JPEG data for upload
    if let jpegData = image.jpegData(compressionQuality: 0.8) {
      avatarData = jpegData
      logger.debug("Avatar image set and converted to JPEG data")
    } else {
      logger.error("Failed to convert avatar image to JPEG data")
    }
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
      Form {
        // Basic Information Section
        Section {
          // List Name Field
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              TextField("List name", text: $viewModel.name)
                .focused($isNameFieldFocused)
                .onChange(of: viewModel.name) { _, newValue in
                  if newValue.count > maxNameLength {
                    viewModel.name = String(newValue.prefix(maxNameLength))
                  }
                }
              
              Spacer()
              
              Text("\(viewModel.name.count)/\(maxNameLength)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          
          // List Description Field
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
              TextField("Description (optional)", text: $viewModel.description, axis: .vertical)
                .lineLimit(3...6)
                .onChange(of: viewModel.description) { _, newValue in
                  if newValue.count > maxDescriptionLength {
                    viewModel.description = String(newValue.prefix(maxDescriptionLength))
                  }
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
        } header: {
          Text("Basic Information")
        }
        
        // List Type Section
        Section {
          Picker("List Type", selection: $viewModel.purpose) {
            Text("Curated List").tag(AppBskyGraphDefs.ListPurpose.appbskygraphdefscuratelist)
            Text("Moderation List").tag(AppBskyGraphDefs.ListPurpose.appbskygraphdefsmodlist)
            Text("Reference List").tag(AppBskyGraphDefs.ListPurpose.appbskygraphdefsreferencelist)
          }
          .pickerStyle(.menu)
          
          // Description based on selected type
          VStack(alignment: .leading, spacing: 4) {
            switch viewModel.purpose {
            case .appbskygraphdefscuratelist:
              Text("Curated List")
                .font(.caption)
                .fontWeight(.medium)
              Text("A list of accounts you find interesting or want to follow as a group")
                .font(.caption2)
                .foregroundStyle(.secondary)
            case .appbskygraphdefsmodlist:
              Text("Moderation List")
                .font(.caption)
                .fontWeight(.medium)
              Text("A list used for blocking or muting multiple accounts at once")
                .font(.caption2)
                .foregroundStyle(.secondary)
            case .appbskygraphdefsreferencelist:
              Text("Reference List")
                .font(.caption)
                .fontWeight(.medium)
              Text("A list used as a reference for other features")
                .font(.caption2)
                .foregroundStyle(.secondary)
            default:
              EmptyView()
            }
          }
        } header: {
          Text("List Type")
        }
        
        // Avatar Section
        Section {
          HStack {
            // Avatar Preview
            Group {
              if let avatarImage = viewModel.avatarImage {
                Image(uiImage: avatarImage)
                  .resizable()
                  .scaledToFill()
                  .frame(width: 60, height: 60)
                  .clipShape(RoundedRectangle(cornerRadius: 8))
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
            
            Spacer()
          }
        } header: {
          Text("Avatar")
        }
      }
      .navigationTitle("Create List")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
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
      .onAppear {
        // Update view model with current app state
        viewModel = CreateListViewModel(appState: appState)
        // Focus the name field when the view appears
        isNameFieldFocused = true
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
      .photosPicker(
        isPresented: $showingPhotoPicker,
        selection: $photoPickerItem,
        matching: .images
      )
      .onChange(of: photoPickerItem) { _, newItem in
        Task {
          if let newItem = newItem,
             let data = try? await newItem.loadTransferable(type: Data.self),
             let image = UIImage(data: data) {
            viewModel.setAvatar(image)
          }
          photoPickerItem = nil
        }
      }
      .overlay {
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
    }
  }
}
