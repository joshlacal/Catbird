#if os(iOS)
import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct ChatCollectionViewBridge<DataSource: UnifiedChatDataSource>: UIViewControllerRepresentable {
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.chatTranscriptBottomInset) private var bottomInset

  let dataSource: DataSource
  @Binding var navigationPath: NavigationPath
  var onMessageLongPress: ((DataSource.Message) -> Void)?
  var onRequestEmojiPicker: ((String) -> Void)?
  var onRetryMessage: ((String) -> Void)?
  var onEditMessage: ((DataSource.Message) -> Void)?
  var onUnsendMessage: ((DataSource.Message) -> Void)?
  var onReply: ((DataSource.Message) -> Void)?
  var onDeleteMessage: ((DataSource.Message) -> Void)?
  var onReportMessage: ((DataSource.Message) -> Void)?

  func makeUIViewController(context: Context) -> ChatCollectionViewController<DataSource> {
    let controller = ChatCollectionViewController(
      dataSource: dataSource,
      navigationPath: $navigationPath,
      appState: appState,
      sceneContext: sceneContext
    )
    controller.onMessageLongPress = onMessageLongPress
    controller.onRequestEmojiPicker = onRequestEmojiPicker
    controller.onRetryMessage = onRetryMessage
    controller.onEditMessage = onEditMessage
    controller.onUnsendMessage = onUnsendMessage
    controller.onReply = onReply
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
    controller.onMessageLongPress = onMessageLongPress
    controller.onRequestEmojiPicker = onRequestEmojiPicker
    controller.onRetryMessage = onRetryMessage
    controller.onEditMessage = onEditMessage
    controller.onUnsendMessage = onUnsendMessage
    controller.onReply = onReply
    controller.onDeleteMessage = onDeleteMessage
    controller.onReportMessage = onReportMessage
  }
}
#endif
