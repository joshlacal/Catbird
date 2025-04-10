import NukeUI
import Petrel
import SwiftUI

// MARK: - Profile Tab Selector

struct ProfileTabSelector: View {
    @Binding var path: NavigationPath
    @Binding var selectedTab: ProfileTab
    var onTabChange: ((ProfileTab) -> Void)? = nil

    // Define the picker sections
    private let sections: [ProfileTab] = [.posts, .replies, .media, .more]
    
    var body: some View {
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
                onTabChange?(newValue)
            }
        }
        .frame(width: UIScreen.main.bounds.width)
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
