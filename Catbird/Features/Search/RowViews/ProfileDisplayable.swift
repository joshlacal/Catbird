//
//  ProfileDisplayable.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// Protocol for any profile-like object that can be displayed in a row
protocol ProfileDisplayable {
    var did: DID { get }
    var handle: Handle { get }
    var displayName: String? { get }
    var avatar: URI? { get }
    
    func finalAvatarURL() -> URL?
}

/// Conformance for ProfileViewDetailed
extension AppBskyActorDefs.ProfileViewDetailed: ProfileDisplayable {}

/// Conformance for ProfileView
extension AppBskyActorDefs.ProfileView: ProfileDisplayable {}

/// Conformance for ProfileViewBasic
extension AppBskyActorDefs.ProfileViewBasic: ProfileDisplayable {}


