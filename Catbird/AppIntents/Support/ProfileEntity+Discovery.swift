//
//  ProfileEntity+Discovery.swift
//  Catbird
//
//  Extends ProfileEntity with URL representation and Transferable support.
//  URLRepresentableEntity works here because ProfileEntity.id is a plain `let`,
//  not a @Property wrapper — string interpolation in URLRepresentation requires
//  a simple stored property, not a property-wrapper binding.
//

import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation

@available(iOS 18.0, *)
extension ProfileEntity: URLRepresentableEntity {
  static var urlRepresentation: URLRepresentation { "https://bsky.app/profile/\(.id)" }
}

@available(iOS 18.0, *)
extension ProfileEntity {
  var attributeSet: CSSearchableItemAttributeSet {
    let set = defaultAttributeSet
    set.contentDescription = description
    set.keywords = [handle, displayName].compactMap { $0 }
    return set
  }
}

@available(iOS 18.0, *)
extension ProfileEntity: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation(exporting: { entity in
      entity.displayName ?? "@\(entity.handle)"
    })
  }
}
