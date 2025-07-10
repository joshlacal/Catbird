//
//  ThreadPostEditorView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/18/23.
//

import SwiftUI
import Petrel

struct ThreadPostEditorView: View {
    let entry: ThreadEntry
    let entryIndex: Int
    let isCurrentPost: Bool
    let isEditing: Bool
    @Bindable var viewModel: PostComposerViewModel
    let onTap: () -> Void
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState
    @FocusState private var isTextFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                avatarView
                
                VStack(alignment: .leading, spacing: 8) {
                    authorInfoView
                    
                    if isEditing {
                        editingTextView
                    } else {
                        previewTextView
                    }
                    
                    if isEditing {
                        editingMediaView
                    } else {
                        previewMediaView
                    }
                    
                    characterCountView
                }
                
                Spacer()
                
                if !isEditing && viewModel.threadEntries.count > 1 {
                    deleteButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.clear)
            .onTapGesture {
                if !isEditing {
                    onTap()
                }
            }
        }
        .onChange(of: isEditing) {
            if isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFocused = true
                }
            }
        }
        .onChange(of: viewModel.postText) {
            if isEditing {
                viewModel.updatePostContent()
            }
        }
    }
    
    private var avatarView: some View {
        Group {
            if let profile = appState.currentUserProfile,
               let avatarURL = profile.avatar {
                AsyncImage(url: URL(string: avatarURL.description)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(
                            Image(systemName: "person.fill")
                                .appFont(size: 16)
                                .foregroundColor(.white)
                        )
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .appFont(size: 16)
                            .foregroundColor(.white)
                    )
            }
        }
    }
    
    private var authorInfoView: some View {
        HStack {
            if let profile = appState.currentUserProfile {
                Text(profile.displayName ?? "You")
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.semibold)
                
                Text("@\(profile.handle.description)")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("You")
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.semibold)
                
                Text("@handle")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isEditing {
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
    
    private var editingTextView: some View {
        TextField("What's happening?", text: $viewModel.postText, axis: .vertical)
            .textFieldStyle(PlainTextFieldStyle())
            .appFont(AppTextRole.body)
            .lineLimit(3...10)
            .focused($isTextFocused)
    }
    
    private var previewTextView: some View {
        Group {
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.text)
                    .appFont(AppTextRole.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Tap to add content")
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    @ViewBuilder
    private var editingMediaView: some View {
        if !viewModel.mediaItems.isEmpty {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4)
            ], spacing: 4) {
                ForEach(viewModel.mediaItems.prefix(4), id: \.id) { item in
                    if let image = item.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        
        if let videoItem = viewModel.videoItem, let image = videoItem.image {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    Image(systemName: "play.circle.fill")
                        .appFont(size: 40)
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                )
        }
        
        // Show GIF if selected
        if let selectedGif = viewModel.selectedGif {
            GifVideoView(gif: selectedGif, onTap: {})
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        
        // Show URL cards
        ForEach(viewModel.detectedURLs, id: \.self) { (url: String) in
            if let card = viewModel.urlCards[url] {
                ComposeURLCardView(
                    card: card,
                    onRemove: { /* handled by parent */ },
                    willBeUsedAsEmbed: viewModel.willBeUsedAsEmbed(for: url)
                )
            }
        }
    }
    
    @ViewBuilder
    private var previewMediaView: some View {
        if !entry.mediaItems.isEmpty {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4)
            ], spacing: 4) {
                ForEach(entry.mediaItems.prefix(4), id: \.id) { item in
                    if let image = item.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray5))
                                .frame(height: 120)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundColor(.secondary)
                                )
                        }
                    }
                }
            }
        
        if let videoItem = entry.videoItem {
            if let image = videoItem.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        Image(systemName: "play.circle.fill")
                            .appFont(size: 40)
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .frame(height: 200)
                    .overlay(
                        VStack {
                            Image(systemName: "video")
                                .appFont(size: 24)
                                .foregroundColor(.secondary)
                            Text("Video")
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            }
        }
        
        // Show GIF if selected for this thread entry
        if let selectedGif = entry.selectedGif {
            GifVideoView(gif: selectedGif, onTap: {})
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    private var characterCountView: some View {
        HStack {
            Spacer()
            let count = isEditing ? viewModel.postText.count : entry.text.count
            Text("\(count)/300")
                .appFont(AppTextRole.caption2)
                .foregroundColor(count > 300 ? .red : .secondary)
        }
    }
    
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .appFont(size: 20)
                .foregroundStyle(.white, Color(.systemGray3))
        }
        .padding(.top, 4)
    }
    
}
