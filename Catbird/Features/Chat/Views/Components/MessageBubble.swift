import ExyteChat
import SwiftUI
import Petrel
import AVKit

struct MessageBubble: View {
  let message: Message
  let embed: AppBskyEmbedRecord.ViewRecordUnion?
  let position: PositionInUserGroup
  @Environment(AppState.self) private var appState
  @Binding var path: NavigationPath
  
  
  // Get the conversation ID from the current navigation context
  private var convoId: String {
    // This is a bit hacky - we should pass convoId as a parameter
    // For now, we'll try to extract it from the navigation path
    ""
  }
  
  // Improved corner radius calculation based on position
  private var cornerRadius: CGFloat {
    switch position {
    case .single: return 18
    case .first: return 18
    case .middle: return 8
    case .last: return 18
    }
  }
  
  // Delivery status indicator
  private var deliveryStatusIcon: some View {
    Group {
      switch message.status {
      case .sending:
        HStack(spacing: 2) {
          Circle()
            .fill(Color.gray.opacity(0.6))
            .frame(width: 4, height: 4)
            .scaleEffect(0.6)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: UUID())
          Circle()
            .fill(Color.gray.opacity(0.6))
            .frame(width: 4, height: 4)
            .scaleEffect(0.8)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(0.2), value: UUID())
          Circle()
            .fill(Color.gray.opacity(0.6))
            .frame(width: 4, height: 4)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(0.4), value: UUID())
        }
      case .sent:
        Image(systemName: "checkmark")
          .appFont(AppTextRole.caption2)
          .foregroundColor(.gray)
      case .read:
        Image(systemName: "checkmark.circle.fill")
          .appFont(AppTextRole.caption2)
          .foregroundColor(.blue)
      default:
        EmptyView()
      }
    }
  }

  var body: some View {
    VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 2) {
      HStack(alignment: .bottom, spacing: 8) {
        if message.user.isCurrentUser {
          Spacer(minLength: 50)
          
          // Delivery status for sent messages
          if message.user.isCurrentUser {
            deliveryStatusIcon
              .padding(.bottom, 2)
          }
        }
        
        VStack(alignment: .leading, spacing: 4) {
          if let embed = embed {
            RecordEmbedView(record: embed, labels: nil, path: $path)
              .foregroundStyle(.primary)
              .padding(8)
          }

          Text(message.text)
                .appFont(AppTextRole.body)
                .padding(.horizontal, 14)
            .padding(.vertical, 10)
          
          if !message.attachments.isEmpty {
            ForEach(message.attachments) { attachment in
              AttachmentView(attachment: attachment, path: $path)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
          }
          
          if let recording = message.recording {
            AudioRecordingView(recording: recording)
              .padding(.horizontal, 8)
              .padding(.bottom, 4)
          }
        }
        .background(
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(message.user.isCurrentUser ? Color.accentColor : Color.gray.opacity(0.15))
            .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
        )
        .foregroundColor(message.user.isCurrentUser ? .white : .primary)
        .overlay(
          // Show sending indicator overlay for pending messages
          Group {
            if message.status == .sending {
              RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.1))
            }
          }
        )
        
        if !message.user.isCurrentUser {
          Spacer(minLength: 50)
        }
      }
      .padding(.horizontal, 12)
    }
  }
}

struct AttachmentView: View {
  let attachment: Attachment
  @Binding var path: NavigationPath
  @State private var showingFullScreen = false

  var body: some View {
    switch attachment.type {
    case .image:
      Button(action: {
        showingFullScreen = true
      }) {
        AsyncImage(url: attachment.full) { image in
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
        } placeholder: {
          ZStack {
            RoundedRectangle(cornerRadius: 12)
              .fill(Color.gray.opacity(0.2))
              .frame(maxWidth: 200, maxHeight: 200)
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .gray))
          }
        }
        .frame(maxWidth: 200, maxHeight: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .fullScreenCover(isPresented: $showingFullScreen) {
        MediaFullScreenView(attachment: attachment)
      }
      
    case .video:
      // Use the chat video player for inline playback
      ChatVideoThumbnailView(attachment: attachment, showingFullScreen: $showingFullScreen)
        .fullScreenCover(isPresented: $showingFullScreen) {
          MediaFullScreenView(attachment: attachment)
        }
      
    // Removed custom case - using link type for post embeds instead
    }
  }
}

