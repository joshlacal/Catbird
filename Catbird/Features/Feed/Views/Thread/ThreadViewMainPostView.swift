import NukeUI
import Petrel
import SwiftUI

struct ThreadViewMainPostView: View {
  let post: AppBskyFeedDefs.PostView
  let showLine: Bool
  let appState: AppState
  @Binding var path: NavigationPath
  @Environment(\.colorScheme) var colorScheme
  @State private var viewModel: PostViewModel

  // Using multiples of 3 for spacing
  private static let baseUnit: CGFloat = 3
  private static let avatarSize: CGFloat = 48
  private static let avatarContainerWidth: CGFloat = 54

  private static let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium  // Shows month, day, year
    formatter.timeStyle = .short  // Shows hour and minute

    // If you specifically want the day of week included:
    formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"  // e.g. "Thursday, Feb 27, 2025 at 2:30 PM"

    return formatter
  }()

  init(
    post: AppBskyFeedDefs.PostView, showLine: Bool, path: Binding<NavigationPath>,
    appState: AppState
  ) {
    self.post = post
    self.showLine = showLine
    self._path = path
    _viewModel = State(initialValue: PostViewModel(post: post, appState: appState))
    self.appState = appState
  }

  private var authorAvatarColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
        LazyImage(url: post.author.finalAvatarURL()) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(1, contentMode: .fill)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())
            .contentShape(Circle())
//            .overlay(
//              Circle()
//                .inset(by: -1.5)
//                .stroke(colorScheme == .dark ? Color.black : Color.white, lineWidth: 3)
//            )
        } else {
          Image(systemName: "person.circle.fill")
            .foregroundColor(.gray)
            .appFont(size: 60)
        }
      }
      .onTapGesture {
          path.append(NavigationDestination.profile(post.author.did.didString()))
      }

    }
    .frame(maxHeight: .infinity, alignment: .top)
    .frame(width: Self.avatarContainerWidth)
    .padding(.horizontal, ThreadViewMainPostView.baseUnit)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {

      VStack(alignment: .leading, spacing: 0) {
        if case let .knownType(postObj) = post.record {
          if let feedPost = postObj as? AppBskyFeedPost {
            HStack(alignment: .center, spacing: 0) {
              authorAvatarColumn

              VStack(alignment: .leading, spacing: 0) {
                  Text((post.author.displayName ?? post.author.handle.description).truncated(to: 30))
                      .lineLimit(1, reservesSpace: true)
                  .appHeadline()
                  .themedText(appState.themeManager, style: .primary, appSettings: appState.appSettings)
                  .truncationMode(.tail)
                  .allowsTightening(true)
                  .fixedSize(horizontal: true, vertical: false)
                  .padding(.bottom, 1)
                  .transaction { $0.animation = nil }
                  .contentTransition(.identity)

                Text("@\(post.author.handle)".truncated(to: 30))
                  .appSubheadline()
                  .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
                  .lineLimit(1)
                  .truncationMode(.tail)
                  .allowsTightening(true)
                  .fixedSize(horizontal: true, vertical: false)
                  .padding(.bottom, 1)
                  .transaction { $0.animation = nil }
                  .contentTransition(.identity)

              }
              .padding(.leading, 3)
              .padding(.bottom, 4)
              .onTapGesture {

                  path.append(NavigationDestination.profile(post.author.did.didString()))

              }
            }

            .frame(height: 60, alignment: .center)
            .padding(.bottom, 3)
              
              if !feedPost.text.isEmpty {
                // Reuse Post component to unify selectable text + translation
                Post(
                  post: feedPost,
                  isSelectable: true,
                  path: $path,
                  textSize: 28,
                  textStyle: .title3,
                  textDesign: .default,
                  textWeight: .regular,
                  fontWidth: 100,
                  lineSpacing: 1.2,
                  letterSpacing: 0.2,
                  useUIKitSelectableText: true
                )
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.leading, 6)
                .padding(.trailing, 6)
                .transaction { txn in txn.animation = nil }
                .contentTransition(.identity)
              }

//              if feedPost.text != "" {
//                  
//                  TappableTextView(
//                    attributedString: feedPost.facetsAsAttributedString, textSize: nil, textStyle: .title3
//                  )
//                  .lineLimit(nil)
//                  .fixedSize(horizontal: false, vertical: true)
//                  .padding(.vertical, 6)
//                  .padding(.leading, 6)
//                  .padding(.trailing, 6)
//              }
            if let embed = post.embed {
              PostEmbed(embed: embed, labels: post.labels, path: $path)
                .padding(.vertical, 6)
                .padding(.leading, 6)
                .padding(.trailing, 6)
            }

            Text(Self.dateTimeFormatter.string(from: feedPost.createdAt.date))
              .appSubheadline()
              .textScale(.secondary)
              .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
              .padding(Self.baseUnit * 3)
              .transaction { $0.animation = nil }
              .contentTransition(.identity)
          }
        }

        PostStatsView(post: post, path: $path)
          .padding(.top, Self.baseUnit * 3)
          .padding(.horizontal, 6)

        ActionButtonsView(
          post: post,
          postViewModel: viewModel,
          path: $path,
          isBig: true
        )
        .padding(.leading, 15)
        .padding(.trailing, 9)
      }
    }
  }
}

/// Truncates the string to a specified maximum length, appending a trailing indicator if needed.
extension String {
    func truncated(to length: Int, trailing: String = "...") -> String {
        // If the string exceeds the max length, return a substring with trailing text
        if self.count > length {
            return self.prefix(length) + trailing
        } else {
            return self
        }
    }
}
