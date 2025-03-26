//
//  StarterPackCardView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/19/25.
//


import SwiftUI
import Petrel

/// Card component for displaying a starter pack preview in feeds
struct StarterPackCardView: View {
    let starterPack: AppBskyGraphDefs.StarterPackViewBasic
    @Binding var path: NavigationPath
    
    var body: some View {
        Button {
            path.append(NavigationDestination.starterPack(starterPack.uri))
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                // Header with creator info and pack title
                HStack(spacing: 12) {
                    // Pack/Creator icon
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 44, height: 44)
                        
                        AsyncProfileImage(url: URL(string: starterPack.creator.avatar?.uriString() ?? ""), size: 44)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        // Try to get display name from record, fall back to generic name
                        if case .knownType(let recordValue) = starterPack.record,
                           let pack = recordValue as? AppBskyGraphStarterpack {
                            Text(pack.name)
                                .font(.headline)
                                .lineLimit(1)
                        } else {
                            Text("Starter Pack")
                                .font(.headline)
                        }
                        
                        Text("By @\(starterPack.creator.handle)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Stats row - dynamically show what's available
                HStack(spacing: 16) {
                    if let count = starterPack.listItemCount {
                        statView(count: count, label: "Profiles")
                    }
                    
                    if let weekCount = starterPack.joinedWeekCount {
                        statView(count: weekCount, label: "This week")
                    }
                    
                    if let allTimeCount = starterPack.joinedAllTimeCount {
                        statView(count: allTimeCount, label: "Total joins")
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 4)
                
                // Visual cue to indicate this is a collection
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color.accentColor.opacity(0.8 - Double(i) * 0.25))
                            .frame(width: 8, height: 8)
                    }
                    
                    Text("Tap to see recommended profiles and feeds")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func statView(count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
