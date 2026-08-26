//
//  CircleMediaLoader.swift
//  Catbird
//

import Foundation
import Petrel
import PetrelCatbird

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Authenticated image loader and memory cache for Circle media.
///
/// Images are fetched exclusively through the proxied AppView media endpoint
/// (`blue.catbird.circle.getMedia`) via `CircleService`. Raw tokens and media
/// URLs are never exposed. Decoded `PlatformImage` instances are kept in memory
/// only, keyed by `accountDID|space|authorDID|cid`, and purged on account
/// logout/switch or Space unavailability.
actor CircleMediaLoader {
  static let shared = CircleMediaLoader()

  private var service: CircleService?
  private var images: [String: PlatformImage] = [:]

  init(service: CircleService? = nil) {
    self.service = service
  }

  func setService(_ service: CircleService) {
    self.service = service
  }

  /// Fetches and decodes a Circle image, caching in memory.
  func image(
    accountDID: String? = nil,
    space: SpaceRef,
    authorDID: DID,
    cid: CID,
    service: CircleService? = nil
  ) async throws -> PlatformImage {
    let accountKey = accountDID ?? "default"
    let key = "\(accountKey)|\(space.description)|\(authorDID.description)|\(cid.description)"

    if let cached = images[key] {
      return cached
    }

    guard let activeService = service ?? self.service else {
      throw CircleMediaError.serviceUnavailable
    }

    let data = try await activeService.media(space: space, authorDID: authorDID, cid: cid)
    guard let platformImage = PlatformImage(data: data) else {
      throw CircleMediaError.invalidImage
    }

    images[key] = platformImage
    return platformImage
  }

  /// Purges every cached image for an account (called on logout, switch, removal).
  func purge(accountDID: String) {
    images = images.filter { !$0.key.hasPrefix("\(accountDID)|") }
  }

  /// Purges cached images for one account in one Space.
  func purge(accountDID: String, space: SpaceRef) {
    let prefix = "\(accountDID)|\(space.description)|"
    images = images.filter { !$0.key.hasPrefix(prefix) }
  }

  /// Purges cached images for a specific Space regardless of account.
  func purge(space: SpaceRef) {
    let needle = "|\(space.description)|"
    images = images.filter { !$0.key.contains(needle) }
  }

  /// Purges all in-memory Circle images.
  func purgeAll() {
    images.removeAll()
  }
}

public enum CircleMediaError: Error, LocalizedError, Equatable {
  case invalidImage
  case serviceUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidImage:
      return "The Circle media could not be decoded as an image."
    case .serviceUnavailable:
      return "The Circle media service is unavailable."
    }
  }
}
