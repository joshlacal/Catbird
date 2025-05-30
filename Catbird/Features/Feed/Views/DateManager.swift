//
//  DateManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/9/24.
//

import Foundation

extension RelativeDateTimeFormatter {
    func shortLocalizedString(for date: Date) -> String {
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
}

func formatTimeAgo(from date: Date, forAccessibility: Bool = false) -> String {
    if forAccessibility {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    } else {
        let formatter = RelativeDateTimeFormatter()
        return formatter.shortLocalizedString(for: date)
    }
}
