#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

// Logger for debugging
import os
let logger = Logger(subsystem: "blue.catbird", category: "widget")

// Shared notification data structure
struct NotificationWidgetData: Codable {
  let count: Int
  let lastUpdated: Date
}

// Widget color option to use instead of direct Color value
enum WidgetColorOption: String, AppEnum {
  case blue
  case red
  case green
  case purple
  case orange
  
  static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource("Widget Color", comment: "Type name for the notification widget accent color option.")
  )
  static var caseDisplayRepresentations: [WidgetColorOption: DisplayRepresentation] = [
    .blue: DisplayRepresentation(title: LocalizedStringResource("Blue", comment: "Blue widget accent color option.")),
    .red: DisplayRepresentation(title: LocalizedStringResource("Red", comment: "Red widget accent color option.")),
    .green: DisplayRepresentation(title: LocalizedStringResource("Green", comment: "Green widget accent color option.")),
    .purple: DisplayRepresentation(title: LocalizedStringResource("Purple", comment: "Purple widget accent color option.")),
    .orange: DisplayRepresentation(title: LocalizedStringResource("Orange", comment: "Orange widget accent color option."))
  ]
  
  var color: Color {
    switch self {
    case .blue: return .accentColor
    case .red: return .red
    case .green: return .green
    case .purple: return .purple
    case .orange: return .orange
    }
  }
}

// Widget configuration intent
struct NotificationWidgetIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = LocalizedStringResource(
    "Notification Settings",
    comment: "Title of the configuration intent for the notifications widget."
  )
  
  @Parameter(title: LocalizedStringResource("Accent Color", comment: "Parameter title for selecting the widget accent color."), default: .blue)
  var accentColor: WidgetColorOption
}

// Timeline entry for the widget
struct NotificationEntry: TimelineEntry {
  let date: Date
  let count: Int
  /// When Catbird last saved the unread count; nil when it never has.
  var lastUpdated: Date? = nil
  /// False when no account is signed in to Catbird.
  var isSignedIn: Bool = true
  var configuration: NotificationWidgetIntent
}

// Provider class for the widget timeline
struct Provider: AppIntentTimelineProvider {
    func snapshot(for configuration: NotificationWidgetIntent, in context: Context) async -> NotificationEntry {
        let entry = getNotificationEntry(configuration: configuration)
        // A sample count is only for the widget gallery preview; a real widget never shows one.
        if context.isPreview && entry.lastUpdated == nil {
          return NotificationEntry(date: Date(), count: 3, lastUpdated: Date(), configuration: configuration)
        }
        return entry
    }
    
    func timeline(for configuration: NotificationWidgetIntent, in context: Context) async -> Timeline<NotificationEntry> {
        let entry = getNotificationEntry(configuration: configuration)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
    
  private let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")

  func placeholder(in context: Context) -> NotificationEntry {
    NotificationEntry(date: Date(), count: 0, configuration: NotificationWidgetIntent())
  }
  
  func recommendations() -> [AppIntentRecommendation<NotificationWidgetIntent>] {
    let intent = NotificationWidgetIntent()
    return [AppIntentRecommendation(intent: intent, description: "Notifications")]
  }

  private func getNotificationEntry(configuration: NotificationWidgetIntent) -> NotificationEntry {
    guard let sharedDefaults = sharedDefaults else {
      logger.debug("Widget: Failed to access UserDefaults with suite 'group.blue.catbird.shared'")
      return NotificationEntry(date: Date(), count: 0, isSignedIn: false, configuration: configuration)
    }

    guard sharedDefaults.string(forKey: "activeAccountDID") != nil else {
      logger.debug("Widget: No signed-in account")
      return NotificationEntry(date: Date(), count: 0, isSignedIn: false, configuration: configuration)
    }

    guard let data = sharedDefaults.data(forKey: "notificationWidgetData") else {
      logger.debug("Widget: No notification data found in UserDefaults")
      return NotificationEntry(date: Date(), count: 0, configuration: configuration)
    }

    do {
      let widgetData = try JSONDecoder().decode(NotificationWidgetData.self, from: data)
      logger.debug("Widget found data: count=\(widgetData.count), lastUpdated=\(widgetData.lastUpdated)")
      return NotificationEntry(
        date: Date(),
        count: widgetData.count,
        lastUpdated: widgetData.lastUpdated,
        configuration: configuration
      )
    } catch {
      logger.debug("Widget failed to decode data: \(error.localizedDescription)")
      return NotificationEntry(date: Date(), count: 0, configuration: configuration)
    }
  }
}

// Widget view
struct NotificationWidgetEntryView: View {
  @Environment(\.widgetFamily) var family

