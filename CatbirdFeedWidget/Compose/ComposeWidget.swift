//
//  ComposeWidget.swift
//  CatbirdFeedWidget
//

#if os(iOS)
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Compose Widget Intent

@available(iOS 17.0, *)
struct ComposeWidgetIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource { "Compose Widget" }
  static var description: IntentDescription { "Quick compose a new post." }

  @Parameter(title: "Account", description: "Which account to compose from")
  var account: AccountEntity?
}

// MARK: - Compose Entry

struct ComposeWidgetEntry: TimelineEntry {
  let date: Date
  let displayName: String?
  let handle: String?
  let accountDID: String?
}

// MARK: - Compose Provider

@available(iOS 17.0, *)
struct ComposeWidgetProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> ComposeWidgetEntry {
    ComposeWidgetEntry(date: Date(), displayName: nil, handle: nil, accountDID: nil)
  }

  func snapshot(for configuration: ComposeWidgetIntent, in context: Context) async -> ComposeWidgetEntry {
    resolveEntry(for: configuration)
  }

  func timeline(for configuration: ComposeWidgetIntent, in context: Context) async -> Timeline<ComposeWidgetEntry> {
    let entry = resolveEntry(for: configuration)
    return Timeline(entries: [entry], policy: .never)
  }

  private func resolveEntry(for configuration: ComposeWidgetIntent) -> ComposeWidgetEntry {
    let accounts = WidgetDataReader.allAccounts()

    // Use the chosen account while it's still signed in to Catbird.
    if let account = configuration.account,
       let signedIn = accounts.first(where: { $0.did == account.id }) {
      return ComposeWidgetEntry(
        date: Date(),
        displayName: signedIn.displayName,
        handle: signedIn.handle,
        accountDID: signedIn.did
      )
    }

    // Fall back to active account
    let activeDID = WidgetDataReader.activeAccountDID()
    if let activeDID,
       let active = accounts.first(where: { $0.did == activeDID }) {
      return ComposeWidgetEntry(
        date: Date(),
        displayName: active.displayName,
        handle: active.handle,
        accountDID: active.did
      )
    }

    return ComposeWidgetEntry(date: Date(), displayName: nil, handle: nil, accountDID: nil)
  }
}

// MARK: - Compose Widget View

@available(iOS 17.0, *)
struct ComposeWidgetView: View {
  let entry: ComposeWidgetEntry

  var body: some View {
    VStack(spacing: WidgetSpacing.md) {
      WidgetAvatar(name: entry.displayName ?? entry.handle, size: WidgetAvatarSize.xxl)

      Text(entry.accountDID == nil ? "Open Catbird to sign in" : "What’s on your mind?")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Image(systemName: WidgetSymbol.compose)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.blue)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .containerBackground(.clear, for: .widget)
    .widgetURL(composeURL)
  }

  private var composeURL: URL? {
    if let did = entry.accountDID {
      return URL(string: "blue.catbird://compose?account=\(did)")
    }
    return URL(string: "blue.catbird://compose")
  }
}

// MARK: - Compose Widget

@available(iOS 17.0, *)
struct ComposeWidget: Widget {
  let kind = "CatbirdComposeWidget"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: ComposeWidgetIntent.self,
      provider: ComposeWidgetProvider()
    ) { entry in
      ComposeWidgetView(entry: entry)
    }
    .configurationDisplayName("Quick Compose")
    .description("Quickly compose a new post on Bluesky.")
    .supportedFamilies([.systemSmall])
  }
}
#endif
