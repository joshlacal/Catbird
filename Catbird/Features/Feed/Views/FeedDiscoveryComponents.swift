import Petrel
import SwiftUI

struct FeedDiscoveryDetailsView: View {
  let feed: AppBskyFeedDefs.GeneratorView
  @Binding var path: NavigationPath
  let onPreview: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        FeedDiscoveryIdentity(feed: feed)
        if let description = feed.description, !description.isEmpty {
          Text(description)
            .appFont(AppTextRole.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("This feed has no description.").foregroundStyle(.secondary)
        }
        Button {
          path.append(NavigationDestination.profile(feed.creator.did.didString()))
        } label: {
          Label("View creator", systemImage: "person.crop.circle")
            .frame(minHeight: 44)
        }
        Button("Browse Feed", action: onPreview)
          .buttonStyle(.borderedProminent)
          .frame(minHeight: 44)
      }
      .frame(maxWidth: 700, alignment: .leading)
      .padding(16)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Feed details")
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
