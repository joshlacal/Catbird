//
//  AlertItem.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/28/25.
//

import Foundation

struct AlertItem: Identifiable {
  let id = UUID()
  let title: String
  let message: String

  init(title: String, message: String) {
    self.title = title
    self.message = message
  }

  init(title: LocalizedStringResource, message: LocalizedStringResource) {
    self.title = String(localized: title)
    self.message = String(localized: message)
  }
}
