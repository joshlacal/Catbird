//
//  AppIntent.swift
//  CatbirdFeedWidget
//
//  Created by Josh LaCalamito on 6/7/25.
//

import WidgetKit
import AppIntents

// Feed selection options for the widget
enum FeedTypeOption: String, AppEnum {
  case timeline
  case discover
  case popular
  case custom
  
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Feed Type"
  static var caseDisplayRepresentations: [FeedTypeOption: DisplayRepresentation] = [
    .timeline: "Timeline",
    .discover: "Discover", 
    .popular: "What's Hot",
    .custom: "Custom Feed"
  ]
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Feed Settings" }
    static var description: IntentDescription { "Choose which Bluesky feed to display in the widget." }

    @Parameter(title: "Feed Type", default: .timeline)
    var feedType: FeedTypeOption
    
    @Parameter(title: "Number of Posts", default: 3)
    var postCount: Int
    
    @Parameter(title: "Show Images", default: true)
    var showImages: Bool
}
