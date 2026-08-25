//
//  CircleNotificationService.swift
//  Catbird
//

import Foundation
import Petrel
import PetrelCatbird

/// Protocol for private Circle notification fetching and refresh operations.
protocol CircleNotificationServiceProtocol: Sendable {
  func listNotifications(cursor: String?) async throws -> CircleNotificationPage
  func refresh() async throws -> CircleNotificationPage
}

/// Production implementation of CircleNotificationService over the generated gateway client.
actor CircleNotificationService: CircleNotificationServiceProtocol {
  private let service: CircleService

  init(service: CircleService) {
    self.service = service
  }

  func listNotifications(cursor: String? = nil) async throws -> CircleNotificationPage {
    try await service.listNotifications(cursor: cursor)
  }

  func refresh() async throws -> CircleNotificationPage {
    try await service.listNotifications(cursor: nil)
  }
}
