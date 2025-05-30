import SwiftUI
import Petrel
import NukeUI

/// Row view for displaying a starter pack in search results
struct StarterPackRowView: View {
    let pack: AppBskyGraphDefs.StarterPackViewBasic
    
    var body: some View {
        HStack(spacing: 12) {
            // Pack creator avatar
            if let avatar = pack.creator.avatar {
                LazyImage(url: URL(string: avatar.uriString())) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                // Placeholder
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "person.3")
                            .foregroundColor(Color.gray)
                    )
            }
            
            // Pack info
            VStack(alignment: .leading, spacing: 4) {
                // Try to get displayName from record if possible
                
                if case .knownType(let obj) = pack.record, let starterPack = obj as? AppBskyGraphStarterpack {
                    Text(starterPack.name)
                        .font(.headline)
                        .lineLimit(1)
                } else {
                    Text("Starter Pack")
                        .font(.headline)
                        .lineLimit(1)

                }
                
                Text("By @\(pack.creator.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if 
                   case .knownType(let obj) = pack.record,
                   let starterPack = obj as? AppBskyGraphStarterpack,
                   let description = starterPack.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                
                // Pack stats
                HStack(spacing: 12) {
                    Label("\(pack.listItemCount ?? 0) profiles", systemImage: "person.2")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
    }
}
