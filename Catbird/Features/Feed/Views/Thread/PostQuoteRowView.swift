//
//  PostQuoteRowView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

import Petrel
import SwiftUI
import NukeUI

struct PostQuoteRowView: View {
    let post: AppBskyFeedDefs.PostView
    @Binding var path: NavigationPath
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LazyImage(url: URL(string: post.author.avatar?.uriString() ?? "")) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author.displayName ?? post.author.handle.description)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Text("@\(post.author.handle)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text(relativeTime(from: post.indexedAt.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if case let .knownType(postObj) = post.record {
                if let feedPost = postObj as? AppBskyFeedPost {
                    Text(feedPost.text)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            path.append(NavigationDestination.post(post.uri))
        }
    }
    
    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
