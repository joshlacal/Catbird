//
//  CrossPlatformModifiers.swift
//  Catbird
//
//  Cross-platform SwiftUI modifier extensions for iOS and macOS compatibility
//

import SwiftUI
// **Note:** this is causing ambiguity with SwiftUI




//
//// MARK: - Cross-Platform Keyboard and Input Modifiers
//
//public extension View {
//    
//    /// Cross-platform keyboard type modifier (iOS only)
//    @ViewBuilder
//    func keyboardType(_ type: UIKeyboardType) -> some View {
//        #if os(iOS)
//        self.keyboardType(type)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform text input autocapitalization (iOS only)
//    @ViewBuilder
//    func textInputAutocapitalization(_ capitalization: TextInputAutocapitalization) -> some View {
//        #if os(iOS)
//        self.textInputAutocapitalization(capitalization)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform autocorrection disabled (iOS only)
////    @ViewBuilder
////    func autocorrectionDisabled(_ disabled: Bool = true) -> some View {
////        #if os(iOS)
////        self.autocorrectionDisabled(disabled)
////        #else
////        self // No-op on macOS
////        #endif
////    }
//    
//    /// Cross-platform submit label (iOS only)
//    @ViewBuilder
//    func submitLabel(_ label: SubmitLabel) -> some View {
//        #if os(iOS)
//        self.submitLabel(label)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//}
//
//// MARK: - Cross-Platform Navigation Modifiers
//
//public extension View {
//    
//    /// Cross-platform navigation bar title display mode (iOS only)
//    @ViewBuilder
//    func navigationBarTitleDisplayMode(_ displayMode: Any) -> some View {
//        #if os(iOS)
//        if let iosDisplayMode = displayMode as? NavigationBarItem.TitleDisplayMode {
//            self.navigationBarTitleDisplayMode(iosDisplayMode)
//        } else {
//            self
//        }
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform toolbar title display mode (iOS only)
//    @ViewBuilder
//    func toolbarTitleDisplayMode(_ displayMode: ToolbarTitleDisplayMode) -> some View {
//        #if os(iOS)
//        self.toolbarTitleDisplayMode(displayMode)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//}
//
//// MARK: - Cross-Platform Presentation Modifiers
//
//public extension View {
//    
//    /// Cross-platform presentation detents (iOS only)
////    @ViewBuilder
////    func presentationDetents(_ detents: Set<PresentationDetent>) -> some View {
////        #if os(iOS)
////        self.presentationDetents(detents)
////        #else
////        self // No-op on macOS - sheets are handled differently
////        #endif
////    }
//    
//    /// Cross-platform presentation background (iOS only)
//    @ViewBuilder
//    func presentationBackground<V: View>(@ViewBuilder content: () -> V) -> some View {
//        #if os(iOS)
//        self.presentationBackground(content: content)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform presentation background with material
//    @ViewBuilder
//    func presentationBackground(_ material: Material) -> some View {
//        #if os(iOS)
//        self.presentationBackground(material)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform presentation corner radius (iOS only)
//    @ViewBuilder
//    func presentationCornerRadius(_ radius: CGFloat?) -> some View {
//        #if os(iOS)
//        self.presentationCornerRadius(radius)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform interactive dismiss disabled (iOS only)
//    @ViewBuilder
//    func interactiveDismissDisabled(_ isDisabled: Bool = true) -> some View {
//        #if os(iOS)
//        self.interactiveDismissDisabled(isDisabled)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//}
//
// MARK: - Cross-Platform Status Bar and System UI

