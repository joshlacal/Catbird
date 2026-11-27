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
  static var title: LocalizedStringResource {
    LocalizedStringResource(
      "Compose Widget",
      comment: "Title for the Quick Compose widget configuration intent."
    )
  }
  static var description: IntentDescription {
    IntentDescription(
      LocalizedStringResource(
        "Quick compose a new post.",
        comment: "Description for the Quick Compose widget configuration intent."
      )
    )
  }

  @Parameter(
    title: LocalizedStringResource(
      "Account",
      comment: "Widget configuration parameter for selecting which Bluesky account composes the post."
    ),
    description: LocalizedStringResource(
      "Which account to compose from",
      comment: "Description for the Account parameter of the Quick Compose widget."
    )
  )
  var account: AccountEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Compose from \(\.$account)")
  }
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

  private var promptText: LocalizedStringResource {
    if entry.accountDID == nil {
      return LocalizedStringResource(
        "Open Catbird to sign in",
        comment: "Prompt in the Quick Compose widget when no Bluesky account is signed in."
      )
    }
    return LocalizedStringResource(
      "What’s on your mind?",
      comment: "Compose prompt in the Quick Compose home-screen widget."
    )
  }

  var body: some View {
    VStack(spacing: WidgetSpacing.sm) {
      WidgetAvatar(name: entry.displayName ?? entry.handle, size: WidgetAvatarSize.xxl)

      Text(promptText)
        .widgetFont(.body, weight: .medium)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Image(systemName: WidgetSymbol.compose)
        .widgetFont(.iconCompact, weight: .medium)
        .foregroundStyle(Color.accentColor)
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
    .configurationDisplayName(
      LocalizedStringResource(
        "Quick Compose",
        comment: "Widget gallery display name for the Quick Compose widget."
      )
    )
    .description(
      LocalizedStringResource(
        "Quickly compose a new post on Bluesky.",
        comment: "Widget gallery description for the Quick Compose widget."
      )
    )
    .supportedFamilies([.systemSmall])
  }
}
#endif
