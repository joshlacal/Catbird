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
  @Environment(\.colorScheme) private var colorScheme
  @State private var displayName: String = ""
  @State private var description: String = ""
  @State private var pronouns: String = ""
  @State private var website: String = ""
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
  private let bioCharLimit = 256

  enum ImagePickerType {
    case avatar, banner
  }

  init(isPresented: Binding<Bool>, viewModel: ProfileViewModel) {
    self._isPresented = isPresented
    self.viewModel = viewModel
    _displayName = State(initialValue: viewModel.profile?.displayName ?? "")
    _description = State(initialValue: viewModel.profile?.description ?? "")
    _pronouns = State(initialValue: viewModel.profile?.pronouns ?? "")
    _website = State(initialValue: viewModel.profile?.website?.uriString() ?? "")
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 0) {
          // Banner + Avatar overlay
          bannerSection

          // Form fields
          VStack(spacing: 20) {
            profileTextField("Display Name", text: $displayName, icon: "person.fill")

            profileTextField("Pronouns", text: $pronouns, icon: "text.quote", placeholder: "e.g. they/them")

            profileTextField("Website", text: $website, icon: "link", placeholder: "https://example.com")
              #if os(iOS)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
              #endif
              .autocorrectionDisabled()

            // Bio
            VStack(alignment: .leading, spacing: 8) {
              Label("Bio", systemImage: "text.alignleft")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

              TextEditor(text: $description)
                .frame(minHeight: 100)
                .padding(8)
                .background(
                  RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray6))
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
                .scrollContentBackground(.hidden)

              HStack {
                Spacer()
                Text("\(description.count)/\(bioCharLimit)")
                  .font(.caption2)
                  .foregroundStyle(description.count > bioCharLimit ? .red : .secondary)
              }
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 20)
          .padding(.bottom, 32)

          // Error
          if let errorMessage {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
              Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
          }
        }
      }
      .navigationTitle("Edit Profile")
      #if os(iOS)
      .toolbarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            isPresented = false
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Button {
            saveProfile()
          } label: {
            if isUploading {
              ProgressView()
            } else {
              Text("Save")
                .fontWeight(.semibold)
            }
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

  // MARK: - Banner + Avatar Section

  private var bannerSection: some View {
    ZStack(alignment: .bottomLeading) {
      // Banner
      Button {
        imagePickerType = .banner
        showingImagePicker = true
      } label: {
        ZStack {
          bannerContent
            .frame(height: 150)
            .clipped()

          // Overlay
          Color.black.opacity(0.2)

          Image(systemName: "camera.fill")
            .font(.title3)
            .foregroundStyle(.white)
        }
        .frame(height: 150)
      }
      .buttonStyle(.plain)

      // Avatar
      Button {
        imagePickerType = .avatar
        showingImagePicker = true
      } label: {
        ZStack {
          avatarContent
            .frame(width: 80, height: 80)
            .clipShape(Circle())

          Circle()
            .fill(.black.opacity(0.3))
            .frame(width: 80, height: 80)

          Image(systemName: "camera.fill")
            .font(.body)
            .foregroundStyle(.white)
        }
        .overlay(
          Circle()
            .stroke(Color(.systemBackground), lineWidth: 3)
        )
      }
      .buttonStyle(.plain)
      .offset(x: 20, y: 40)
    }
    .padding(.bottom, 44)
  }

  @ViewBuilder
  private var bannerContent: some View {
    if let bannerImage {
      #if os(iOS)
      Image(uiImage: bannerImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
      #else
      Image(nsImage: bannerImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
      #endif
    } else if let bannerURL = viewModel.profile?.banner?.uriString(),
              let url = URL(string: bannerURL) {
      LazyImage(url: url) { state in
        if let image = state.image {
          image.resizable().aspectRatio(contentMode: .fill)
        } else {
          Rectangle().fill(Color(.systemGray5))
        }
      }
    } else {
      Rectangle().fill(Color(.systemGray5))
    }
  }

  @ViewBuilder
  private var avatarContent: some View {
    if let avatarImage {
      #if os(iOS)
      Image(uiImage: avatarImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
      #else
      Image(nsImage: avatarImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
      #endif
    } else if let avatarURL = viewModel.profile?.avatar?.uriString(),
              let url = URL(string: avatarURL) {
      LazyImage(url: url) { state in
        if let image = state.image {
          image.resizable().aspectRatio(contentMode: .fill)
        } else {
          Circle().fill(Color(.systemGray4))
        }
      }
    } else {
      Circle().fill(Color(.systemGray4))
        .overlay(
          Image(systemName: "person.fill")
            .font(.title)
            .foregroundStyle(.white)
        )
    }
  }

  // MARK: - Reusable Field

  private func profileTextField(
    _ title: String,
    text: Binding<String>,
    icon: String,
    placeholder: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: icon)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)

      TextField(placeholder ?? title, text: text)
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color(.systemGray6))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
    }
  }

  // MARK: - Actions

  private func loadImage(from item: PhotosPickerItem?, for type: ImagePickerType) {
    guard let item else { return }

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

  /// Normalizes a website string by prepending "https://" if no scheme is present.
  private func normalizedWebsite(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.contains("://") {
      return trimmed
    }
    return "https://\(trimmed)"
  }

  private func saveProfile() {
    Task {
      await MainActor.run {
        isUploading = true
        errorMessage = nil
      }

      do {
        var avatarBlob: Blob?
        var bannerBlob: Blob?

        if let avatarImage,
           let avatarData = avatarImage.jpegData(compressionQuality: 0.8) {
          avatarBlob = try await viewModel.uploadImageBlob(avatarData)
        }

        if let bannerImage,
           let bannerData = bannerImage.jpegData(compressionQuality: 0.8) {
          bannerBlob = try await viewModel.uploadImageBlob(bannerData)
        }

        try await viewModel.updateProfile(
          displayName: displayName.isEmpty ? nil : displayName,
          description: description.isEmpty ? nil : description,
          pronouns: pronouns.isEmpty ? nil : pronouns,
          website: normalizedWebsite(website),
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
          errorMessage = "Failed to save: \(error.localizedDescription)"
          logger.error("Failed to save profile: \(error.localizedDescription)")
        }
      }
    }
  }
}
