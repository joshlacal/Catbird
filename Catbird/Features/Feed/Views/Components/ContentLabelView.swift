//
//  ContentLabelView.swift
//  Catbird
//
//  Created by Claude on 5/12/25.
//

import SwiftUI
import Petrel
import Observation

/// Visibility settings for different content categories
enum ContentVisibility: String, Codable, Identifiable, CaseIterable {
    case show = "Show"
    case warn = "Warn"
    case hide = "Hide"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .show: return "eye"
        case .warn: return "eye.trianglebadge.exclamationmark"
        case .hide: return "eye.slash"
        }
    }
    
    var color: Color {
        switch self {
        case .show: return .green
        case .warn: return .orange
        case .hide: return .red
        }
    }
}

/// A compact visual indicator for content labels
struct ContentLabelBadge: View {
    let label: ComAtprotoLabelDefs.Label
    let backgroundColor: Color
    
    init(label: ComAtprotoLabelDefs.Label) {
        self.label = label
        
        // Determine background color based on label type
        switch label.val.lowercased() {
        case "nsfw", "porn", "nudity", "sexual":
            backgroundColor = .red.opacity(0.7)
        case "spam", "scam", "impersonation", "misleading":
            backgroundColor = .orange.opacity(0.7)
        case "gore", "violence", "corpse", "self-harm":
            backgroundColor = .purple.opacity(0.7)
        case "hate", "hate-symbol", "terrorism":
            backgroundColor = .red.opacity(0.7)
        default:
            backgroundColor = .gray.opacity(0.5)
        }
    }
    
    var body: some View {
        Text(label.val)
            .appFont(AppTextRole.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
    }
}

/// A view that displays content labels with appropriate styling and interaction
struct ContentLabelView: View {
    let labels: [ComAtprotoLabelDefs.Label]?
    @State private var isExpanded: Bool = false
    
    var body: some View {
        if let labels = labels, !labels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    
                    Text("Content Warning")
                        .appFont(AppTextRole.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                if isExpanded {
                    HStack(spacing: 4) {
                        ForEach(labels, id: \.val) { label in
                            ContentLabelBadge(label: label)
                        }
                    }
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground).opacity(0.5))
            .cornerRadius(8)
            .padding(.horizontal, 6)
        }
    }
}

/// A view that handles display decisions for labeled content
struct ContentLabelManager: View {
    let labels: [ComAtprotoLabelDefs.Label]?
    let contentType: String
    @State private var isBlurred: Bool
    @Environment(AppState.self) private var appState
    let content: () -> AnyView
    
    init(labels: [ComAtprotoLabelDefs.Label]?, contentType: String = "content", @ViewBuilder content: @escaping () -> some View) {
        self.labels = labels
        self.contentType = contentType
        self._isBlurred = State(initialValue: ContentLabelManager.shouldInitiallyBlur(labels: labels))
        self.content = { AnyView(content()) }
    }
    
    static func shouldInitiallyBlur(labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        // Default implementation - should be replaced with app preference-based logic
        guard let labels = labels, !labels.isEmpty else { return false }
        
        return labels.contains { label in
            let lowercasedValue = label.val.lowercased()
            return ["nsfw", "porn", "nudity", "sexual", "gore", "violence"].contains(lowercasedValue)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Show labels if there are any
            if let labels = labels, !labels.isEmpty {
                ContentLabelView(labels: labels)
                    .padding(.bottom, 6)
            }
            
            // Content with conditional blur
            if isBlurred {
                ZStack {
                    content()
                        .blur(radius: 30)
                    
                    // Warning overlay with reveal button
                    VStack {
                        Text("Sensitive \(contentType.capitalized)")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.bottom, 4)
                        
                        Text("This content may not be appropriate for all audiences")
                            .appFont(AppTextRole.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.bottom, 12)
                        
                        Button {
                            withAnimation {
                                isBlurred = false
                            }
                        } label: {
                            Text("Show Content")
                                .appFont(AppTextRole.footnote)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.gray.opacity(0.5))
                                .cornerRadius(18)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.7))
                    )
                    .padding(20)
                }
                .onTapGesture {
                    // Double tap anywhere to reveal
                    withAnimation {
                        isBlurred = false
                    }
                }
            } else {
                content()
                    .overlay(alignment: .topTrailing) {
                        if labels != nil && !labels!.isEmpty {
                            // Reblur button
                            Button {
                                withAnimation {
                                    isBlurred = true
                                }
                            } label: {
                                Image(systemName: "eye.slash")
                                    .appFont(AppTextRole.caption)
                                    .padding(6)
                                    .background(Circle().fill(Color.black.opacity(0.6)))
                                    .foregroundStyle(.white)
                            }
                            .padding(12)
                        }
                    }
            }
        }
    }
}
