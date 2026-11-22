//
//  CountFormatter.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/27/24.
//

import Foundation

struct CountFormatter {
  static func format(_ count: Int, locale: Locale = .current) -> String {
    count.formatted(
      .number
        .notation(.compactName)
        .precision(.fractionLength(0...1))
        .locale(locale)
    )
  }
}

// Extension to make it easy to use
extension Int {
    var formatted: String {
        CountFormatter.format(self)
    }
}
