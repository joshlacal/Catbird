import ExyteChat
import SwiftUI
import Petrel

struct MessageBubble: View {
  let message: Message
  let embed: AppBskyEmbedRecord.ViewRecordUnion?
  let position: PositionInUserGroup
  @Environment(AppState.self) private var appState
  @Binding var path: NavigationPath
  
  // Animation state
  @State private var animationOffset: CGFloat = 30
  @State private var animationOpacity: Double = 0
  
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
    case .top: return 18
    case .middle: return 8
    case .bottom: return 18
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
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: animationOpacity)
          Circle()
            .fill(Color.gray.opacity(0.6))
            .frame(width: 4, height: 4)
            .scaleEffect(0.8)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(0.2), value: animationOpacity)
          Circle()
            .fill(Color.gray.opacity(0.6))
            .frame(width: 4, height: 4)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(0.4), value: animationOpacity)
        }
        .onAppear {
          animationOpacity = 1
        }
      case .sent:
        Image(systemName: "checkmark")
          .font(.caption2)
          .foregroundColor(.gray)
      case .read:
        Image(systemName: "checkmark.circle.fill")
          .font(.caption2)
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
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
          
          if !message.attachments.isEmpty {
            ForEach(message.attachments) { attachment in
              AttachmentView(attachment: attachment)
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
      .offset(y: animationOffset)
      .opacity(animationOpacity)
      .onAppear {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0)) {
          animationOffset = 0
          animationOpacity = 1
        }
      }
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
