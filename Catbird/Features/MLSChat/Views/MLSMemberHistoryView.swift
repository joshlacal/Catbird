//
//  MLSMemberHistoryView.swift
//  Catbird
//
//  Created by Claude on 2025-12-02.
//

#if os(iOS)
import SwiftUI
import CatbirdMLSCore
import OSLog


struct MLSMemberHistoryView: View {
    
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "blue.catbird",
        category: "MLSMemberHistoryView"
    )

    let conversationID: String
    let currentUserDID: String
    let database: MLSDatabase

    @Environment(\.dismiss) private var dismiss
    @State private var events: [MLSMembershipEventModel] = []
    @State private var members: [MLSMemberModel] = []
    @State private var isLoading = true
    @State private var selectedFilter: FilterOption = .all
    @State private var searchText = ""
    @State private var enrichedProfiles: [String: MLSProfileEnricher.ProfileData] = [:]

    enum FilterOption: String, CaseIterable {
        case all = "All Events"
        case activeOnly = "Active Members"
        case removedOnly = "Removed Members"
        case joinsOnly = "Joins Only"
        case exitsOnly = "Exits Only"

        var icon: String {
            switch self {
            case .all: return "list.bullet"
            case .activeOnly: return "person.fill.checkmark"
            case .removedOnly: return "person.fill.xmark"
            case .joinsOnly: return "person.badge.plus"
            case .exitsOnly: return "person.badge.minus"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search members...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding()

            // Filter picker
            Picker("Filter", selection: $selectedFilter) {
                ForEach(FilterOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Content
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEvents.isEmpty {
                emptyStateView
            } else {
                eventsList
            }
        }
        .navigationTitle("Member History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Subviews

    private var eventsList: some View {
        List {
            ForEach(groupedEvents.keys.sorted(by: >), id: \.self) { date in
                Section(header: Text(dateHeaderText(date))) {
                    if let eventsForDate = groupedEvents[date] {
                        ForEach(eventsForDate, id: \.id) { event in
                            MembershipEventRow(
                                event: event,
                                profile: enrichedProfiles[event.memberDID]
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedFilter.icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Events Found")
                .font(.headline)

            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "No events match '\(searchText)'"
        }
        switch selectedFilter {
        case .all:
            return "No membership events recorded yet"
        case .activeOnly:
            return "No active members found"
        case .removedOnly:
            return "No removed members found"
        case .joinsOnly:
            return "No join events recorded"
        case .exitsOnly:
            return "No exit events recorded"
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let storage = MLSStorage.shared

            // Fetch events and members in parallel
            async let eventsTask = storage.fetchMembershipHistory(
                conversationID: conversationID,
                currentUserDID: currentUserDID,
                database: database
            )
            async let membersTask = storage.fetchAllMembers(
                conversationID: conversationID,
                currentUserDID: currentUserDID,
                includeRemoved: true,
                database: database
            )

            let (fetchedEvents, fetchedMembers) = try await (eventsTask, membersTask)

            events = fetchedEvents
            members = fetchedMembers

            logger.info("Loaded \(events.count) events and \(members.count) members")

        } catch {
            logger.error("Failed to load member history: \(error.localizedDescription)")
        }
    }

    // MARK: - Filtering

    private var filteredEvents: [MLSMembershipEventModel] {
        var filtered = events

        // Apply filter
        switch selectedFilter {
        case .all:
            break
        case .activeOnly:
            let activeDIDs = Set(members.filter { $0.isActive }.map { $0.did })
            filtered = filtered.filter { activeDIDs.contains($0.memberDID) }
        case .removedOnly:
            let removedDIDs = Set(members.filter { !$0.isActive }.map { $0.did })
            filtered = filtered.filter { removedDIDs.contains($0.memberDID) }
        case .joinsOnly:
            filtered = filtered.filter {
                $0.eventType == .joined || $0.eventType == .deviceAdded
            }
        case .exitsOnly:
            filtered = filtered.filter {
                $0.eventType == .removed || $0.eventType == .left || $0.eventType == .kicked
            }
        }

        // Apply search
        if !searchText.isEmpty {
            let searchLower = searchText.lowercased()
            filtered = filtered.filter { event in
                if let profile = enrichedProfiles[event.memberDID] {
                    return profile.displayName?.lowercased().contains(searchLower) == true ||
                           profile.handle.lowercased().contains(searchLower)
                }
                return event.memberDID.lowercased().contains(searchLower)
            }
        }

        return filtered
    }

    private var groupedEvents: [Date: [MLSMembershipEventModel]] {
        Dictionary(grouping: filteredEvents) { event in
            Calendar.current.startOfDay(for: event.timestamp)
        }
    }

    // MARK: - Helpers

    private func dateHeaderText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }
}

// MARK: - MembershipEventRow

private struct MembershipEventRow: View {
    let event: MLSMembershipEventModel
    let profile: MLSProfileEnricher.ProfileData?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Event icon
            Image(systemName: eventIcon)
                .font(.system(size: 20))
                .foregroundColor(eventColor)
                .frame(width: 32, height: 32)
                .background(eventColor.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                // Member info
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))

                    if let handle = profile?.handle {
                        Text("@\(handle)")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }

                // Event description
                Text(eventDescription)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)

                // Metadata
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(timeAgo)
                            .font(.system(size: 12))
                    }

                    Text("•")
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .font(.system(size: 11))
                        Text("Epoch \(event.epoch)")
                            .font(.system(size: 12))
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Event Properties

    private var eventIcon: String {
        switch event.eventType {
        case .joined:
            return "person.badge.plus"
        case .deviceAdded:
            return "iphone.badge.plus"
        case .removed:
            return "person.badge.minus"
        case .left:
            return "rectangle.portrait.and.arrow.right"
        case .kicked:
            return "person.fill.xmark"
        case .roleChanged:
            return "person.badge.shield.checkmark"
        }
    }

    private var eventColor: Color {
        switch event.eventType {
        case .joined, .deviceAdded:
            return .green
        case .removed, .left, .kicked:
            return .red
        case .roleChanged:
            return .blue
        }
    }

    private var eventDescription: String {
        switch event.eventType {
        case .joined:
            if let actor = event.actorDID, actor != event.memberDID {
                return "Added to the group"
            }
            return "Joined the group"
        case .deviceAdded:
            return "Added a new device"
        case .removed:
            if let actor = event.actorDID, actor != event.memberDID {
                return "Removed from the group"
            }
            return "Left the group"
        case .left:
            return "Left the group"
        case .kicked:
            return "Kicked from the group"
        case .roleChanged:
            return "Role changed"
        }
    }

    private var displayName: String {
        profile?.displayName ?? event.memberDID.split(separator: ":").last.map(String.init) ?? "Unknown"
    }

    private var timeAgo: String {
        let interval = Date().timeIntervalSince(event.timestamp)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

#Preview {
    // Preview requires mock database - use empty view for preview
    Text("MLSMemberHistoryView Preview")
}

#endif
