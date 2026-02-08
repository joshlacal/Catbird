import CatbirdMLSService
//
//  MLSGroupedMember.swift
//  Catbird
//
//  Created by Claude Code on 11/25/24.
//

import Foundation
import Petrel

/// Represents a user's presence in an MLS conversation, grouping all their devices together
struct MLSGroupedMember: Identifiable, Equatable {
    let userDid: String
    let devices: [BlueCatbirdMlsDefs.MemberView]
    let isAdmin: Bool
    let isCreator: Bool
    let firstJoinedAt: Date

    var id: String { userDid }
    var deviceCount: Int { devices.count }
    var primaryDevice: BlueCatbirdMlsDefs.MemberView? { devices.first }
}
