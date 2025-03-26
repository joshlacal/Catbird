import SwiftUI
import NukeUI
import Petrel

// MARK: - Profile Tab Selector

struct ProfileTabSelector: View {
  @Binding var selectedTab: ProfileTab
  var onTabChange: ((ProfileTab) -> Void)? = nil
  
  var body: some View {
    VStack(spacing: 0) {
      // Use ScrollView for horizontal scrolling with dynamic content width
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          ForEach(ProfileTab.allCases, id: \.self) { tab in
            Button(action: {
              withAnimation {
                // Only trigger if it's a new tab
                if selectedTab != tab {
                  selectedTab = tab
                  onTabChange?(tab)
                }
              }
            }) {
              VStack(spacing: 8) {
                Text(tab.title)
                  .font(.subheadline)
                  .fontWeight(selectedTab == tab ? .semibold : .regular)
                  .foregroundColor(selectedTab == tab ? .primary : .secondary)
                
                Rectangle()
                  .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                  .frame(height: 2)
              }
              .padding(.horizontal, 4)
            }
          }
        }
        .padding(.horizontal)
        .frame(width: UIScreen.main.bounds.width) // Exact width
      }
      
      Divider()
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
