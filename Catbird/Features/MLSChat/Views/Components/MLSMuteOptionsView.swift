import SwiftUI

// MARK: - Mute Duration

/// Available mute durations for conversations
enum MuteDuration: CaseIterable, Identifiable {
  case oneHour
  case eightHours
  case oneDay
  case oneWeek
  case forever

  var id: String {
    switch self {
    case .oneHour: "1h"
    case .eightHours: "8h"
    case .oneDay: "1d"
    case .oneWeek: "1w"
    case .forever: "forever"
    }
  }

  var label: String {
    switch self {
    case .oneHour: String(localized: "1 Hour", comment: "Mute conversation notifications for 1 hour")
    case .eightHours: String(localized: "8 Hours", comment: "Mute conversation notifications for 8 hours")
    case .oneDay: String(localized: "1 Day", comment: "Mute conversation notifications for 1 day")
    case .oneWeek: String(localized: "1 Week", comment: "Mute conversation notifications for 1 week")
    case .forever: String(localized: "Forever", comment: "Mute conversation notifications indefinitely")
    }
  }

  var iconName: String {
    switch self {
    case .oneHour: "clock"
    case .eightHours: "clock.badge.fill"
    case .oneDay: "sun.max"
    case .oneWeek: "calendar"
    case .forever: "bell.slash"
    }
  }

  /// Returns the Date when the mute expires, or `.distantFuture` for forever
  var mutedUntilDate: Date {
    let now = Date()
    switch self {
    case .oneHour: return now.addingTimeInterval(3600)
    case .eightHours: return now.addingTimeInterval(3600 * 8)
    case .oneDay: return now.addingTimeInterval(86400)
    case .oneWeek: return now.addingTimeInterval(86400 * 7)
    case .forever: return .distantFuture
    }
  }
}

// MARK: - MLSMuteOptionsView

/// Presents mute duration options for a conversation.
/// Shows an unmute option when the conversation is currently muted.
struct MLSMuteOptionsView: View {
  let isMuted: Bool
  let onMute: (Date?) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if isMuted {
          Section {
            Button {
              onMute(nil)
              dismiss()
            } label: {
              Label("Unmute", systemImage: "bell")
            }
          }
        }

        Section(isMuted ? "Change Duration" : "Mute Notifications") {
          ForEach(MuteDuration.allCases) { duration in
            Button {
              onMute(duration.mutedUntilDate)
              dismiss()
            } label: {
              Label(duration.label, systemImage: duration.iconName)
            }
          }
        }
      }
      .navigationTitle("Notifications")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }
}
