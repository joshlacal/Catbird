//
//  CountFormatter.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/27/24.
//


import Foundation

struct CountFormatter {
    static func format(_ count: Int) -> String {
        if count < 1000 {
            return "\(count)"
        }
        
        let thousand = 1000.0
        let million = thousand * 1000
        let billion = million * 1000
        
        let number = Double(count)
        
        switch number {
        case billion...:
            return String(format: "%.1fB", number / billion)
                .replacingOccurrences(of: ".0", with: "")
        case million...:
            return String(format: "%.1fM", number / million)
                .replacingOccurrences(of: ".0", with: "")
        case thousand...:
            return String(format: "%.1fK", number / thousand)
                .replacingOccurrences(of: ".0", with: "")
        default:
            return "\(count)"
        }
    }
}

// Extension to make it easy to use
extension Int {
    var formatted: String {
        CountFormatter.format(self)
    }
}
