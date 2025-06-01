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
    
    // Only display if any stat is available
    private var hasAnyStats: Bool {
        (post.replyCount != nil && post.replyCount! > 0) ||
        (post.repostCount != nil && post.repostCount! > 0) ||
        (post.likeCount != nil && post.likeCount! > 0) ||
        (post.quoteCount != nil && post.quoteCount! > 0)
    }
    
    var body: some View {
        if hasAnyStats {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .padding(.horizontal, Self.baseUnit * 2)
                
                FlowLayout(
                    horizontalSpacing: Self.baseUnit * 4,
                    verticalSpacing: Self.baseUnit * 4
                ) {
                    // Replies stat
                    if let replyCount = post.replyCount, replyCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(replyCount)")
                                .fontWeight(.semibold)
                            Text("replies")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Reposts stat with tap gesture
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
                    
                    // Likes stat with tap gesture
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
                    
                    // Quotes stat with tap gesture
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
                .padding(.horizontal, Self.baseUnit * 2)
                .padding(.vertical, Self.baseUnit * 3)
                .appFont(AppTextRole.headline)
                
                // Keep existing sheet modifiers
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
            // No stats available – render nothing
            EmptyView()
        }
    }
}

/// A layout that arranges views in a horizontal flow, wrapping to the next line when needed
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    var alignment: FlowAlignment = .leading
    
    enum FlowAlignment {
        case leading, center, trailing
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return calculateSize(sizes: sizes, proposal: proposal)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        
        var lineSubviews: [(subview: LayoutSubview, size: CGSize)] = []
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var y = bounds.minY
        
        // Function to place a line of subviews with proper alignment
        func placeLine() {
            guard !lineSubviews.isEmpty else { return }
            
            // Calculate x position based on alignment
            var x = bounds.minX
            let totalWidth = lineWidth - horizontalSpacing  // Remove trailing space
            
            if alignment == .center {
                x = bounds.minX + (bounds.width - totalWidth) / 2
            } else if alignment == .trailing {
                x = bounds.minX + (bounds.width - totalWidth)
            }
            
            // Place each subview in the line
            for (subview, size) in lineSubviews {
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: .unspecified
                )
                x += size.width + horizontalSpacing
            }
            
            // Move to next line
            y += lineHeight + verticalSpacing
            
            // Reset line tracking
            lineSubviews.removeAll()
            lineWidth = 0
            lineHeight = 0
        }
        
        // Process all subviews
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            
            // If adding this view would exceed the line width, place the current line and start a new one
            let wouldExceedWidth = lineWidth + size.width > bounds.width
            let notFirstInLine = !lineSubviews.isEmpty
            
            if wouldExceedWidth && notFirstInLine {
                placeLine()
            }
            
            // Add the current view to the line
            lineSubviews.append((subview, size))
            lineWidth += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
        
        // Place the final line
        placeLine()
    }
    
    private func calculateSize(sizes: [CGSize], proposal: ProposedViewSize) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        
        // Calculate required size
        for size in sizes {
            // If this view doesn't fit on the current line, move to the next
            if currentX + size.width > containerWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            
            // Update position and line height
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
            maxWidth = max(maxWidth, currentX)
        }
        
        // Calculate final height including the last line
        let totalHeight = currentY + lineHeight
        
        return CGSize(width: maxWidth - horizontalSpacing, height: totalHeight)
    }
}
