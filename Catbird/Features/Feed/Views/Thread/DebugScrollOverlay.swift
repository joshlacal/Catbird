import SwiftUI

/// Overlay view for visualizing scroll events and content shifts
struct DebugScrollOverlay: View {
    // Values tracked by parent view
    let scrollOffset: CGPoint
    let contentHeight: CGFloat
    let isLoadingMore: Bool
    let visibleParents: Int
    let totalParents: Int
    let lastVisibleParentID: String?
    let parentYOffsets: [String: CGFloat]
    let scrollEvents: [ScrollEvent]
    
    // Local state
    @State private var expanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.toggle() }) {
                HStack {
                    Text("Scroll Debug")
                        .font(.caption)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)
            
            if expanded {
                Group {
                    // Basic metrics
                    Text("Scroll Y: \(String(format: "%.1f", scrollOffset.y))")
                    Text("Content: \(String(format: "%.1f", contentHeight))px")
                    Text("Parents: \(visibleParents)/\(totalParents) visible")
                    
                    // Loading status with indicator
                    HStack {
                        Text("Loading more:")
                        if isLoadingMore {
                            Text("YES")
                                .foregroundColor(.green)
                                .fontWeight(.bold)
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Text("no")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Last visible parent & position
                    if let lastID = lastVisibleParentID, let yOffset = parentYOffsets[lastID] {
                        Text("Last visible: \(lastID.suffix(8)) @ \(String(format: "%.1f", yOffset))px")
                            .lineLimit(1)
                    }
                    
                    // Recent scroll events
                    Text("Recent events:")
                        .fontWeight(.bold)
                        .padding(.top, 2)
                    
                    ScrollView(.vertical, showsIndicators: false) {
                        ForEach(scrollEvents.suffix(6)) { event in
                            HStack(alignment: .top) {
                                Image(systemName: event.iconName)
                                    .foregroundColor(event.color)
                                    .font(.caption2)
                                
                                VStack(alignment: .leading) {
                                    Text(event.title)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                    Text(event.description)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .foregroundColor(event.color)
                                
                                Spacer()
                                
                                Text(event.timeString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(height: 120)
                }
                .font(.caption)
                .foregroundColor(.primary)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.07))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }
}

/// Represents a scrolling or loading event for debugging
struct ScrollEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let title: String
    let description: String
    let type: EventType
    
    enum EventType {
        case scroll
        case load
        case contentShift
        case error
        case success
    }
    
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
    
    var iconName: String {
        switch type {
        case .scroll:
            return "arrow.up.and.down"
        case .load:
            return "arrow.triangle.2.circlepath"
        case .contentShift:
            return "arrow.up.and.down.text.horizontal"
        case .error:
            return "exclamationmark.triangle"
        case .success:
            return "checkmark.circle"
        }
    }
    
    var color: Color {
        switch type {
        case .scroll:
            return .blue
        case .load:
            return .orange
        case .contentShift:
            return .purple
        case .error:
            return .red
        case .success:
            return .green
        }
    }
}

#Preview {
    let mockOffsets: [String: CGFloat] = ["parent1": 120.0, "parent2": 250.0, "parent3": 380.0]
    
    let mockEvents = [
        ScrollEvent(timestamp: Date().addingTimeInterval(-10), 
                    title: "Scrolled to parent",
                    description: "parent2 is now visible",
                    type: .scroll),
        ScrollEvent(timestamp: Date().addingTimeInterval(-8), 
                    title: "Loading more",
                    description: "Triggered by parent1 at 120px", 
                    type: .load),
        ScrollEvent(timestamp: Date().addingTimeInterval(-5), 
                    title: "Content shifted",
                    description: "parent2 shifted from 250px to 380px (+130px)", 
                    type: .contentShift),
        ScrollEvent(timestamp: Date().addingTimeInterval(-2), 
                    title: "Added 5 parents",
                    description: "New parents: ...", 
                    type: .success),
    ]
    
    DebugScrollOverlay(
        scrollOffset: CGPoint(x: 0, y: 320),
        contentHeight: 1200,
        isLoadingMore: true,
        visibleParents: 2,
        totalParents: 8,
        lastVisibleParentID: "parent2",
        parentYOffsets: mockOffsets,
        scrollEvents: mockEvents
    )
}
