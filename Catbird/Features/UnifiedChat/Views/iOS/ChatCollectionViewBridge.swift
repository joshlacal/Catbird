#if os(iOS)
import SwiftUI
import UIKit

/// Configuration for the inline UIKit composer hosted inside ChatCollectionViewController.
/// Pass `nil` to omit the composer (e.g. for ConversationView, UnifiedChatView).
struct InlineComposerConfig {
  var placeholderText: String = "Message"
  /// When true the send button is disabled and taps are ignored, leaving the
  /// draft intact (WS-6.5: sends blocked during conversation recovery).
  var isSendBlocked: Bool = false
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

  var isEditMode: Bool = false
  var editMessageText: String? = nil
  var onCancelEdit: (() -> Void)? = nil

  // One-shot Siri/Shortcuts draft handoff. The owner clears this only after
  // the UIKit composer confirms that it applied the text.
  var prefillText: String? = nil
  var onPrefillApplied: (() -> Void)? = nil
}

@available(iOS 16.0, *)
struct ChatCollectionViewBridge<DataSource: UnifiedChatDataSource>: UIViewControllerRepresentable {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.chatTranscriptBottomInset) private var bottomInset
  #if DEBUG
  @Environment(\.chatPresentationFixtureRecords) private var fixtureRecords
  #endif

  let dataSource: DataSource
  @Binding var navigationPath: NavigationPath
  var onMessageLongPress: ((DataSource.Message) -> Void)?
  var onRequestEmojiPicker: ((String) -> Void)?
  var onRetryMessage: ((String) -> Void)?
  var onEditMessage: ((DataSource.Message) -> Void)?
  var onUnsendMessage: ((DataSource.Message) -> Void)?
  var onReply: ((DataSource.Message) -> Void)?
  var composerConfig: InlineComposerConfig?
  var onDeleteMessage: ((DataSource.Message) -> Void)?
  var onReportMessage: ((DataSource.Message) -> Void)?

  func makeUIViewController(context: Context) -> ChatCollectionViewController<DataSource> {
    let controller = ChatCollectionViewController(
      dataSource: dataSource,
      navigationPath: $navigationPath,
      appState: appState,
      sceneContext: sceneContext
    )
    #if DEBUG
    controller.updateFixtureRecords(fixtureRecords)
    #endif
    controller.onMessageLongPress = onMessageLongPress
    controller.onRequestEmojiPicker = onRequestEmojiPicker
    controller.onRetryMessage = onRetryMessage
    controller.onEditMessage = onEditMessage
    controller.onUnsendMessage = onUnsendMessage
    controller.onReply = onReply
    controller.updateComposer(config: composerConfig)
    controller.onDeleteMessage = onDeleteMessage
    controller.onReportMessage = onReportMessage
    controller.updatePrefetchSceneActivity(isActive: scenePhase == .active)
    return controller
  }

  func updateUIViewController(
    _ controller: ChatCollectionViewController<DataSource>,
    context: Context
  ) {
    controller.updateTranscriptBottomInset(bottomInset)
    controller.updateNavigationBinding($navigationPath)
    controller.updateAppState(appState)
    controller.updateSceneContext(sceneContext)
    controller.updatePrefetchSceneActivity(isActive: scenePhase == .active)
    #if DEBUG
    controller.updateFixtureRecords(fixtureRecords)
    #endif
    controller.onMessageLongPress = onMessageLongPress
    controller.onRequestEmojiPicker = onRequestEmojiPicker
    controller.onRetryMessage = onRetryMessage
    controller.onEditMessage = onEditMessage
    controller.onUnsendMessage = onUnsendMessage
    controller.onReply = onReply
    controller.updateComposer(config: composerConfig)
    controller.onDeleteMessage = onDeleteMessage
    controller.onReportMessage = onReportMessage
  }

  static func dismantleUIViewController(
    _ controller: ChatCollectionViewController<DataSource>,
    coordinator: ()
  ) {
    controller.dismantle()
  }
}
#endif
