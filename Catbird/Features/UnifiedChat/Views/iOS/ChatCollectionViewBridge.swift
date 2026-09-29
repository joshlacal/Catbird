#if os(iOS)
import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct ChatCollectionViewBridge<DataSource: UnifiedChatDataSource>: UIViewControllerRepresentable {
  @Environment(AppState.self) private var appState

  let dataSource: DataSource
  @Binding var navigationPath: NavigationPath
  var onMessageLongPress: ((DataSource.Message) -> Void)?
  var onRequestEmojiPicker: ((String) -> Void)?
  var onRetryMessage: ((String) -> Void)?
  var onEditMessage: ((DataSource.Message) -> Void)?
  var onUnsendMessage: ((DataSource.Message) -> Void)?
  var onReply: ((DataSource.Message) -> Void)?

  func makeUIViewController(context: Context) -> ChatCollectionViewController<DataSource> {
    let controller = ChatCollectionViewController(
      dataSource: dataSource,
      navigationPath: $navigationPath,
      appState: appState
    )
    controller.onMessageLongPress = onMessageLongPress
    controller.onRequestEmojiPicker = onRequestEmojiPicker
    controller.onRetryMessage = onRetryMessage
    controller.onEditMessage = onEditMessage
    controller.onUnsendMessage = onUnsendMessage
    controller.onReply = onReply
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
    controller.onRetryMessage = onRetryMessage
    controller.onEditMessage = onEditMessage
    controller.onUnsendMessage = onUnsendMessage
    controller.onReply = onReply
  }
}
#endif
