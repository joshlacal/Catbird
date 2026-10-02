//
//  DateManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/9/24.
//

import Foundation

/// Compact relative time ("5m", "3h", "2d", "1mo", "1y", "now").
/// Uses only `Calendar`; no formatter is allocated, so this is safe on hot paths
/// such as feed-row `body` evaluation.
func shortTimeAgoString(from date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()
    let components = calendar.dateComponents([.minute, .hour, .day, .month, .year], from: date, to: now)

    if let years = components.year, years > 0 {
        return "\(years)y"
    } else if let months = components.month, months > 0 {
        return "\(months)mo"
    } else if let days = components.day, days > 0 {
        return "\(days)d"
    } else if let hours = components.hour, hours > 0 {
        return "\(hours)h"
    } else if let minutes = components.minute, minutes > 0 {
        return "\(minutes)m"
    } else {
        return "now"
    }
}

/// Process-wide cache for the accessibility (`.full` / `.named`) relative formatter.
/// `RelativeDateTimeFormatter` is expensive to create; one instance is built lazily
/// on first use and guarded by a lock so it can be shared across isolation domains.
private enum TimeAgoFormatters {
    private static let accessibilityLock = NSLock()

    nonisolated(unsafe) private static let accessibilityFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    static func accessibilityString(for date: Date) -> String {
        accessibilityLock.withLock {
            accessibilityFormatter.localizedString(for: date, relativeTo: Date())
        }
    }
}

func formatTimeAgo(from date: Date, forAccessibility: Bool = false) -> String {
    guard !forAccessibility else {
        return TimeAgoFormatters.accessibilityString(for: date)
    }
    return shortTimeAgoString(from: date)
}
