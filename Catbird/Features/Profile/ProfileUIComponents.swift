import NukeUI
import Petrel
import SwiftUI

// MARK: - Profile Tab Selector

struct ProfileTabSelector: View {
    @Binding var path: NavigationPath
    @Binding var selectedTab: ProfileTab
    var onTabChange: ((ProfileTab) -> Void)? = nil
    @State private var isShowingMoreOptions = false

    // Define the picker sections
    private let sections: [ProfileTab] = [.posts, .replies, .media, .more]
    // Tabs to show in the More menu
    private let moreTabs = [ProfileTab.likes, ProfileTab.lists, ProfileTab.starterPacks]

    var body: some View {
        VStack(spacing: 0) {
            // Main tab selector
            Picker("", selection: $selectedTab) {
                ForEach(sections, id: \.self) { section in
                    if section == .more {
                        Text("More")
                            .tag(ProfileTab.more)
                    } else {
                        Text(section.title).tag(section)
                    }
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .onChange(of: selectedTab) { _, newValue in
                if newValue != .more {
                    // If selecting a main tab, hide more options and trigger callback
                    isShowingMoreOptions = false
                    onTabChange?(newValue)
                } else {
                    // If selecting "More", show the options
                    isShowingMoreOptions = true
                }
            }

            // More options list (shown when More is selected)
            if isShowingMoreOptions {
                moreOptionsList
            }
        }
        .frame(width: UIScreen.main.bounds.width)
    }

    private var moreOptionsList: some View {
        VStack(spacing: 0) {
            ForEach(moreTabs, id: \.self) { tab in
                Button {
                    // Pre-load the data before navigating
                    // This is critical to prevent freezing
                    Task {
                        // Pre-load data for the section (optional)
                        switch tab {
                        case .likes:
                            await onTabChange?(tab)
                        case .lists:
                            await onTabChange?(tab)
                        case .starterPacks:
                            await onTabChange?(tab)
                        default:
                            break
                        }
                        
                        // Delay navigation slightly to allow data loading to start
                        try? await Task.sleep(for: .milliseconds(100))
                        
                        // Then navigate - on the main thread
                        await MainActor.run {
                            path.append(ProfileNavigationDestination.section(tab))
                        }
                    }
                } label: {
                    HStack {
                        Text(tab.title)
                            .font(.headline)
                            .padding(.vertical, 30)
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if tab != moreTabs.last {
                    Divider()
                        .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - List Row

struct ListRow: View {
  let list: AppBskyGraphDefs.ListView

  var body: some View {
    HStack(spacing: 12) {
      // List avatar
      LazyImage(url: URL(string: list.avatar?.uriString() ?? "")) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.2))
            .overlay(
              Image(systemName: "list.bullet")
                .foregroundColor(.accentColor)
            )
        }
      }
      .frame(width: 50, height: 50)
      .clipShape(RoundedRectangle(cornerRadius: 6))

      // List details
      VStack(alignment: .leading, spacing: 4) {
        Text(list.name)
          .font(.headline)

        if let description = list.description, !description.isEmpty {
          Text(description)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(2)
        }

        // Item count
        Text("\(list.listItemCount ?? 0) items")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer()
    }
    .padding()
  }
}
