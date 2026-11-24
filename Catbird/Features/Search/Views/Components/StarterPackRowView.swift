import SwiftUI
import Petrel

/// Row view for displaying a starter pack in search results
struct StarterPackRowView: View {
    let pack: AppBskyGraphDefs.StarterPackViewBasic
    
    var body: some View {
        HStack(spacing: 12) {
            // Pack creator avatar, honoring moderation labels
            AsyncProfileImage(
                url: URL(string: pack.creator.avatar?.uriString() ?? ""),
                size: 44,
                did: pack.creator.did.didString(),
                labels: pack.creator.labels
            )
            
            // Pack info
            VStack(alignment: .leading, spacing: 4) {
                // Try to get displayName from record if possible
                
                if case .knownType(let obj) = pack.record, let starterPack = obj as? AppBskyGraphStarterpack {
                    Text(starterPack.name)
                        .appFont(AppTextRole.headline)
                        .lineLimit(1)
                } else {
                    Text("Starter Pack", comment: "Fallback title for a starter pack row in search results")
                        .appFont(AppTextRole.headline)
                        .lineLimit(1)

                }
                
                Text(
                    "By @\(pack.creator.handle.description)",
                    comment: "Starter pack creator attribution in search results — variable is the creator's handle"
                )
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                
                if 
                   case .knownType(let obj) = pack.record,
                   let starterPack = obj as? AppBskyGraphStarterpack,
                   let description = starterPack.description, !description.isEmpty {
                    Text(description)
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                
                // Pack stats
                if let count = pack.listItemCount {
                    HStack(spacing: 12) {
                        Label {
                            Text(
                                "\(count) profiles",
                                comment: "Number of member profiles in a starter pack"
                            )
                        } icon: {
                            Image(systemName: "person.2")
                        }
                        .appFont(AppTextRole.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.forward")
                .appFont(AppTextRole.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
    }
}
