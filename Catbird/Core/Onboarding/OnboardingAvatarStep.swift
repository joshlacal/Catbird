import Foundation
import OSLog
import Petrel
import PhotosUI
import SwiftUI

/// Onboarding step for setting up user profile avatar via photo picker or symbol/color generator
public struct OnboardingAvatarStep: View {
    @Environment(AppState.self) private var appState
    let onContinue: () -> Void
    let onSkip: () -> Void
    
    // State
    @State private var avatarMode: AvatarCreationMode = .sticker
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhoto: UIImage?
    @State private var selectedSymbol: String = "bird.fill"
    @State private var selectedColorHex: String = "#0A84FF"
    
    @State private var isUploading: Bool = false
    @State private var uploadErrorMessage: String?
    @State private var hasSavedAvatar: Bool = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "OnboardingAvatarStep")
    
    enum AvatarCreationMode: String, CaseIterable, Identifiable {
        case sticker = "Design Avatar"
        case photo = "Upload Photo"
        
        var id: String { rawValue }
    }
    
    private let availableSymbols = [
        "bird.fill", "cat.fill", "dog.fill", "sparkles",
        "star.fill", "heart.fill", "flame.fill", "bolt.fill",
        "moon.stars.fill", "sun.max.fill", "leaf.fill", "paintbrush.fill",
        "music.note", "camera.fill", "crown.fill", "globe.americas.fill"
    ]
    
    private let availableColors: [(name: String, hex: String, color: Color)] = [
        ("Blue", "#0A84FF", .blue),
        ("Purple", "#AF52DE", .purple),
        ("Indigo", "#5856D6", .indigo),
        ("Pink", "#FF2D55", .pink),
        ("Orange", "#FF9500", .orange),
        ("Teal", "#30B0C7", .teal),
        ("Mint", "#00C7BE", .mint),
        ("Green", "#34C759", .green)
    ]
    
    public init(onContinue: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onContinue = onContinue
        self.onSkip = onSkip
    }
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("Add a Profile Picture")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Choose a photo or build an avatar to help friends recognize you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 8)
                
                // Avatar Preview
                avatarPreview
                    .frame(width: 140, height: 140)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
                    .padding(.vertical, 8)
                
                // Mode Picker
                Picker("Avatar Mode", selection: $avatarMode) {
                    ForEach(AvatarCreationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                
                // Mode-specific Controls
                if avatarMode == .sticker {
                    stickerControls
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                } else {
                    photoControls
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                
                // Error display
                if let error = uploadErrorMessage {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        
                        Button("Retry Upload") {
                            saveAndContinue()
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.accent)
                    }
                    .padding(.horizontal)
                }
                
                // Actions
                VStack(spacing: 12) {
                    Button(action: saveAndContinue) {
                        HStack {
                            if isUploading {
                                ProgressView()
                                    .tint(.white)
                                    .padding(.trailing, 4)
                            }
                            Text(isUploading ? "Saving Profile..." : "Save & Continue")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isUploading)
                    
                    Button("Skip for now") {
                        onSkip()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(isUploading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: avatarMode)
    }
    
    // MARK: - Avatar Preview
    
    @ViewBuilder
    private var avatarPreview: some View {
        if avatarMode == .photo, let selectedPhoto {
            Image(uiImage: selectedPhoto)
                .resizable()
                .scaledToFill()
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2))
        } else {
            let activeColor = availableColors.first(where: { $0.hex == selectedColorHex })?.color ?? .blue
            Circle()
                .fill(activeColor)
                .overlay(
                    Image(systemName: selectedSymbol)
                        .font(.system(size: 60, weight: .semibold))
                        .foregroundColor(.white)
                )
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 3))
        }
    }
    
    // MARK: - Sticker Controls
    
    private var stickerControls: some View {
        VStack(spacing: 20) {
            // Symbol Grid
            VStack(alignment: .leading, spacing: 10) {
                Text("Select an Icon")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(availableSymbols, id: \.self) { symbol in
                        Button {
                            selectedSymbol = symbol
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedSymbol == symbol ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedSymbol == symbol ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                
                                Image(systemName: symbol)
                                    .font(.system(size: 24))
                                    .foregroundColor(selectedSymbol == symbol ? .accentColor : .primary)
                            }
                            .frame(height: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Icon \(symbol)")
                    }
                }
                .padding(.horizontal, 24)
            }
            
            // Color Palette
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Background Color")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(availableColors, id: \.hex) { item in
                        Button {
                            selectedColorHex = item.hex
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 44, height: 44)
                                
                                if selectedColorHex == item.hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.name) color")
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
    
    // MARK: - Photo Controls
    
    private var photoControls: some View {
        VStack(spacing: 16) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                    Text(selectedPhoto == nil ? "Choose Photo from Library" : "Choose Another Photo")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.secondary.opacity(0.15))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            selectedPhoto = uiImage
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Save Action
    
    private func saveAndContinue() {
        guard let client = appState.atProtoClient else {
            logger.warning("No ATProtoClient available; advancing onboarding")
            onContinue()
            return
        }
        
        isUploading = true
        uploadErrorMessage = nil
        
        Task {
            do {
                let renderedImageData: Data?
                
                if avatarMode == .photo, let selectedPhoto {
                    renderedImageData = selectedPhoto.jpegData(compressionQuality: 0.85)
                } else {
                    renderedImageData = renderStickerImage()
                }
                
                guard let imageData = renderedImageData else {
                    throw NSError(
                        domain: "OnboardingAvatar",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to render avatar image"]
                    )
                }
                
                let profileVM = ProfileViewModel(client: client, userDID: appState.userDID, currentUserDID: appState.userDID)
                
                let blob = try await profileVM.uploadImageBlob(imageData)
                try await profileVM.updateProfile(avatar: blob)
                
                await MainActor.run {
                    isUploading = false
                    hasSavedAvatar = true
                    logger.info("Successfully updated avatar in onboarding")
                    onContinue()
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    uploadErrorMessage = "Failed to upload avatar: \(error.localizedDescription)"
                    logger.error("Avatar upload failed: \(error)")
                }
            }
        }
    }
    
    @MainActor
    private func renderStickerImage() -> Data? {
        let size = CGSize(width: 512, height: 512)
        let activeColor = availableColors.first(where: { $0.hex == selectedColorHex })?.color ?? .blue
        
        let stickerView = Circle()
            .fill(activeColor)
            .frame(width: 512, height: 512)
            .overlay(
                Image(systemName: selectedSymbol)
                    .font(.system(size: 240, weight: .semibold))
                    .foregroundColor(.white)
            )
        
        let renderer = ImageRenderer(content: stickerView)
        renderer.scale = 1.0
        if let uiImage = renderer.uiImage {
            return uiImage.pngData()
        }
        
        // Fallback to UIGraphicsImageRenderer
        let uiRenderer = UIGraphicsImageRenderer(size: size)
        let image = uiRenderer.image { ctx in
            let uiColor = UIColor(activeColor)
            uiColor.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            
            let config = UIImage.SymbolConfiguration(pointSize: 220, weight: .semibold)
            if let symbolImage = UIImage(systemName: selectedSymbol, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let origin = CGPoint(
                    x: (size.width - symbolImage.size.width) / 2,
                    y: (size.height - symbolImage.size.height) / 2
                )
                symbolImage.draw(at: origin)
            }
        }
        return image.pngData()
    }
}
