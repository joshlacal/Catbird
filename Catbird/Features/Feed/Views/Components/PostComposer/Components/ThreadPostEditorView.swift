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
            HStack(alignment: .top, spacing: 16) {
                avatarView
                
                VStack(alignment: .leading, spacing: 12) {
                    authorInfoView
                    
                    Group {
                        if isEditing {
                            editingTextView
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .leading)),
                                    removal: .opacity.combined(with: .move(edge: .trailing))
                                ))
                        } else {
                            previewTextView
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                                    removal: .opacity.combined(with: .move(edge: .leading))
                                ))
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: isEditing)
                    
                    Group {
                        if isEditing {
                            editingMediaView
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                                    removal: .opacity.combined(with: .scale(scale: 1.05))
                                ))
                        } else {
                            previewMediaView
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 1.05)),
                                    removal: .opacity.combined(with: .scale(scale: 0.95))
                                ))
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: isEditing)
                    
                    characterCountView
                }
                
                Spacer()
                
                if !isEditing && viewModel.threadEntries.count > 1 {
                    deleteButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
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
        VStack(spacing: 8) {
            ZStack {
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
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "person.fill")
                                .appFont(size: 18)
                                .foregroundColor(.white)
                        )
                }
                
                // Thread position indicator
                if entryIndex > 0 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Text("\(entryIndex + 1)")
                                .appFont(size: 10)
                                .foregroundColor(.white)
                                .fontWeight(.semibold)
                        )
                        .offset(x: 14, y: -14)
                }
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
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                
                Circle()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .scaleEffect(1.0)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isEditing)
            }
            
            Text("Editing")
                .appFont(AppTextRole.caption)
                .foregroundColor(.accentColor)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
        .transition(.asymmetric(
            insertion: .scale.combined(with: .opacity),
            removal: .scale.combined(with: .opacity)
        ))
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
                    .lineLimit(4)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tap to write post \(entryIndex + 1)")
                            .appFont(AppTextRole.body)
                            .foregroundColor(.secondary)
                            .fontWeight(.medium)
                        
                        Text("Continue your thread here")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(Color.tertiaryLabel)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "square.and.pencil")
                        .appFont(size: 16)
                        .foregroundColor(Color.tertiaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.systemGray6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.systemGray5, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                )
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
                                .fill(Color.systemGray5)
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
                    .fill(Color.systemGray5)
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
            let remaining = 300 - count
            
            HStack(spacing: 6) {
                Circle()
                    .fill(remaining < 0 ? .red : remaining < 20 ? .orange : remaining < 50 ? .yellow : .secondary)
                    .frame(width: 6, height: 6)
                
                Text("\(remaining)")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(remaining < 0 ? .red : remaining < 20 ? .orange : remaining < 50 ? .yellow : .secondary)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.systemBackground)
                    .overlay(
                        Capsule()
                            .stroke(Color.systemGray4, lineWidth: 0.5)
                    )
            )
            .opacity(isEditing ? 1.0 : 0.6)
        }
    }
    
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .appFont(size: 20)
                .foregroundStyle(.white, Color.systemGray3)
        }
        .padding(.top, 4)
    }
    
}
