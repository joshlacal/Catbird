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
            if title == "Pinned" {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if title == "Saved" {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}
