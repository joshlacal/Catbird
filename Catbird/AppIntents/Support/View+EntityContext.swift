//
//  View+EntityContext.swift
//  Catbird
//
//  Onscreen-context bridge for Apple Intelligence / Siri: annotating a view
//  with an App Intents entity identifier is what lets "block this guy" or
//  "like this post" resolve to the profile/post currently on screen. Without
//  the annotation the system has no visibility into the app's content.
//

import AppIntents
import SwiftUI

enum AppEntityAnnotationIdentifiers {
  static func postURI(_ candidate: String) -> String? {
    candidate.hasPrefix("at://") ? candidate : nil
  }

  static func postURI(for cachedPost: CachedFeedViewPost) -> String? {
    guard let post = try? cachedPost.feedViewPost else { return nil }
    return postURI(post.post.uri.uriString())
  }
}

extension View {
  /// Associates this view with an App Intents entity for onscreen context.
  /// No-op on OS versions without the annotation API.
  @ViewBuilder
  func entityContext(_ identifier: EntityIdentifier?) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      self.appEntityIdentifier(identifier)
    } else {
      self
    }
  }
}
