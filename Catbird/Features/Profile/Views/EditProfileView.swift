//
//  EditProfileView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/5/24.
//

import SwiftUI
import Petrel
import NukeUI
import PhotosUI
import OSLog

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct EditProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var displayName: String = ""
    @State private var description: String = ""
    @State private var avatarImage: PlatformImage?
    @State private var bannerImage: PlatformImage?
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var selectedBannerItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var errorMessage: String?
    @State private var showingImagePicker = false
    @State private var imagePickerType: ImagePickerType = .avatar
    @Binding var isPresented: Bool
    var viewModel: ProfileViewModel
    
    private let logger = Logger(subsystem: "blue.catbird", category: "EditProfileView")
    
    enum ImagePickerType {
        case avatar, banner
    }
    
    init(isPresented: Binding<Bool>, viewModel: ProfileViewModel) {
        self._isPresented = isPresented
        self.viewModel = viewModel
        _displayName = State(initialValue: viewModel.profile?.displayName ?? "")
        _description = State(initialValue: viewModel.profile?.description ?? "")
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // Banner Image Section
                Section("Banner Image") {
                    bannerImageSection
                }
                
                // Avatar Image Section
                Section("Profile Picture") {
                    avatarImageSection
                }
                
                // Profile Text Section
                Section("Profile Information") {
                    TextField("Display Name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $description)
                            .frame(height: 100)
                    }
                }
                
                // Error Section
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Profile")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .disabled(isUploading)
                }
            }
            .photosPicker(
                isPresented: $showingImagePicker,
                selection: imagePickerType == .avatar ? $selectedAvatarItem : $selectedBannerItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedAvatarItem) { _, newItem in
                loadImage(from: newItem, for: .avatar)
            }
            .onChange(of: selectedBannerItem) { _, newItem in
                loadImage(from: newItem, for: .banner)
            }
        }
    }
    
    @ViewBuilder
    private var avatarImageSection: some View {
        HStack {
            // Current/Selected Avatar
            Group {
                if let avatarImage = avatarImage {
                    #if os(iOS)
                    Image(uiImage: avatarImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #else
                    Image(nsImage: avatarImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #endif
                } else if let currentAvatarURL = viewModel.profile?.avatar?.uriString(),
                          let url = URL(string: currentAvatarURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                        }
                    }
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "person.fill")
                                .foregroundColor(.gray)
                        )
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 8) {
                Button("Change Photo") {
                    imagePickerType = .avatar
                    showingImagePicker = true
                }
                .buttonStyle(.bordered)
                
                if avatarImage != nil {
                    Button("Remove") {
                        avatarImage = nil
                        selectedAvatarItem = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var bannerImageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current/Selected Banner
            Group {
                if let bannerImage = bannerImage {
                    #if os(iOS)
                    Image(uiImage: bannerImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #else
                    Image(nsImage: bannerImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #endif
                } else if let currentBannerURL = viewModel.profile?.banner?.uriString(),
                          let url = URL(string: currentBannerURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                        )
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            HStack {
                Button("Change Banner") {
                    imagePickerType = .banner
                    showingImagePicker = true
                }
                .buttonStyle(.bordered)
                
                if bannerImage != nil {
                    Button("Remove") {
                        bannerImage = nil
                        selectedBannerItem = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                    .font(.caption)
                }
                
                Spacer()
            }
        }
        .padding(.vertical, 8)
    }
    
    private func loadImage(from item: PhotosPickerItem?, for type: ImagePickerType) {
        guard let item = item else { return }
        
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = PlatformImage(data: data) {
                    await MainActor.run {
                        switch type {
                        case .avatar:
                            self.avatarImage = image
                        case .banner:
                            self.bannerImage = image
                        }
                        self.errorMessage = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load image: \(error.localizedDescription)"
                    logger.error("Failed to load image: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func saveProfile() {
        Task {
            do {
                await MainActor.run {
                    isUploading = true
                    errorMessage = nil
                }
                
                var avatarBlob: Blob?
                var bannerBlob: Blob?
                
                // Upload avatar if changed
                if let avatarImage = avatarImage,
                   let avatarData = avatarImage.jpegData(compressionQuality: 0.8) {
                    avatarBlob = try await viewModel.uploadImageBlob(avatarData)
                }
                
                // Upload banner if changed
                if let bannerImage = bannerImage,
                   let bannerData = bannerImage.jpegData(compressionQuality: 0.8) {
                    bannerBlob = try await viewModel.uploadImageBlob(bannerData)
                }
                
                // Update profile with new data
                try await viewModel.updateProfile(
                    displayName: displayName,
                    description: description,
                    avatar: avatarBlob,
                    banner: bannerBlob
                )
                
                await MainActor.run {
                    isUploading = false
                    isPresented = false
                }
                
            } catch {
                await MainActor.run {
                    isUploading = false
                    errorMessage = "Failed to save profile: \(error.localizedDescription)"
                    logger.error("Failed to save profile: \(error.localizedDescription)")
                }
            }
        }
    }
}
