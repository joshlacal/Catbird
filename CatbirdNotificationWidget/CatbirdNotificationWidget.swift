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
  
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget Color"
  static var caseDisplayRepresentations: [WidgetColorOption: DisplayRepresentation] = [
    .blue: "Blue",
    .red: "Red",
    .green: "Green",
    .purple: "Purple",
    .orange: "Orange"
  ]
  
  var color: Color {
    switch self {
    case .blue: return .blue
    case .red: return .red
    case .green: return .green
    case .purple: return .purple
    case .orange: return .orange
    }
  }
}

// Widget configuration intent
struct NotificationWidgetIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource = "Notification Settings"
  
  @Parameter(title: "Accent Color", default: .blue)
  var accentColor: WidgetColorOption
}

// Timeline entry for the widget
struct NotificationEntry: TimelineEntry {
  let date: Date
  let count: Int
  var configuration: NotificationWidgetIntent
}

// Provider class for the widget timeline
struct Provider: AppIntentTimelineProvider {
    func snapshot(for configuration: NotificationWidgetIntent, in context: Context) async -> NotificationEntry {
        return getNotificationEntry(configuration: configuration)
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
      if let sharedDefaults = sharedDefaults {
        if let data = sharedDefaults.data(forKey: "notificationWidgetData") {
          do {
            let widgetData = try JSONDecoder().decode(NotificationWidgetData.self, from: data)
            logger.debug("Widget found data: count=\(widgetData.count), lastUpdated=\(widgetData.lastUpdated)")
            return NotificationEntry(date: Date(), count: widgetData.count, configuration: configuration)
          } catch {
            logger.debug("Widget failed to decode data: \(error.localizedDescription)")
            return NotificationEntry(date: Date(), count: 5, configuration: configuration)
          }
        } else {
          logger.debug("Widget: No notification data found in UserDefaults")
          return NotificationEntry(date: Date(), count: 3, configuration: configuration)
        }
      } else {
        logger.debug("Widget: Failed to access UserDefaults with suite 'group.blue.catbird.shared'")
        return NotificationEntry(date: Date(), count: 7, configuration: configuration)
      }
  }
}

// Widget view
struct NotificationWidgetEntryView: View {
  @Environment(\.widgetFamily) var family
  @Environment(\.colorScheme) var colorScheme

  var entry: Provider.Entry
  
  var body: some View {
    Group {
      if family == .systemSmall {
        smallWidgetView
      } else if family == .systemMedium {
        mediumWidgetView
      } else if family == .accessoryCircular {
        circularWidgetView
      } else if family == .accessoryInline {
        Text("Catbird: \(entry.count) unread")
          .font(.headline)
          .widgetAccentable()
      } else if family == .accessoryRectangular {
        rectangularWidgetView
      } else {
        mediumWidgetView
      }
    }
    .widgetURL(URL(string: "blue.catbird://notifications")!)
    .containerBackground(for: .widget) {
      LinearGradient(
        colors: [
          entry.configuration.accentColor.color.opacity(0.9),
          entry.configuration.accentColor.color.opacity(0.6)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .overlay {
        Color(colorScheme == .dark ? .black : .white)
          .opacity(0.7)
      }
    }
  }

  // Small widget for Home Screen and StandBy
  private var smallWidgetView: some View {
    VStack(spacing: 3) {
      
      // Count area with extra large number
      VStack(alignment: .center, spacing: 2) {
          
          Text("bluesky")
              .font(.system(.headline, design: .rounded, weight: .heavy).lowercaseSmallCaps())
              .foregroundStyle(.tertiary)
              .textScale(.secondary)
              .multilineTextAlignment(.center)
            .widgetAccentable()
            .minimumScaleFactor(0.8)

        Text("\(entry.count)")
              .font(.system(size: 75, weight: .bold, design: .rounded))
          .minimumScaleFactor(0.5)
          .lineLimit(1)
          .widgetAccentable()
          .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
        
          Text(entry.count == 1 ? "unread notification" : "unread notifications")
              .font(.system(.caption, design: .rounded))
              .lineLimit(nil)
              .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .widgetAccentable()
      }
      .frame(maxWidth: .infinity)
      
      // Timestamp area
      Text("Updated \(entry.date.formatted(.relative(presentation: .named)))")
        .font(.system(.caption2, design: .rounded))
        .textScale(.secondary)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .containerBackground(for: .widget, content: {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThickMaterial)
            .padding(2)
    })
  }

  // Medium widget for Home Screen
  private var mediumWidgetView: some View {
    HStack(spacing: 20) {
      // Left section with icon and title
      VStack(alignment: .leading, spacing: 4) {

        Text("bluesky notifications")
              .font(.system(.headline, design: .rounded, weight: .heavy).lowercaseSmallCaps())
          .foregroundStyle(.secondary)
          .widgetAccentable()
          .minimumScaleFactor(0.8)
          
        Spacer()
        
        Text("Updated \(entry.date.formatted(.relative(presentation: .named)))")
          .font(.system(.caption2, design: .rounded))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      
      // Right section with large count
      VStack(alignment: .trailing) {
        Text("\(entry.count)")
          .font(.system(size: 75, weight: .bold, design: .rounded))
          .minimumScaleFactor(0.6)
          .lineLimit(1)
          .widgetAccentable()
          .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
          
        Text(entry.count == 1 ? "unread notification" : "unread notifications")
          .font(.system(.caption, design: .rounded))
          .foregroundStyle(.secondary)
          .widgetAccentable()
          .minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
    .containerBackground(for: .widget, content: {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThickMaterial)
            .padding(2)
    })

  }

  // Circular widget for Lock Screen
  private var circularWidgetView: some View {
    VStack(spacing: 0) {
      // Icon area
      Image(systemName: "bell.badge.fill")
        .font(.system(size: 20))
        .widgetAccentable()
      
      // Count with large font
      Text("\(entry.count)")
        .font(.system(size: 24, weight: .bold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .widgetAccentable()
    }
  }

  // Rectangular widget for Lock Screen
  private var rectangularWidgetView: some View {
    HStack {
      // Icon area
      Image(systemName: "bell.badge.fill")
        .font(.system(size: 18))
        .widgetAccentable()
      
      // Count with large, prominent text
      Text("\(entry.count) unread")
        .font(.system(.body, design: .rounded))
        .fontWeight(.bold)
        .widgetAccentable()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        
      Text("notifications")
        .font(.system(.body, design: .rounded))
        .widgetAccentable()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
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
    .configurationDisplayName("Notifications")
    .description("Shows your unread bluesky notifications.")
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