struct MediaFullScreenView: View {
  let attachment: Attachment
  @Environment(\.dismiss) private var dismiss
  
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      
      VStack {
        HStack {
          Spacer()
          Button("Done") {
            dismiss()
          }
          .foregroundColor(.white)
          .padding()
        }
        
        Spacer()
        
        switch attachment.type {
        case .image:
          AsyncImage(url: attachment.full) { image in
            image
              .resizable()
              .aspectRatio(contentMode: .fit)
          } placeholder: {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .white))
          }
          
        case .video:
          // Full video player implementation using existing infrastructure
          ChatVideoPlayerView(attachment: attachment)
        }
        
        Spacer()
      }
    }
  }
}

struct AudioRecordingView: View {
  let recording: Recording

  var body: some View {
    HStack {
      Image(systemName: "play.circle.fill")
      HStack(spacing: 2) {
        ForEach(recording.waveformSamples.indices, id: \.self) { index in
          RoundedRectangle(cornerRadius: 2)
            .frame(width: 3, height: max(4, recording.waveformSamples[index] * 40))
        }
      }
      Text(formatDuration(recording.duration))
        .appFont(AppTextRole.caption)
    }
    .padding(8)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(16)
  }

  private func formatDuration(_ duration: Double) -> String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}

/// A view that displays a Bluesky post embed within a chat message
struct ChatPostEmbedView: View {
  let postEmbedData: PostEmbedData
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Post header with author info
      HStack(spacing: 8) {
        AsyncImage(url: postEmbedData.postView.author.avatar?.url) { image in
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
        } placeholder: {
          Circle()
            .fill(Color.gray.opacity(0.3))
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        
        VStack(alignment: .leading, spacing: 2) {
          if let displayName = postEmbedData.postView.author.displayName {
            Text(displayName)
              .appFont(AppTextRole.footnote)
              .fontWeight(.medium)
              .lineLimit(1)
          }
          
          Text("@\(postEmbedData.authorHandle)")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        
        Spacer()
        
        Image(systemName: "quote.bubble")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      
      // Post content
      Text(postEmbedData.displayText)
        .appFont(AppTextRole.body)
        .lineLimit(3)
      
      // Post metadata
      let createdAt = postEmbedData.postView.indexedAt.date
      Text(RelativeDateTimeFormatter().localizedString(for: createdAt, relativeTo: Date()))
        .appFont(AppTextRole.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(.secondarySystemBackground))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color(.separator), lineWidth: 0.5)
        )
    )
    .onTapGesture {
      // Navigate to the post when tapped
      let destination = NavigationDestination.post(postEmbedData.postView.uri)
      path.append(destination)
    }
  }
}

// MARK: - Chat Video Player Components

/// Thumbnail view for video attachments in chat with play button overlay
struct ChatVideoThumbnailView: View {
  let attachment: Attachment
  @Binding var showingFullScreen: Bool
  @Environment(AppState.self) private var appState
  @State private var showingInlinePlayer = false
  
  var body: some View {
    Button(action: {
      // Check user preference for video playback
      if appState.appSettings.autoplayVideos {
        showingInlinePlayer = true
      } else {
        showingFullScreen = true
      }
    }) {
      ZStack {
        AsyncImage(url: attachment.thumbnail) { image in
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
        } placeholder: {
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.2))
            .overlay(
              ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .gray))
            )
        }
        .frame(maxWidth: 200, maxHeight: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        
        // Play button overlay - only show if not autoplaying
        if !showingInlinePlayer {
          Circle()
            .fill(Color.black.opacity(0.6))
            .frame(width: 50, height: 50)
            .overlay(
              Image(systemName: "play.fill")
                .appFont(size: 20)
                .foregroundColor(.white)
                .offset(x: 2) // Slight offset to center the play triangle
            )
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.gray.opacity(0.2), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .overlay(
      Group {
        if showingInlinePlayer {
          ChatInlineVideoPlayerView(attachment: attachment, isPresented: $showingInlinePlayer)
        }
      }
    )
  }
}

