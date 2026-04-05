import SwiftUI

// MARK: - Mute Duration

/// Available mute durations for conversations
enum MuteDuration: CaseIterable, Identifiable {
  case oneHour
  case eightHours
  case oneDay
  case oneWeek
  case forever

  var id: String { label }

  var label: String {
    switch self {
    case .oneHour: "1 Hour"
    case .eightHours: "8 Hours"
    case .oneDay: "1 Day"
    case .oneWeek: "1 Week"
    case .forever: "Forever"
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
