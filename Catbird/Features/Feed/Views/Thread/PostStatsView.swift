//
//  PostStatsView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

import SwiftUI
import Petrel


struct PostStatsView: View {
    let post: AppBskyFeedDefs.PostView
    @Binding var path: NavigationPath
    @State private var showingLikes: Bool = false
    @State private var showingReposts: Bool = false
    @State private var showingQuotes: Bool = false
    
    private static let baseUnit: CGFloat = 3
    
    // Check if any stats exist to display
    private var hasAnyStats: Bool {
        (post.replyCount != nil && post.replyCount! > 0) ||
        (post.repostCount != nil && post.repostCount! > 0) ||
        (post.likeCount != nil && post.likeCount! > 0) ||
        (post.quoteCount != nil && post.quoteCount! > 0)
    }
    
    var body: some View {
        // Only show view if there are stats to display
        if hasAnyStats {
            VStack(spacing: 0) {
                Divider()
                    .padding(.horizontal, Self.baseUnit * 2)
                
                HStack(spacing: 16) {
                    if let replyCount = post.replyCount, replyCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(replyCount)")
                                .fontWeight(.semibold)
                            Text("replies")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let repostCount = post.repostCount, repostCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(repostCount)")
                                .fontWeight(.semibold)
                            Text("reposts")
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingReposts = true
                        }
                    }
                    
                    if let likeCount = post.likeCount, likeCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(likeCount)")
                                .fontWeight(.semibold)
                            Text("likes")
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingLikes = true
                        }
                    }
                    
                    if let quoteCount = post.quoteCount, quoteCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(quoteCount)")
                                .fontWeight(.semibold)
                            Text("quotes")
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingQuotes = true
                        }
                    }
                }
                .padding(.top, Self.baseUnit * 2)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading) // Fix for centering issue
                .padding(.horizontal, Self.baseUnit * 2) // Add padding to align with dividers
                .padding(.vertical, Self.baseUnit * 3)
                .sheet(isPresented: $showingLikes) {
                    NavigationStack {
                        LikesView(postUri: post.uri.uriString())
                    }
                }
                .sheet(isPresented: $showingReposts) {
                    NavigationStack {
                        RepostsView(postUri: post.uri.uriString())
                    }
                }
                .sheet(isPresented: $showingQuotes) {
                    NavigationStack {
                        QuotesView(postUri: post.uri.uriString(), path: $path)
                    }
                }
                
                Divider()
                    .padding(.horizontal, Self.baseUnit * 2)
                    .padding(.vertical, Self.baseUnit * 2)
            }
        } else {
            EmptyView() // Return empty view if no stats to display
        }
    }
}
