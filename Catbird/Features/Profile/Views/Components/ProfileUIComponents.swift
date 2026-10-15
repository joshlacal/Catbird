import NukeUI
import Petrel
import SwiftUI

// MARK: - Profile Tab Selector

struct ProfileTabSelector: View {
    @Binding var path: NavigationPath
    @Binding var selectedTab: ProfileTab
    var onTabChange: ((ProfileTab) -> Void)?
    let isLabeler: Bool

    // Define the picker sections based on profile type
    private var sections: [ProfileTab] {
        isLabeler ? ProfileTab.labelerTabs : ProfileTab.userTabs
    }
    
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
        .profileTabPickerStyle()
        .accessibilityIdentifier("profileTabPicker")
        .onChange(of: selectedTab) { _, newValue in
            if newValue != .more {
                onTabChange?(newValue)
            }
        }
    }
}

private extension View {
    /// The tabs picker style on iOS 27 and later; the segmented control before that,
    /// and on macOS, whose profile is unchanged.
    @ViewBuilder
    func profileTabPickerStyle() -> some View {
        #if os(iOS) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            pickerStyle(.tabs)
        } else {
            pickerStyle(.segmented)
        }
        #else
        pickerStyle(.segmented)
        #endif
    }
}

// MARK: - List Row

struct ListRow: View {
  let list: AppBskyGraphDefs.ListView

  var body: some View {
    ListSummaryRow(list: list)
  }
}

#Preview("ProfileTabSelector") {
  @Previewable @State var tab = ProfileTab.posts
  ProfileTabSelector(
    path: .constant(NavigationPath()),
    selectedTab: $tab,
    isLabeler: false
  )
}
