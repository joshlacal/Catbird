import Foundation
import Petrel
import PetrelCatbird

/// Behavior-free adapter over the generated `FeedItem.post` union. Plaintext
/// Circle posts are `FeedViewPost`; encrypted posts are an `EncryptedPostView`
/// opened by `CirclePostOpener` (results in `CircleFeedModel.opened`).
extension BlueCatbirdCircleDefs.FeedItemPostUnion {
  /// The plaintext arm; nil for the encrypted arm and for `.unexpected`.
  var feedViewPost: AppBskyFeedDefs.FeedViewPost? {
    if case .appBskyFeedDefsFeedViewPost(let post) = self { return post }
    return nil
  }

  /// The encrypted arm; nil otherwise.
  var encryptedPostView: BlueCatbirdCircleDefs.EncryptedPostView? {
    if case .blueCatbirdCircleDefsEncryptedPostView(let view) = self { return view }
    return nil
  }

  var isEncrypted: Bool {
    if case .blueCatbirdCircleDefsEncryptedPostView = self { return true }
    return false
  }

  /// A stable list key: the post URI, or for `.unexpected` (no URI) the
  /// variant's encoded form, so unknown rows still render one each.
  var feedRowKey: String {
    if let uri = postURI?.uriString() { return uri }
    guard case .unexpected(let container) = self,
          let data = try? JSONEncoder().encode(container) else { return "unexpected" }
    return "unexpected-" + String(decoding: data, as: UTF8.self)
  }

  /// The post's URI for either arm (the STANDARD form for envelopes).
  var postURI: ATProtocolURI? {
    switch self {
    case .appBskyFeedDefsFeedViewPost(let post): return post.post.uri
    case .blueCatbirdCircleDefsEncryptedPostView(let view): return view.uri
    case .unexpected: return nil
    }
  }
}
