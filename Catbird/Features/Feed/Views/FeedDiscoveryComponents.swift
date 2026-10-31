import Petrel
import SwiftUI

struct FeedDiscoveryDetailsView: View {
  let feed: AppBskyFeedDefs.GeneratorView
  @Binding var path: NavigationPath
  let onPreview: () -> Void

  var body: some View {
    List {
      Section {
        FeedDiscoveryIdentity(feed: feed)
      }
      Section("About") {
        if let description = feed.description, !description.isEmpty {
          Text(description)
            .appFont(AppTextRole.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("This feed has no description.").foregroundStyle(.secondary)
        }
      }
      Section {
        NavigationLink(value: NavigationDestination.profile(feed.creator.did.didString())) {
          Label("View creator", systemImage: "person.crop.circle")
        }
      }
    }
    .navigationTitle("Feed details")
    .modifier(BrowseFeedToolbar(action: onPreview))
  }
}

/// Browse Feed is the screen's one primary action, so it sits in the bottom bar
/// as a prominent Liquid Glass button on iOS 26 rather than inside the list.
private struct BrowseFeedToolbar: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    #if os(iOS)
    content.toolbar {
      ToolbarItem(placement: .bottomBar) { button }
    }
    #else
    content.toolbar {
      ToolbarItem(placement: .primaryAction) { button }
    }
    #endif
  }

  @ViewBuilder private var button: some View {
    #if compiler(>=6.2)
    if #available(iOS 26.0, macOS 26.0, *) {
      Button("Browse Feed", action: action)
        .buttonStyle(.glassProminent)
    } else {
      Button("Browse Feed", action: action)
        .buttonStyle(.borderedProminent)
    }
    #else
    Button("Browse Feed", action: action)
      .buttonStyle(.borderedProminent)
    #endif
  }
}

struct FeedDiscoveryIdentity: View {
  let feed: AppBskyFeedDefs.GeneratorView
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
    layout {
      DiscoveryFeedAvatar(feed: feed, size: 40)
      VStack(alignment: .leading, spacing: 4) {
        Text(feed.displayName)
          .appFont(AppTextRole.headline)
          .fixedSize(horizontal: false, vertical: true)
        Text("by @\(feed.creator.handle.description)")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DiscoveryFeedAvatar: View {
  let feed: AppBskyFeedDefs.GeneratorView
  let size: CGFloat

  var body: some View {
    AsyncImage(url: feed.avatar.flatMap { URL(string: $0.uriString()) }) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Image(systemName: "square.stack.fill")
        .resizable().scaledToFit()
        .padding(size * 0.22)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.12))
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    .accessibilityHidden(true)
  }
}

struct FeedDiscoveryRetryView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Try Again", action: retry)
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }
    .accessibilityElement(children: .contain)
  }
}
