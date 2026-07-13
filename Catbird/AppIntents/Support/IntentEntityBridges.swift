//
//  IntentEntityBridges.swift
//  Catbird
//
//  Helpers that bridge Petrel's dynamically-typed record container to the
//  typed fields App Intents entities need. Separated from the generated entity
//  files so the generator doesn't need to understand Petrel's value container.
//

import Foundation
import Petrel

enum IntentEntityBridges {
  /// Extracts post body text from a PostView's dynamically-typed record.
  /// Returns nil for reposts, embeds-only posts, or posts with empty text.
  static func postText(_ view: AppBskyFeedDefs.PostView) -> String? {
    guard case .knownType(let record) = view.record,
      let post = record as? AppBskyFeedPost,
      !post.text.isEmpty
    else { return nil }
    return post.text
  }

  /// Extracts the record key (rkey) from an AT Protocol URI.
  /// Returns an empty string for malformed URIs (handled gracefully downstream).
  static func recordKey(_ uri: ATProtocolURI) -> String {
    uri.recordKey ?? ""
  }
}