  var entry: Provider.Entry

  /// Caption under the big unread count. String catalogs reject plural
  /// variations that leave out the number, so the singular and the plural
  /// caption are separate keys.
  private var unreadCaption: LocalizedStringResource {
    entry.count == 1
      ? LocalizedStringResource("widget.unread.caption.one", defaultValue: "unread notification", comment: "Caption below the large unread notification count in the Home Screen widget, used when the count is exactly 1. The count is shown above it, so the caption has no number.")
      : LocalizedStringResource("widget.unread.caption.other", defaultValue: "unread notifications", comment: "Caption below the large unread notification count in the Home Screen widget, used when the count is anything but 1. The count is shown above it, so the caption has no number.")
  }
  
  private var isLockScreenFamily: Bool {
    family == .accessoryCircular || family == .accessoryInline || family == .accessoryRectangular
  }

  var body: some View {
    Group {
      if family == .systemSmall {
        smallWidgetView
      } else if family == .systemMedium {
        mediumWidgetView
      } else if family == .accessoryCircular {
        circularWidgetView
      } else if family == .accessoryInline {
        Group {
          if entry.isSignedIn {
            Text("Catbird: \(entry.count) unread", comment: "Lock Screen inline widget text showing unread notification count.")
          } else {
            Text("Catbird: Not signed in", comment: "Lock Screen inline widget text when no account is signed in.")
          }
        }
        .notificationWidgetFont(.inlineHeadline)
        .widgetAccentable()
      } else if family == .accessoryRectangular {
        rectangularWidgetView
      } else {
        mediumWidgetView
      }
    }
    .widgetURL(URL(string: "blue.catbird://notifications")!)
    .containerBackground(for: .widget) {
      if isLockScreenFamily {
        Color.clear
      } else {
        NotificationWidgetSurfaceBackground(accentColor: entry.configuration.accentColor.color)
      }
    }
  }

