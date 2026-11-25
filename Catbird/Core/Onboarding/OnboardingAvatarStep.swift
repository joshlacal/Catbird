import Foundation
import ImageIO
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
    /// Becomes true once the person picks an icon or color, so an existing avatar is never replaced by default.
    @State private var hasCustomizedSticker: Bool = false
    
    @State private var isUploading: Bool = false
    @State private var uploadErrorMessage: String?
    @State private var hasSavedAvatar: Bool = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "OnboardingAvatarStep")
    
    enum AvatarCreationMode: String, CaseIterable, Identifiable {
        case sticker = "Design Avatar"
        case photo = "Upload Photo"
        
        var id: String { rawValue }
        
        var localizedTitle: LocalizedStringResource {
            switch self {
            case .sticker:
                LocalizedStringResource("Design Avatar", comment: "Onboarding mode option to create an icon-based avatar.")
            case .photo:
                LocalizedStringResource("Upload Photo", comment: "Onboarding mode option to upload a profile photo.")
            }
        }
    }
    
    private let availableSymbols = [
        "bird.fill", "cat.fill", "dog.fill", "sparkles",
        "star.fill", "heart.fill", "flame.fill", "bolt.fill",
        "moon.stars.fill", "sun.max.fill", "leaf.fill", "paintbrush.fill",
        "music.note", "camera.fill", "crown.fill", "globe.americas.fill"
    ]
    
    private let symbolNames: [String: LocalizedStringResource] = [
        "bird.fill": LocalizedStringResource("Bird", comment: "Avatar icon name."),
        "cat.fill": LocalizedStringResource("Cat", comment: "Avatar icon name."),
        "dog.fill": LocalizedStringResource("Dog", comment: "Avatar icon name."),
        "sparkles": LocalizedStringResource("Sparkles", comment: "Avatar icon name."),
        "star.fill": LocalizedStringResource("Star", comment: "Avatar icon name."),
        "heart.fill": LocalizedStringResource("Heart", comment: "Avatar icon name."),
        "flame.fill": LocalizedStringResource("Flame", comment: "Avatar icon name."),
        "bolt.fill": LocalizedStringResource("Lightning Bolt", comment: "Avatar icon name."),
        "moon.stars.fill": LocalizedStringResource("Moon and Stars", comment: "Avatar icon name."),
        "sun.max.fill": LocalizedStringResource("Sun", comment: "Avatar icon name."),
        "leaf.fill": LocalizedStringResource("Leaf", comment: "Avatar icon name."),
        "paintbrush.fill": LocalizedStringResource("Paintbrush", comment: "Avatar icon name."),
        "music.note": LocalizedStringResource("Music Note", comment: "Avatar icon name."),
        "camera.fill": LocalizedStringResource("Camera", comment: "Avatar icon name."),
        "crown.fill": LocalizedStringResource("Crown", comment: "Avatar icon name."),
        "globe.americas.fill": LocalizedStringResource("Globe", comment: "Avatar icon name.")
    ]
    
    private let availableColors: [(name: LocalizedStringResource, hex: String, color: Color)] = [
        (LocalizedStringResource("Blue", comment: "Avatar background color name."), "#0A84FF", .blue),
        (LocalizedStringResource("Purple", comment: "Avatar background color name."), "#AF52DE", .purple),
        (LocalizedStringResource("Indigo", comment: "Avatar background color name."), "#5856D6", .indigo),
        (LocalizedStringResource("Pink", comment: "Avatar background color name."), "#FF2D55", .pink),
        (LocalizedStringResource("Orange", comment: "Avatar background color name."), "#FF9500", .orange),
        (LocalizedStringResource("Teal", comment: "Avatar background color name."), "#30B0C7", .teal),
        (LocalizedStringResource("Mint", comment: "Avatar background color name."), "#00C7BE", .mint),
        (LocalizedStringResource("Green", comment: "Avatar background color name."), "#34C759", .green)
    ]
    
    public init(onContinue: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onContinue = onContinue
        self.onSkip = onSkip
    }
    
    /// The account's current avatar, if it already has one.
    private var existingAvatarURL: URL? {
        appState.currentUserProfile?.finalAvatarURL()
    }
    
    /// Uploads only a chosen photo, a customized avatar, or the designed avatar for an account without one.
    private var willUpload: Bool {
        if avatarMode == .photo { return selectedPhoto != nil }
        return existingAvatarURL == nil || hasCustomizedSticker
    }
    
    private var primaryButtonTitle: LocalizedStringResource {
        if isUploading {
            return LocalizedStringResource("Saving…", comment: "Progress button label while uploading onboarding avatar.")
        }
        return willUpload
            ? LocalizedStringResource("Save & Continue", comment: "Button to upload selected onboarding avatar and advance.")
            : LocalizedStringResource("Continue", comment: "Button to advance onboarding without uploading a new avatar.")
    }
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("Add a Profile Picture")
                        .appFont(AppTextRole.title2)
                        .fontWeight(.bold)
                    
                    Text("Choose a photo or build an avatar to help friends recognize you.")
                        .appFont(AppTextRole.subheadline)
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
                Picker(selection: $avatarMode) {
                    ForEach(AvatarCreationMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                } label: {
                    Text("Avatar Mode", comment: "Segmented control label for choosing between designing an avatar or uploading a photo.")
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
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.red)
                        }
                        
                        Button("Try Again") {
                            saveAndContinue()
                        }
                        .appFont(AppTextRole.caption)
                        .fontWeight(.bold)
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
                            Text(primaryButtonTitle)
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
                    .disabled(isUploading || (avatarMode == .photo && selectedPhoto == nil))
                    
                    Button("Skip for Now") {
                        onSkip()
                    }
                    .appFont(AppTextRole.subheadline)
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
            Image(platformImage: selectedPhoto)
                .resizable()
                .scaledToFill()
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2) }
        } else if avatarMode == .sticker, !hasCustomizedSticker, let existingAvatarURL {
            ProfileAvatarView(url: existingAvatarURL, fallbackText: "", size: 140)
                .overlay { Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2) }
                .accessibilityLabel("Your current profile picture")
        } else {
            let activeColor = availableColors.first(where: { $0.hex == selectedColorHex })?.color ?? .blue
            Circle()
                .fill(activeColor)
                .overlay(
                    Image(systemName: selectedSymbol)
                        .font(.system(size: 60, weight: .semibold))
                        .foregroundColor(.white)
                )
                .overlay { Circle().stroke(Color.white.opacity(0.3), lineWidth: 3) }
        }
    }
    
    // MARK: - Sticker Controls
    
    private var stickerControls: some View {
        VStack(spacing: 20) {
            // Symbol Grid
            VStack(alignment: .leading, spacing: 10) {
                Text("Select an Icon")
                    .appFont(AppTextRole.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(availableSymbols, id: \.self) { symbol in
                        Button {
                            selectedSymbol = symbol
                            hasCustomizedSticker = true
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedSymbol == symbol ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(selectedSymbol == symbol ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                
                                Image(systemName: symbol)
                                    .font(.system(size: 24, weight: .regular))
                                    .foregroundColor(selectedSymbol == symbol ? .accentColor : .primary)
                            }
                            .frame(height: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(symbolNames[symbol] ?? LocalizedStringResource("Icon", comment: "Fallback accessibility label for an avatar icon.")))
                        .accessibilityAddTraits(selectedSymbol == symbol ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 24)
            }
            
            // Color Palette
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Background Color")
                    .appFont(AppTextRole.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(availableColors, id: \.hex) { item in
                        Button {
                            selectedColorHex = item.hex
                            hasCustomizedSticker = true
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
                        .accessibilityLabel(Text("\(String(localized: item.name)) color", comment: "Accessibility label for avatar background color swatch — variable is the localized color name."))
                        .accessibilityAddTraits(selectedColorHex == item.hex ? .isSelected : [])
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
                    if selectedPhoto == nil {
                        Text("Choose Photo from Library", comment: "Button to select an avatar photo from the user's photo library.")
                    } else {
                        Text("Choose Another Photo", comment: "Button to replace the currently selected avatar photo.")
                    }
                }
            }
            .buttonStyle(.catbird(.tonal, size: .lg, fullWidth: true))
            .padding(.horizontal, 24)
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        let downsampled = await Task.detached(priority: .userInitiated) {
                            Self.downsampleAvatar(data: data, maxPixelSize: 1000)
                        }.value
                        if let downsampled {
                            await MainActor.run {
                                selectedPhoto = downsampled
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Save Action
    
    private func saveAndContinue() {
        guard willUpload else {
            onContinue()
            return
        }
        guard let client = appState.atProtoClient else {
            logger.warning("No ATProtoClient available; advancing onboarding")
            onContinue()
            return
        }
        
        isUploading = true
        uploadErrorMessage = nil
        
        Task {
            do {
                let photo = (avatarMode == .photo) ? selectedPhoto : nil
                let stickerData = (avatarMode != .photo) ? renderStickerImage() : nil
                
                let imageData = try await Task.detached(priority: .userInitiated) { () -> Data in
                    if let photo {
                        if let jpeg = photo.jpegData(compressionQuality: 0.85) {
                            return jpeg
                        }
                    } else if let stickerData {
                        return stickerData
                    }
                    throw NSError(
                        domain: "OnboardingAvatar",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to render avatar image"]
                    )
                }.value
                
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
                    uploadErrorMessage = UserFacingError.message(
                        for: error,
                        action: String(localized: "save your profile picture", comment: "Action phrase in error message when saving onboarding avatar fails.")
                    )
                    logger.error("Avatar upload failed: \(error)")
                }
            }
        }
    }
    
    @MainActor
    private func renderStickerImage() -> Data? {
        let activeColor = availableColors.first(where: { $0.hex == selectedColorHex })?.color ?? .blue
        
        let stickerView = Circle()
            .fill(activeColor)
            .frame(width: 512, height: 512)
            .overlay(
                Image(systemName: selectedSymbol)
                    .font(.system(size: 240, weight: .semibold)) // fixed raster for uploaded avatar: must not scale
                    .foregroundColor(.white)
            )
        
        let renderer = ImageRenderer(content: stickerView)
        renderer.scale = 1.0
        #if os(iOS)
        let size = CGSize(width: 512, height: 512)
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
        #elseif os(macOS)
        return renderer.nsImage?.pngImageData()
        #endif
    }
    
    // MARK: - Image Processing Helper
    
    private static func downsampleAvatar(data: Data, maxPixelSize: CGFloat = 1000) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return UIImage(data: data)
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        // A zero size makes NSImage use the thumbnail's pixel dimensions.
        return UIImage(cgImage: cgImage, size: .zero)
        #endif
    }
}
