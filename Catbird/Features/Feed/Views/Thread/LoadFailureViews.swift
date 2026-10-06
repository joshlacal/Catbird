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
    case .offline: return "Check your connection and try again."
    case .timedOut: return "The server took too long to respond. Try again."
    case .rateLimited: return "Wait a moment and try again."
    case .signInRequired: return "Sign in again and try again."
    case .server: return "The server is having trouble right now. Try again later."
    case .notFound: return "This post may have been deleted."
    case .cancelled, .notAllowed, .other: return "Something went wrong. Try again."
    }
  }

  static func systemImage(for error: Error) -> String {
    UserFacingError.kind(of: error) == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle"
  }
}

/// Full-screen state shown when the first page of a list fails to load.
struct ListLoadFailureView: View {
  let title: String
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
