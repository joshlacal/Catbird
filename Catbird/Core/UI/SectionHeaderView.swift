import SwiftUI

struct SectionHeaderView: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(Font.customSystemFont(size: 21,
                                           weight: .bold,
                                           width: 120,
                                           opticalSize: true,
                                           design: .default,
                                           relativeTo: .title3))
                .foregroundColor(.primary)
            Spacer()
            if title == "Pinned" || title == String(localized: "Pinned", comment: "Section header title for pinned feeds.") {
                Image(systemName: "pin.fill")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            } else if title == "Saved" || title == String(localized: "Saved", comment: "Section header title for saved feeds.") {
                Image(systemName: "bookmark.fill")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

#Preview("SectionHeaderView") {
  List {
    SectionHeaderView(title: "Recent Posts")
    SectionHeaderView(title: "Trending")
  }
}
