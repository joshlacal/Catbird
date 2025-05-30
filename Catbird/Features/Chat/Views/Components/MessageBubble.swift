import ExyteChat
import SwiftUI
import Petrel

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

  var body: some View {
    VStack(alignment: message.user.isCurrentUser ? .trailing : .leading, spacing: 4) {
      HStack {
        if message.user.isCurrentUser {
          Spacer()
        }
        VStack(alignment: .leading) {
          
          if let embed = embed {
            RecordEmbedView(record: embed, labels: nil, path: $path)
              .foregroundStyle(.primary)
              .padding(8)
          }
          
          Text(message.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
          if !message.attachments.isEmpty {
            ForEach(message.attachments) { attachment in
              AttachmentView(attachment: attachment)
            }
          }
          if let recording = message.recording {
            AudioRecordingView(recording: recording)
          }
        }
        .background(message.user.isCurrentUser ? Color.accentColor : Color.gray.opacity(0.2))
        .foregroundColor(message.user.isCurrentUser ? .white : .primary)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        if !message.user.isCurrentUser {
          Spacer()
        }
      }
      .padding(.horizontal)
      
      // Display reactions if available
      // Note: We need to get the original message view to show reactions
      // This should be passed from the parent view
    }
  }
}

struct AttachmentView: View {
  let attachment: Attachment

  var body: some View {
    switch attachment.type {
    case .image:
      AsyncImage(url: attachment.full) { image in
        image.resizable().aspectRatio(contentMode: .fill)
      } placeholder: {
        ProgressView()
      }
      .frame(maxWidth: 200, maxHeight: 200)
      .cornerRadius(12)
    case .video:
      ZStack {
        AsyncImage(url: attachment.thumbnail) { image in
          image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
          ProgressView()
        }
        .frame(maxWidth: 200, maxHeight: 200)
        Image(systemName: "play.circle.fill")
          .font(.system(size: 40))
          .foregroundColor(.white)
      }
      .cornerRadius(12)
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
        .font(.caption)
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
