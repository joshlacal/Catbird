import SwiftUI
import WidgetKit

// Basic timeline entry with just date
struct BasicEntry: TimelineEntry {
  let date: Date
}

// Basic provider with no dependencies
struct BasicProvider: TimelineProvider {
  func placeholder(in context: Context) -> BasicEntry {
    BasicEntry(date: Date())
  }

  func getSnapshot(in context: Context, completion: @escaping (BasicEntry) -> Void) {
    completion(BasicEntry(date: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<BasicEntry>) -> Void) {
    let entry = BasicEntry(date: Date())
    let timeline = Timeline(entries: [entry], policy: .never)
    completion(timeline)
  }
}

// Simple test widget view
struct SimpleWidgetView: View {
  var entry: BasicProvider.Entry

  var body: some View {
    ZStack {
      Color(uiColor: .systemBackground)

      VStack(spacing: 10) {
        Text("Catbird Widget")
          .font(.headline)

        Text("42")
          .font(.system(size: 36, weight: .bold))
          .foregroundStyle(.blue)

        Text("unread notifications")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
    }
  }
}

// The final static test widget that doesn't depend on any data
struct SimpleTestWidget: Widget {
  private let kind = "SimpleTestWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: kind,
      provider: BasicProvider()
    ) { entry in
      SimpleWidgetView(entry: entry)
    }
    .configurationDisplayName("Catbird Notifications")
    .description("Shows your unread notifications")
    .supportedFamilies([.systemSmall])
  }
}