  // Small widget for Home Screen and StandBy
  private var smallWidgetView: some View {
    VStack(spacing: NotificationWidgetSpacing.xs) {
      // Count area with extra large number
      VStack(alignment: .center, spacing: NotificationWidgetSpacing.hairline) {
        Text(verbatim: "Catbird")
          .notificationWidgetFont(.headerSmallCaps)
          .foregroundStyle(.tertiary)
          .textScale(.secondary)
          .multilineTextAlignment(.center)
          .widgetAccentable()
          .minimumScaleFactor(0.8)

        if entry.isSignedIn {
          Text(entry.count, format: .number)
            .notificationWidgetFont(.heroCount)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .widgetAccentable()

          Text(unreadCaption)
            .notificationWidgetFont(.caption)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .widgetAccentable()
        } else {
          signedOutMessage
        }
      }
      .frame(maxWidth: .infinity)

      // Timestamp area
      if let lastUpdated = entry.lastUpdated, entry.isSignedIn {
        Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))", comment: "Relative timestamp in the notification widget — variable is a relative time phrase such as '2 minutes ago'.")
          .notificationWidgetFont(.timestamp)
          .textScale(.secondary)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  // Medium widget for Home Screen
  private var mediumWidgetView: some View {
    HStack(spacing: NotificationWidgetSpacing.xl) {
      // Left section with icon and title
      VStack(alignment: .leading, spacing: NotificationWidgetSpacing.xs) {
        Text("Notifications", comment: "Header title in the medium Home Screen notifications widget.")
          .notificationWidgetFont(.headerSmallCaps)
          .foregroundStyle(.secondary)
          .widgetAccentable()
          .minimumScaleFactor(0.8)

        Spacer()

        if let lastUpdated = entry.lastUpdated, entry.isSignedIn {
          Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))", comment: "Relative timestamp in the notification widget — variable is a relative time phrase such as '2 minutes ago'.")
            .notificationWidgetFont(.timestamp)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }

      // Right section with large count
      VStack(alignment: .trailing) {
        if entry.isSignedIn {
          Text(entry.count, format: .number)
            .notificationWidgetFont(.heroCount)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .widgetAccentable()

          Text(unreadCaption)
            .notificationWidgetFont(.caption)
            .foregroundStyle(.secondary)
            .widgetAccentable()
            .minimumScaleFactor(0.8)
        } else {
          signedOutMessage
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(NotificationWidgetSpacing.lg)
  }

  // Circular widget for Lock Screen
  private var circularWidgetView: some View {
    VStack(spacing: 0) {
      // Icon area
      Image(systemName: "bell.badge.fill")
        .notificationWidgetFont(.circularIcon)
        .widgetAccentable()

      // Count with large font
      if entry.isSignedIn {
        Text(entry.count, format: .number)
          .notificationWidgetFont(.circularCount)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .widgetAccentable()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(countAccessibilityLabel))
  }

  private var countAccessibilityLabel: String {
    guard entry.isSignedIn else {
      return String(localized: "Not signed in to Catbird", comment: "Accessibility label for the notification widget when no account is signed in.")
    }
    return String(localized: "\(entry.count) unread notifications", comment: "Accessibility label for the notification widget showing unread notification count.")
  }

  // Rectangular widget for Lock Screen
  private var rectangularWidgetView: some View {
    HStack(spacing: NotificationWidgetSpacing.sm) {
      // Icon area
      Image(systemName: "bell.badge.fill")
        .notificationWidgetFont(.rectangularIcon)
        .widgetAccentable()

      if entry.isSignedIn {
        Text("**\(entry.count)** unread notifications", comment: "Lock Screen rectangular widget label showing unread notification count.")
          .notificationWidgetFont(.rectangularBody)
          .widgetAccentable()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      } else {
        Text("Open Catbird to sign in", comment: "Prompt shown in the notification widget when no account is signed in.")
          .notificationWidgetFont(.rectangularBody)
          .widgetAccentable()
          .lineLimit(2)
          .minimumScaleFactor(0.8)
      }
    }
  }

  // Shown in place of the count when no account is signed in
  private var signedOutMessage: some View {
    Text("Open Catbird to sign in", comment: "Prompt shown in the notification widget when no account is signed in.")
      .notificationWidgetFont(.signedOut)
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .minimumScaleFactor(0.8)
  }
}

// Widget configuration
struct CatbirdNotificationWidget: Widget {
  private let kind = "CatbirdNotificationWidget"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: NotificationWidgetIntent.self,
      provider: Provider()
    ) { entry in
      NotificationWidgetEntryView(entry: entry)
    }
    .configurationDisplayName(Text("Notifications", comment: "Widget gallery display name for the notifications widget."))
    .description(Text("Shows your unread Bluesky notifications.", comment: "Widget gallery description for the notifications widget."))
    .supportedFamilies([
      .systemSmall,
      .systemMedium,
      .accessoryInline,
      .accessoryCircular,
      .accessoryRectangular
    ])
  }
}

// Preview
#Preview("Notification Widget", as: .systemSmall) {
  CatbirdNotificationWidget()
} timeline: {
  NotificationEntry(date: Date(), count: 8, configuration: NotificationWidgetIntent())
}

#Preview("Notification Widget", as: .accessoryCircular) {
  CatbirdNotificationWidget()
} timeline: {
  NotificationEntry(date: Date(), count: 5, configuration: NotificationWidgetIntent())
}
#endif
