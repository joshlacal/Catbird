//
//  AppIntent.swift
//  CatbirdFeedWidget
//
//  Created by Josh LaCalamito on 6/7/25.
//

import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Configuration" }
    static var description: IntentDescription { "Configure your Catbird feed widget." }

    @Parameter(title: "Feed Type", default: "timeline")
    var feedType: String
    
    @Parameter(title: "Post Count", default: 3)
    var postCount: Int
    
    @Parameter(title: "Show Images", default: true)
    var showImages: Bool
}
