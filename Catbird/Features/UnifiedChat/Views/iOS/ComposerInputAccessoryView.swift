import CatbirdMLSCore
#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Composer Configuration

/// All data the SwiftUI composer needs, passed from the parent SwiftUI view
/// through the bridge into the UIKit controller.
struct ComposerConfiguration {
  var text: Binding<String>
  var attachedEmbed: Binding<MLSEmbedData?>
  var conversationId: String
  var onSend: (String, MLSEmbedData?) -> Void
  var imageSender: MLSImageSender?
  var onVoiceTapped: (() -> Void)?
  var isRecording: Bool
  var voiceOverlay: AnyView?
}

// MARK: - SwiftUI Content Wrapper

/// Thin SwiftUI wrapper that assembles the voice overlay + composer.
@available(iOS 16.0, *)
struct ComposerAccessoryContent: View {
  let config: ComposerConfiguration

  var body: some View {
    VStack(spacing: 0) {
      if let voiceOverlay = config.voiceOverlay {
        voiceOverlay
          .padding(.horizontal, 16)
          .padding(.bottom, 4)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      MLSMessageComposerView(
        text: config.text,
        attachedEmbed: config.attachedEmbed,
        conversationId: config.conversationId,
        onSend: config.onSend,
        imageSender: config.imageSender,
        onVoiceTapped: config.onVoiceTapped,
        isRecording: config.isRecording
      )
    }
  }
}
#endif
