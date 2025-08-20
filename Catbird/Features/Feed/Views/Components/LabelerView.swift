//
//  LabelerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/19/25.
//

import SwiftUI
import Petrel

struct LabelerView: View {
    let labeler: AppBskyLabelerDefs.LabelerView
    let onLikeTapped: ((Bool) -> Void)?
    @State private var isLiked: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    init(labeler: AppBskyLabelerDefs.LabelerView, onLikeTapped: ((Bool) -> Void)? = nil) {
        self.labeler = labeler
        self.onLikeTapped = onLikeTapped
        self._isLiked = State(initialValue: labeler.viewer?.like != nil)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with profile info
            HStack(spacing: 12) {
                ProfileImageView(url: labeler.creator.avatar?.url, size: 44)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(labeler.creator.displayName ?? labeler.creator.handle.description)
                        .appFont(AppTextRole.headline)
                        .fontWeight(.semibold)
                    
                    Text("@\(labeler.creator.handle)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                dateView
            }
            
            // Labels section
            if let labels = labeler.labels, !labels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Labels")
                        .appFont(AppTextRole.headline)
                        .fontWeight(.medium)
                    
                    labelsView(labels: labels)
                }
                .padding(.vertical, 4)
            }
            
            // Action bar
            HStack(spacing: 20) {
                likeButton
                
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color.systemGray6 : Color.systemBackground)
                .shadow(color: Color.systemGray4.opacity(0.2), radius: 8, x: 0, y: 2)
        )
    }
    
    private var dateView: some View {
        Text(formattedDate)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
    }
    
    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: labeler.indexedAt.date, relativeTo: Date())
    }
    
    private func labelsView(labels: [ComAtprotoLabelDefs.Label]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(labels, id: \.self) { label in
                    Text(label.val)
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(labelColor(for: label.val).opacity(0.15))
                        )
                        .foregroundStyle(labelColor(for: label.val))
                }
            }
        }
    }
    
    private var likeButton: some View {
        Button {
            isLiked.toggle()
            onLikeTapped?(isLiked)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? .red : .primary)
                
                if let likeCount = labeler.likeCount, likeCount > 0 {
                    Text("\(likeCount)")
                        .foregroundStyle(isLiked ? .red : .primary)
                }
            }
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
    
    private func labelColor(for value: String) -> Color {
        // You might want to map specific label values to colors
        switch value.lowercased() {
        case "spam": return .red
        case "misleading": return .orange
        case "sexual": return .pink
        case "nudity": return .purple
        case "legal": return .blue
        default: return .green
        }
    }
}

// Extended view for detailed labeler
struct LabelerDetailedView: View {
    let labeler: AppBskyLabelerDefs.LabelerViewDetailed
    let onLikeTapped: ((Bool) -> Void)?
    @State private var isLiked: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    init(labeler: AppBskyLabelerDefs.LabelerViewDetailed, onLikeTapped: ((Bool) -> Void)? = nil) {
        self.labeler = labeler
        self.onLikeTapped = onLikeTapped
        self._isLiked = State(initialValue: labeler.viewer?.like != nil)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with profile info
            HStack(spacing: 12) {
                ProfileImageView(url: labeler.creator.avatar?.url, size: 44)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(labeler.creator.displayName ?? labeler.creator.handle.description)
                        .appFont(AppTextRole.headline)
                        .fontWeight(.semibold)
                    
                    Text("@\(labeler.creator.handle)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                dateView
            }
            
            // Policies section
            VStack(alignment: .leading, spacing: 8) {
                Text("Policies")
                    .appFont(AppTextRole.headline)
                    .fontWeight(.medium)
                
                policiesView(policies: labeler.policies)
            }
            
            // Labels section
            if let labels = labeler.labels, !labels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Labels")
                        .appFont(AppTextRole.headline)
                        .fontWeight(.medium)
                    
                    labelsView(labels: labels)
                }
            }
            
            // Reason types and subject types
            if let reasonTypes = labeler.reasonTypes, !reasonTypes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reason Types")
                        .appFont(AppTextRole.headline)
                        .fontWeight(.medium)
                    
                    reasonTypesView(reasonTypes: reasonTypes)
                }
            }
            
            // Action bar
            HStack(spacing: 20) {
                likeButton
                
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color.systemGray6 : Color.systemBackground)
                .shadow(color: Color.systemGray4.opacity(0.2), radius: 8, x: 0, y: 2)
        )
    }
    
    private var dateView: some View {
        Text(formattedDate)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
    }
    
    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: labeler.indexedAt.date, relativeTo: Date())
    }
    
    private func policiesView(policies: AppBskyLabelerDefs.LabelerPolicies) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(policies.labelValues, id: \.self) { value in
                    Text(value.rawValue)
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        )
                        .foregroundStyle(Color.blue)
                }
            }
        }
    }
    
    private func labelsView(labels: [ComAtprotoLabelDefs.Label]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(labels, id: \.self) { label in
                    Text(label.val)
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(labelColor(for: label.val).opacity(0.15))
                        )
                        .foregroundStyle(labelColor(for: label.val))
                }
            }
        }
    }
    
    private func reasonTypesView(reasonTypes: [ComAtprotoModerationDefs.ReasonType]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(reasonTypes, id: \.self) { reason in
                    Text(String(describing: reason))
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.purple.opacity(0.15))
                        )
                        .foregroundStyle(Color.purple)
                }
            }
        }
    }
    
    private var likeButton: some View {
        Button {
            isLiked.toggle()
            onLikeTapped?(isLiked)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? .red : .primary)
                
                if let likeCount = labeler.likeCount, likeCount > 0 {
                    Text("\(likeCount)")
                        .foregroundStyle(isLiked ? .red : .primary)
                }
            }
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
    
    private func labelColor(for value: String) -> Color {
        // You might want to map specific label values to colors
        switch value.lowercased() {
        case "spam": return .red
        case "misleading": return .orange
        case "sexual": return .pink
        case "nudity": return .purple
        case "legal": return .blue
        default: return .green
        }
    }
}
