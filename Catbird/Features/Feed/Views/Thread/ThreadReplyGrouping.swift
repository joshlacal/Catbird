#if os(iOS)
import Foundation
import Petrel

// MARK: - ParentPost Extensions
extension ParentPost {
  /// Safely extracts URI from parent post thread item
  var uri: ATProtocolURI? {
    return threadItem.uri
  }

  var post: AppBskyFeedDefs.PostView? {
    guard case .appBskyUnspeccedDefsThreadItemPost(let item) = threadItem.value else {
      return nil
    }
    return item.post
  }
}
#endif
