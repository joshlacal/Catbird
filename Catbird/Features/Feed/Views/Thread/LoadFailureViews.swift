//
//  LoadFailureViews.swift
//  Catbird
//

import SwiftUI

/// Recovery copy for thread and interaction-list load failures. Raw error
/// details belong in the log, never on screen.
enum LoadFailureCopy {
  static func suggestion(for error: Error) -> String {
    suggestion(for: UserFacingError.kind(of: error))
  }

  static func suggestion(for kind: UserFacingError.Kind) -> String {
    switch kind {
    case .offline:
      return String(localized: "Check your connection and try again.", comment: "Recovery suggestion when loading fails due to being offline")
    case .timedOut:
      return String(localized: "The server took too long to respond. Try again.", comment: "Recovery suggestion when a request times out")
    case .rateLimited:
      return String(localized: "Wait a moment and try again.", comment: "Recovery suggestion when rate limited")
    case .signInRequired:
      return String(localized: "Sign in again and try again.", comment: "Recovery suggestion when authentication has expired")
    case .server:
      return String(localized: "The server is having trouble right now. Try again later.", comment: "Recovery suggestion when the server returns an error")
    case .notFound:
      return String(localized: "This post may have been deleted.", comment: "Recovery suggestion when a post is not found")
    case .cancelled, .notAllowed, .other:
      return String(localized: "Something went wrong. Try again.", comment: "Generic recovery suggestion when loading fails")
    }
  }

  static func systemImage(for error: Error) -> String {
    UserFacingError.kind(of: error) == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle"
  }
}

/// Full-screen state shown when the first page of a list fails to load.
struct ListLoadFailureView: View {
  let title: LocalizedStringKey
  let error: Error
  let onRetry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: LoadFailureCopy.systemImage(for: error))
    } description: {
      Text(LoadFailureCopy.suggestion(for: error))
    } actions: {
      Button("Try Again", action: onRetry)
        .buttonStyle(.borderedProminent)
    }
  }
}

/// Inline row shown when a later page fails, so already-loaded rows stay visible.
struct ListPageFailureRow: View {
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Text("Couldn’t load more.")
        .appFont(AppTextRole.footnote)
        .foregroundStyle(Color.secondary)
        .multilineTextAlignment(.center)
      Button("Try Again", action: onRetry)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }
}
