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
}
