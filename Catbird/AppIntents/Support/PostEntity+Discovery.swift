//
//  PostEntity+Discovery.swift
//  Catbird
//
//  Extends PostEntity with Spotlight indexing and Transferable support so
//  posts donated to the system index can be opened from Spotlight results.
//

import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation

@available(iOS 18.0, *)
extension PostEntity {
  /// The canonical Bluesky web URL for this post (bsky.app permalink).
  var webURL: URL? {
    guard !rkey.isEmpty else { return nil }
    return URL(string: "https://bsky.app/profile/\(authorHandle)/post/\(rkey)")
  }

  var attributeSet: CSSearchableItemAttributeSet {
    let set = defaultAttributeSet
    let authorName = authorDisplayName ?? "@\(authorHandle)"
    set.title = authorName
    set.textContent = text
    set.contentDescription = text
    set.authorNames = [authorName]
    set.keywords = [authorHandle, authorDisplayName].compactMap { $0 }
    set.url = webURL
    set.addedDate = indexedAt
    set.contentCreationDate = indexedAt
    return set
  }
}

@available(iOS 18.0, *)
extension PostEntity: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation(exporting: { entity in
      entity.text ?? "Post by @\(entity.authorHandle)"
    })
  }
}
