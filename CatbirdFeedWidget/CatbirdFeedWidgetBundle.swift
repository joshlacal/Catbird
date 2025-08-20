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
    }
}
#endif
