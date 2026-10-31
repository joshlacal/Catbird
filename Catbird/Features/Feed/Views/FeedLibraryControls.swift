import SwiftUI
import Petrel

/// Library membership controls shared by search, discovery and the feed preview.
struct FeedLibraryControls: View {
  @Environment(AppState.self) private var appState
  let feed: AppBskyFeedDefs.GeneratorView
  var onOpen: (() -> Void)? = nil
  var compactLabels = false
  var alignsTrailing = false
  var prominent = false
  /// Label height inside the bordered control; the bezel adds about 14 pt, so a
  /// value near 30 still yields a 44 pt control.
  var minimumLabelHeight: CGFloat = 44
  /// Draws Saved/Pinned as a tinted capsule so library status reads as state, not a link.
  var statusChip = false
  @State private var showExplanation = false

  private var actions: FeedLibraryActions { appState.feedLibraryActions }
  private var membership: FeedLibraryMembership { actions.membership(for: feed.uri) }
  private var state: FeedLibraryActionState { actions.state(for: feed.uri) }
  private let education = FeedDiscoveryEducationStore()

  var body: some View {
    VStack(alignment: alignsTrailing ? .trailing : .leading, spacing: 6) {
      if state == .saving {
        ProgressView("Saving")
          .font(.caption)
          .accessibilityLabel("Saving \(feed.displayName)")
      } else if membership == .absent {
        Button { perform(.saved) } label: {
          Label {
            if prominent { Text("Add \(feed.displayName)") } else { Text("Add") }
          } icon: {
            Image(systemName: "plus")
          }
            .labelStyle(FeedLibraryActionLabelStyle(compact: compactLabels))
            .frame(minWidth: 44, minHeight: minimumLabelHeight)
            .frame(maxWidth: prominent ? .infinity : nil)
            .lineLimit(prominent ? 2 : nil)
        }
        .modifier(FeedLibraryButtonPresentation(prominent: prominent))
        .accessibilityLabel("Add \(feed.displayName) to Saved")
        .accessibilityIdentifier("feed.library.add.\(feed.uri.uriString())")
      } else {
        Menu {
          if membership == .saved {
            Button { perform(.pinned) } label: {
              Label("Pin to Feeds", systemImage: "pin")
            }
          }
          if let onOpen {
            Button("Open Feed", systemImage: "arrow.up.forward", action: onOpen)
          }
          Button(role: .destructive) { perform(nil) } label: {
            Label("Remove from Library", systemImage: "trash")
          }
        } label: {
          Label {
            if membership == .pinned { Text("Pinned") } else { Text("Saved") }
          } icon: {
            Image(systemName: membership == .pinned ? "pin.fill" : "checkmark")
          }
            .labelStyle(FeedLibraryActionLabelStyle(compact: compactLabels))
            .frame(minWidth: 44, minHeight: minimumLabelHeight)
            .frame(maxWidth: prominent ? .infinity : nil)
            .modifier(FeedLibraryStatusChip(enabled: statusChip))
        }
        .modifier(FeedLibraryButtonPresentation(prominent: prominent, drawsChrome: !statusChip))
        .accessibilityLabel("\(feed.displayName), \(membership == .pinned ? "Pinned" : "Saved"). Manage feed")
        .accessibilityIdentifier("feed.library.manage.\(feed.uri.uriString())")
      }
      feedback
    }
    .fixedSize(horizontal: false, vertical: true)
    .alert("Saved and Pinned", isPresented: $showExplanation) {
      Button("Got it") { education.acknowledge(accountDID: appState.userDID) }
    } message: {
      Text("Saved keeps a feed in your library. Pin to Feeds adds it to your pinned feeds without changing your default feed.")
    }
  }

  @ViewBuilder private var feedback: some View {
    switch state {
    case .pendingSync:
      Text("Saved on this device. It will sync when you’re back online.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button(action: retry) {
        Text("Try Again").font(.caption).frame(minHeight: 44)
      }
    case .failed(let message):
      Text(message).font(.caption).foregroundStyle(.red)
      Button(action: retry) {
        Text("Try Again").font(.caption).frame(minHeight: 44)
      }
    case .success(.saved):
      Text("Added to Saved").font(.caption).foregroundStyle(.secondary)
    case .success(.pinned):
      Text("Pinned to Feeds").font(.caption).foregroundStyle(.secondary)
    default:
      EmptyView()
    }
  }

  private func retry() {
    Task { @MainActor in
      do {
        try await actions.retry(feed.uri)
        if membership != .absent && !education.hasAcknowledged(accountDID: appState.userDID) {
          showExplanation = true
        }
      } catch {}
    }
  }

  private func perform(_ destination: FeedLibraryDestination?) {
    Task { @MainActor in
      do {
        if let destination {
          _ = try await actions.add(feed.uri, to: destination)
          if !education.hasAcknowledged(accountDID: appState.userDID) { showExplanation = true }
        } else {
          try await actions.remove(feed.uri)
        }
      } catch {
        // FeedLibraryActions retains the per-feed error and local sync status.
      }
    }
  }
}

private struct FeedLibraryButtonPresentation: ViewModifier {
  let prominent: Bool
  var drawsChrome = true

  @ViewBuilder func body(content: Content) -> some View {
    if !drawsChrome {
      content.buttonStyle(.plain)
    } else if prominent {
      content
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .appFont(AppTextRole.headline)
    } else {
      content.buttonStyle(.bordered)
    }
  }
}

/// A tinted capsule around the Saved/Pinned menu label. Menus don't adopt bordered
/// button styles, so the chip is drawn explicitly.
private struct FeedLibraryStatusChip: ViewModifier {
  let enabled: Bool

  @ViewBuilder func body(content: Content) -> some View {
    if enabled {
      content
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    } else {
      content
    }
  }
}

/// Only the resting control collapses to an icon; menu items keep their titles.
private struct FeedLibraryActionLabelStyle: LabelStyle {
  let compact: Bool

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    if compact {
      configuration.icon
    } else {
      HStack(spacing: 6) {
        configuration.icon
        configuration.title
      }
    }
  }
}