/// Inline video player for chat messages
struct ChatInlineVideoPlayerView: View {
  let attachment: Attachment
  @Binding var isPresented: Bool
  @Environment(AppState.self) private var appState
  @State private var player: AVPlayer?
  @State private var isPlaying = false
  @State private var showControls = false
  @State private var playerTask: Task<Void, Never>?
  
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.black)
        .frame(maxWidth: 200, maxHeight: 200)
      
      if let player = player {
        VideoPlayer(player: player)
          .frame(maxWidth: 200, maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .onTapGesture {
            togglePlayback()
          }
      } else {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: .white))
      }
      
      // Controls overlay
      if showControls {
        VStack {
          HStack {
            Spacer()
            Button(action: {
              isPresented = false
            }) {
              Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundColor(.white)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
            }
          }
          Spacer()
          HStack {
            Button(action: togglePlayback) {
              Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.largeTitle)
                .foregroundColor(.white)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
            }
            Spacer()
            Button(action: {
              // Open fullscreen
              isPresented = false
              // This would need to be passed up to trigger fullscreen
            }) {
              Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.title2)
                .foregroundColor(.white)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
            }
          }
          .padding()
        }
        .padding()
      }
    }
    .onAppear {
      setupPlayer()
      showControlsTemporarily()
    }
    .onDisappear {
      cleanupPlayer()
    }
    .onTapGesture {
      showControlsTemporarily()
    }
  }
  
  private func setupPlayer() {
    let videoURL = attachment.full
    
    playerTask = Task {
      let newPlayer = AVPlayer(url: videoURL)
      await MainActor.run {
        self.player = newPlayer
        
        // Start muted as per app convention
        newPlayer.isMuted = true
        
        // Auto-play if enabled
        if appState.appSettings.autoplayVideos {
          newPlayer.play()
          isPlaying = true
        }
      }
    }
  }
  
  private func cleanupPlayer() {
    playerTask?.cancel()
    player?.pause()
    player = nil
  }
  
  private func togglePlayback() {
    guard let player = player else { return }
    
    if isPlaying {
      player.pause()
      isPlaying = false
    } else {
      player.play()
      isPlaying = true
    }
    
    showControlsTemporarily()
  }
  
  private func showControlsTemporarily() {
    showControls = true
    
    Task {
      try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
      await MainActor.run {
        if !isPlaying {
          showControls = false
        }
      }
    }
  }
}

/// Full-screen video player for chat attachments
struct ChatVideoPlayerView: View {
  let attachment: Attachment
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var player: AVPlayer?
  @State private var showControls = true
  @State private var playerTask: Task<Void, Never>?
  
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      
      if let player = player {
        VideoPlayer(player: player)
          .onTapGesture {
            showControls.toggle()
          }
      } else {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: .white))
      }
      
      // Controls overlay
      if showControls {
        VStack {
          HStack {
            Spacer()
            Button(action: {
              dismiss()
            }) {
              Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundColor(.white)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
            }
          }
          .padding()
          
          Spacer()
        }
      }
    }
    .onAppear {
      setupPlayer()
    }
    .onDisappear {
      cleanupPlayer()
    }
  }
  
  private func setupPlayer() {
    let videoURL = attachment.full
    
    playerTask = Task {
      let newPlayer = AVPlayer(url: videoURL)
      await MainActor.run {
        self.player = newPlayer
        
        // Don't start muted in fullscreen
        newPlayer.isMuted = false
        newPlayer.play()
      }
    }
  }
  
  private func cleanupPlayer() {
    playerTask?.cancel()
    player?.pause()
    player = nil
  }
}