public extension View {
//    
//    /// Cross-platform status bar hidden (iOS only)
//    @ViewBuilder
//    func statusBar(hidden: Bool) -> some View {
//        #if os(iOS)
//        self.statusBar(hidden: hidden)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform safe area inset (iOS behavior on macOS)
//    @ViewBuilder
//    func safeAreaInset<V: View>(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View {
//        #if os(iOS)
//        self.safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
//        #else
//        // On macOS, just overlay the content at the specified edge
//        self.overlay(alignment: edge == .top ? .top : .bottom) {
//            content()
//        }
//        #endif
//    }
//    
//    /// Cross-platform ignore safe area (more controlled on macOS)
    @ViewBuilder
    func platformIgnoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View {
        #if os(iOS)
        self.ignoresSafeArea(regions, edges: edges)
        #else
        // On macOS, be more conservative with ignoring safe areas
        if regions == .container || regions == .all {
            self.ignoresSafeArea(.container, edges: edges)
        } else {
            self
        }
        #endif
    }
}
//
//// MARK: - Cross-Platform Interactive Gestures
//
//public extension View {
//    
//    /// Cross-platform swipe actions (iOS only, no-op on macOS)
//    @ViewBuilder
//    func swipeActions<T: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true, @ViewBuilder content: () -> T) -> some View {
//        #if os(iOS)
//        self.swipeActions(edge: edge, allowsFullSwipe: allowsFullSwipe, content: content)
//        #else
//        // On macOS, could implement right-click context menu as alternative
//        self.contextMenu {
//            content()
//        }
//        #endif
//    }
//}
//
//// MARK: - Cross-Platform Background and Style Modifiers
//
//public extension View {
//    
//    /// Cross-platform background style (iOS only)
//    @ViewBuilder
//    func backgroundStyle<S: ShapeStyle>(_ style: S) -> some View {
//        #if os(iOS)
//        self.backgroundStyle(style)
//        #else
//        self // No-op on macOS
//        #endif
//    }
//    
//    /// Cross-platform toolbar background (limited on macOS)
//    @ViewBuilder
//    func toolbarBackground<S: ShapeStyle>(_ style: S, for bars: ToolbarPlacement...) -> some View {
//        #if os(iOS)
//        self.toolbarBackground(style, for: bars)
//        #else
//        self // No-op on macOS - toolbar appearance is more limited
//        #endif
//    }
//}
//
//// MARK: - Cross-Platform Zoom and Scale Modifiers
//
//public extension View {
//    
//    /// Cross-platform zoom modifier (iOS only)
//    @ViewBuilder
//    func zoom(sourceID: String, in namespace: Namespace.ID) -> some View {
//        #if os(iOS)
//        if #available(iOS 18.0, *) {
//            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
//        } else {
//            self
//        }
//        #else
//        self // No-op on macOS
//        #endif
//    }
//}
//
//// MARK: - Cross-Platform Picker Styles
//
//public extension View {
//    
//    /// Cross-platform wheel picker style (iOS only)
//    @ViewBuilder
//    func wheelPickerStyle() -> some View {
//        #if os(iOS)
//        self.pickerStyle(.wheel)
//        #else
//        self.pickerStyle(.menu) // Use menu style on macOS
//        #endif
//    }
//}
//
//// MARK: - Cross-Platform Helper Extensions
//
//public extension View {
//    
//    /// Apply modifiers conditionally based on platform
//    @ViewBuilder
//    func iOS<Content: View>(@ViewBuilder content: (Self) -> Content) -> some View {
//        #if os(iOS)
//        content(self)
//        #else
//        self
//        #endif
//    }
//    
//    /// Apply modifiers conditionally for macOS
//    @ViewBuilder
//    func macOS<Content: View>(@ViewBuilder content: (Self) -> Content) -> some View {
//        #if os(macOS)
//        content(self)
//        #else
//        self
//        #endif
//    }
//    
//    /// Apply different modifiers per platform
//    @ViewBuilder
//    func crossPlatform<iOSContent: View, macOSContent: View>(
//        iOS: (Self) -> iOSContent,
//        macOS: (Self) -> macOSContent
//    ) -> some View {
//        #if os(iOS)
//        iOS(self)
//        #elseif os(macOS)
//        macOS(self)
//        #endif
//    }
//}
//
//// MARK: - Platform-Specific Keyboard Types for Cross-Platform Use
//
//#if os(macOS)
//// Define UIKeyboardType for macOS compatibility (no-op enum)
//public enum UIKeyboardType: Int {
//    case `default`
//    case asciiCapable
//    case numbersAndPunctuation
//    case URL
//    case numberPad
//    case phonePad
//    case namePhonePad
//    case emailAddress
//    case decimalPad
//    case twitter
//    case webSearch
//    case asciiCapableNumberPad
//}
//
//// Define other iOS-only types for macOS
//public enum TextInputAutocapitalization {
//    case never
//    case words
//    case sentences
//    case characters
//}
//
//public enum SubmitLabel {
//    case done
//    case go
//    case send
//    case join
//    case route
//    case search
//    case `return`
//    case next
//    case `continue`
//}
//
//// Define iOS navigation types for macOS
//public enum ToolbarTitleDisplayMode {
//    case automatic
//    case inlineLarge
//    case inline
//    case large
//}
//
//// Define NavigationBarItem for macOS compatibility
//public struct NavigationBarItem {
//    public enum TitleDisplayMode {
//        case automatic
//        case inline
//        case large
//    }
//}
//#endif
