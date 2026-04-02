#if os(iOS)
import SwiftUI
import UIKit

/// Configuration for the inline UIKit composer hosted inside ChatCollectionViewController.
/// Pass `nil` to omit the composer (e.g. for ConversationView, UnifiedChatView).
struct InlineComposerConfig {
  var placeholderText: String = "Message"
  var onSend: (String) -> Void
  var onAttachTapped: () -> Void
  var onTypingChanged: ((Bool) -> Void)?
  var onPhotoPicker: (() -> Void)?
  var onGifPicker: (() -> Void)?
  var onPostPicker: (() -> Void)?
  var embedPreviewImage: UIImage? = nil
  var hasEmbed: Bool = false
  var onEmbedRemoved: (() -> Void)?

  // Voice recording
  var voiceMode: ComposerMode = .compose
  var voicePreviewURL: URL? = nil
  var voiceRecordingDuration: TimeInterval = 0
  var onVoiceRecordingStarted: (() -> Void)?
  var onVoiceRecordingLocked: (() -> Void)?
  var onVoiceRecordingStopped: (() -> Void)?
  var onVoiceRecordingCancelled: (() -> Void)?
  var onVoicePreviewSend: (() -> Void)?
  var onVoicePreviewDiscard: (() -> Void)?
}

@available(iOS 16.0, *)
struct ChatCollectionViewBridge<DataSource: UnifiedChatDataSource>: UIViewControllerRepresentable {
  @Environment(AppState.self) private var appState

  let dataSource: DataSource
  @Binding var navigationPath: NavigationPath
  var onMessageLongPress: ((DataSource.Message) -> Void)?
  var onRequestEmojiPicker: ((String) -> Void)?
  var composerConfig: InlineComposerConfig?

  func makeUIViewController(context: Context) -> ChatCollectionViewController<DataSource> {
    let controller = ChatCollectionViewController(
      dataSource: dataSource,
      navigationPath: $navigationPath,
      appState: appState
    )
    controller.onMessageLongPress = onMessageLongPress
    controller.onRequestEmojiPicker = onRequestEmojiPicker
    if let config = composerConfig {
      controller.installComposer(config: config)
    }
    return controller
  }

  func updateUIViewController(
    _ controller: ChatCollectionViewController<DataSource>,
    context: Context
  ) {
    controller.updateNavigationBinding($navigationPath)
    controller.updateAppState(appState)
    controller.onMessageLongPress = onMessageLongPress
    controller.onRequestEmojiPicker = onRequestEmojiPicker
    if let config = composerConfig {
      controller.updateComposerCallbacks(config: config)
      controller.updateComposerEmbedState(hasEmbed: config.hasEmbed, previewImage: config.embedPreviewImage)
      controller.updateComposerVoiceMode(config: config)
    }
  }
}
#endif
