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

        // Round before choosing the unit so 999,950 reads "1M", not "1000K".
        let suffixes = ["K", "M", "B"]
        var suffixIndex = 0
        var value = Double(count) / 1000
        var rounded = (value * 10).rounded() / 10
        while rounded >= 1000 && suffixIndex < suffixes.count - 1 {
            value /= 1000
            suffixIndex += 1
            rounded = (value * 10).rounded() / 10
        }

        let number = rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
        return number + suffixes[suffixIndex]
    }
}

// Extension to make it easy to use
extension Int {
    var formatted: String {
        CountFormatter.format(self)
    }
}
