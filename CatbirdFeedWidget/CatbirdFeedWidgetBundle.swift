//
//  CatbirdFeedWidgetBundle.swift
//  CatbirdFeedWidget
//
//  Created by Josh LaCalamito on 6/7/25.
//

#if os(iOS)
import WidgetKit
import SwiftUI

@main
struct CatbirdFeedWidgetBundle: WidgetBundle {
  var body: some Widget {
    CatbirdFeedWidget()
    if #available(iOS 17.0, *) {
      ComposeWidget()
    }
    NotificationCircularWidget()
    NotificationInlineWidget()
    FeedRectangularWidget()
  }
}
#endif
