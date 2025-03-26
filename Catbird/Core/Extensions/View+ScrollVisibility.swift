////
////  View+ScrollVisibility.swift
////  Catbird
////
////  Created by Josh LaCalamito on 2/26/25.
////
//
//import SwiftUI
//
//extension View {
//    /// View modifier that detects when a view becomes visible or hidden while scrolling
//    /// - Parameters:
//    ///   - threshold: The visibility threshold (0-1) that triggers the callback
//    ///   - action: Closure called when visibility changes, passing in the new visibility state
//    /// - Returns: Modified view that reports visibility changes
//    func onScrollVisibilityChange(threshold: CGFloat = 0.5, action: @escaping (Bool) -> Void) -> some View {
//        self.modifier(ScrollVisibilityModifier(threshold: threshold, onVisibilityChange: action))
//    }
//}
//
///// Internal modifier that tracks view visibility during scrolling
//private struct ScrollVisibilityModifier: ViewModifier {
//    let threshold: CGFloat
//    let onVisibilityChange: (Bool) -> Void
//    
//    // Used to track last reported visibility state to avoid duplicate calls
//    @State private var lastReportedVisibility: Bool?
//    
//    func body(content: Content) -> some View {
//        content
//            .background(
//                GeometryReader { geometry in
//                    Color.clear
//                        .preference(
//                            key: ScrollVisibilityPreferenceKey.self,
//                            value: ScrollVisibilityData(
//                                rect: geometry.frame(in: .global),
//                                id: UUID() // Unique ID for this instance
//                            )
//                        )
//                }
//            )
//            .onPreferenceChange(ScrollVisibilityPreferenceKey.self) { data in
//                DispatchQueue.main.async {
//                    let windowRect = UIScreen.main.bounds
//                    let viewRect = data.rect
//                    
//                    // Calculate visible area percentage
//                    let visibleHeight = min(viewRect.maxY, windowRect.maxY) - max(viewRect.minY, windowRect.minY)
//                    let viewHeight = viewRect.height
//                    let visiblePercentage = viewHeight > 0 ? visibleHeight / viewHeight : 0
//                    
//                    // Determine if view is visible based on threshold
//                    let isVisible = viewRect.intersects(windowRect) && visiblePercentage >= threshold
//                    
//                    // Only call the action if visibility has changed
//                    if lastReportedVisibility != isVisible {
//                        lastReportedVisibility = isVisible
//                        onVisibilityChange(isVisible)
//                    }
//                }
//            }
//    }
//}
//
///// Data structure to hold geometric information about the view
//private struct ScrollVisibilityData: Equatable {
//    let rect: CGRect
//    let id: UUID
//    
//    // Custom implementation of Equatable to compare only the rect
//    static func == (lhs: ScrollVisibilityData, rhs: ScrollVisibilityData) -> Bool {
//        return lhs.rect == rhs.rect && lhs.id == rhs.id
//    }
//}
//
///// Preference key for tracking scroll visibility
//private struct ScrollVisibilityPreferenceKey: PreferenceKey {
//    static var defaultValue: ScrollVisibilityData {
//        ScrollVisibilityData(rect: .zero, id: UUID())
//    }
//    
//    static func reduce(value: inout ScrollVisibilityData, nextValue: () -> ScrollVisibilityData) {
//        value = nextValue()
//    }
//}
