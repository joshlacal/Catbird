//
//  CatbirdNotificationWidgetBundle.swift
//  CatbirdNotificationWidget
//
//  Created by Josh LaCalamito on 4/30/25.
//

import SwiftUI
import WidgetKit

@main
struct CatbirdNotificationWidgetBundle: WidgetBundle {
  var body: some Widget {
    SimpleTestWidget()
    CatbirdNotificationWidget()
  }
}
