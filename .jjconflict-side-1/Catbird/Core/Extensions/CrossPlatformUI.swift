//
//  CrossPlatformUI.swift
//  Catbird
//
//  Created by Claude on 8/19/25.
//

#if os(iOS)
import UIKit
import SwiftUI

// MARK: - iOS Platform Types
public typealias PlatformView = UIView
public typealias PlatformViewController = UIViewController
public typealias PlatformDevice = UIDevice
public typealias PlatformScreen = UIScreen
public typealias PlatformFont = UIFont
public typealias PlatformEdgeInsets = UIEdgeInsets
public typealias PlatformLayoutPriority = UILayoutPriority
public typealias PlatformGestureRecognizer = UIGestureRecognizer
public typealias PlatformTapGestureRecognizer = UITapGestureRecognizer
public typealias PlatformPanGestureRecognizer = UIPanGestureRecognizer
public typealias PlatformScrollView = UIScrollView
public typealias PlatformTextView = UITextView
public typealias PlatformLabel = UILabel
public typealias PlatformButton = UIButton
public typealias PlatformStackView = UIStackView
public typealias PlatformImageView = UIImageView
public typealias PlatformActivityIndicator = UIActivityIndicatorView
public typealias PlatformSlider = UISlider
public typealias PlatformSwitch = UISwitch
public typealias PlatformSegmentedControl = UISegmentedControl
public typealias PlatformTextField = UITextField
public typealias PlatformTableView = UITableView
public typealias PlatformCollectionView = UICollectionView
public typealias PlatformNavigationController = UINavigationController
public typealias PlatformTabBarController = UITabBarController
public typealias PlatformSplitViewController = UISplitViewController
public typealias PlatformPopoverPresentationController = UIPopoverPresentationController

// MARK: - iOS Control States
public typealias PlatformControlState = UIControl.State
public typealias PlatformControlEvents = UIControl.Event

#elseif os(macOS)
import AppKit
import SwiftUI

// MARK: - macOS Platform Types
public typealias PlatformView = NSView
public typealias PlatformViewController = NSViewController
public typealias PlatformDevice = Host // Closest equivalent
public typealias PlatformScreen = NSScreen
public typealias PlatformFont = NSFont
public typealias PlatformEdgeInsets = NSEdgeInsets
public typealias PlatformLayoutPriority = NSLayoutConstraint.Priority
public typealias PlatformGestureRecognizer = NSGestureRecognizer
public typealias PlatformTapGestureRecognizer = NSClickGestureRecognizer
public typealias PlatformPanGestureRecognizer = NSPanGestureRecognizer
public typealias PlatformScrollView = NSScrollView
public typealias PlatformTextView = NSTextView
public typealias PlatformLabel = NSTextField
public typealias PlatformButton = NSButton
public typealias PlatformStackView = NSStackView
public typealias PlatformImageView = NSImageView
public typealias PlatformActivityIndicator = NSProgressIndicator
public typealias PlatformSlider = NSSlider
public typealias PlatformSwitch = NSSwitch
public typealias PlatformSegmentedControl = NSSegmentedControl
public typealias PlatformTextField = NSTextField
public typealias PlatformTableView = NSTableView
public typealias PlatformCollectionView = NSCollectionView
public typealias PlatformNavigationController = NSViewController // No direct equivalent
public typealias PlatformTabBarController = NSTabViewController
public typealias PlatformSplitViewController = NSSplitViewController
public typealias PlatformPopoverPresentationController = NSPopover

// MARK: - macOS Control States
public enum PlatformControlState: Int {
    case normal = 0
    case highlighted = 1
    case disabled = 2
    case selected = 4
    case focused = 8
    case application = 16
    case reserved = 32
}

public enum PlatformControlEvents: Int {
    case touchDown = 1
    case touchDownRepeat = 2
    case touchDragInside = 4
    case touchDragOutside = 8
    case touchDragEnter = 16
    case touchDragExit = 32
    case touchUpInside = 64
    case touchUpOutside = 128
    case touchCancel = 256
    case valueChanged = 4096
    case primaryActionTriggered = 8192
    case editingDidBegin = 65536
    case editingChanged = 131072
    case editingDidEnd = 262144
    case editingDidEndOnExit = 524288
    case allTouchEvents = 4095
    case allEditingEvents = 983040
    case applicationReserved = 251658240
    case systemReserved = 4026531840
    case allEvents = 4294967295
}

#endif

import OSLog

private let crossPlatformUILogger = Logger(subsystem: "blue.catbird", category: "CrossPlatformUI")

// MARK: - Cross-Platform Hosting Controller

/// A cross-platform hosting controller that works on both iOS and macOS
public class PlatformHostingController<Content: View>: PlatformViewController {
    
    private let rootView: Content
    private var hostingController: Any
    
    public init(rootView: Content) {
        self.rootView = rootView
        
        #if os(iOS)
        self.hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        #elseif os(macOS)
        self.hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        #endif
        
        setupHostingController()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupHostingController() {
        #if os(iOS)
        guard let hostingController = self.hostingController as? UIHostingController<Content> else { return }
        
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
        
        #elseif os(macOS)
        guard let hostingController = self.hostingController as? NSHostingController<Content> else { return }
        
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        #endif
    }
    
    /// Update the root view of the hosting controller
    public func updateRootView(_ newRootView: Content) {
        #if os(iOS)
        if let hostingController = self.hostingController as? UIHostingController<Content> {
            hostingController.rootView = newRootView
        }
        #elseif os(macOS)
        if let hostingController = self.hostingController as? NSHostingController<Content> {
            hostingController.rootView = newRootView
        }
        #endif
    }
    
    /// Get the underlying hosting controller
    public var underlyingHostingController: Any {
        return hostingController
    }
}

// MARK: - Cross-Platform View Representable

/// Protocol that abstracts UIViewRepresentable and NSViewRepresentable
public protocol PlatformViewRepresentable: View {
    associatedtype PlatformViewType: PlatformView
    associatedtype Coordinator = Void
    
    func makePlatformView(context: Context) -> PlatformViewType
    func updatePlatformView(_ platformView: PlatformViewType, context: Context)
    
    static func dismantlePlatformView(_ platformView: PlatformViewType, coordinator: Coordinator)
    func makeCoordinator() -> Coordinator
    
    typealias Context = PlatformViewRepresentableContext<Self>
}

// Default implementations
public extension PlatformViewRepresentable where Coordinator == Void {
    static func dismantlePlatformView(_ platformView: PlatformViewType, coordinator: Coordinator) {}
    func makeCoordinator() -> Coordinator { return () }
}

public extension PlatformViewRepresentable {
    static func dismantlePlatformView(_ platformView: PlatformViewType, coordinator: Coordinator) {}
}

// MARK: - Platform View Representable Context

public struct PlatformViewRepresentableContext<Representable: PlatformViewRepresentable> {
    public let coordinator: Representable.Coordinator
    public let transaction: Transaction
    public let environment: EnvironmentValues
    
    public init(coordinator: Representable.Coordinator, transaction: Transaction, environment: EnvironmentValues) {
        self.coordinator = coordinator
        self.transaction = transaction
        self.environment = environment
    }
}

// MARK: - iOS Implementation

#if os(iOS)

extension PlatformViewRepresentable {
    public var body: some View {
        PlatformViewWrapper(representable: self)
    }
}

private struct PlatformViewWrapper<Representable: PlatformViewRepresentable>: UIViewRepresentable {
    let representable: Representable
    
    func makeUIView(context: Context) -> Representable.PlatformViewType {
        let platformContext = PlatformViewRepresentableContext<Representable>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        return representable.makePlatformView(context: platformContext)
    }
    
    func updateUIView(_ uiView: Representable.PlatformViewType, context: Context) {
        let platformContext = PlatformViewRepresentableContext<Representable>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        representable.updatePlatformView(uiView, context: platformContext)
    }
    
    func makeCoordinator() -> Representable.Coordinator {
        return representable.makeCoordinator()
    }
    
    static func dismantleUIView(_ uiView: Representable.PlatformViewType, coordinator: Representable.Coordinator) {
        Representable.dismantlePlatformView(uiView, coordinator: coordinator)
    }
}

#elseif os(macOS)

extension PlatformViewRepresentable {
    public var body: some View {
        PlatformViewWrapper(representable: self)
    }
}

private struct PlatformViewWrapper<Representable: PlatformViewRepresentable>: NSViewRepresentable {
    let representable: Representable
    
    func makeNSView(context: Context) -> Representable.PlatformViewType {
        let platformContext = PlatformViewRepresentableContext<Representable>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        return representable.makePlatformView(context: platformContext)
    }
    
    func updateNSView(_ nsView: Representable.PlatformViewType, context: Context) {
        let platformContext = PlatformViewRepresentableContext<Representable>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        representable.updatePlatformView(nsView, context: platformContext)
    }
    
    func makeCoordinator() -> Representable.Coordinator {
        return representable.makeCoordinator()
    }
    
    static func dismantleNSView(_ nsView: Representable.PlatformViewType, coordinator: Representable.Coordinator) {
        Representable.dismantlePlatformView(nsView, coordinator: coordinator)
    }
}

#endif

// MARK: - Cross-Platform Utilities

public extension PlatformView {
    
    /// Cross-platform method to add subview with constraints
    func addSubviewWithConstraints(_ subview: PlatformView, insets: PlatformEdgeInsets = .platformZero) {
        addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: subview.trailingAnchor, constant: insets.right),
            bottomAnchor.constraint(equalTo: subview.bottomAnchor, constant: insets.bottom)
        ])
    }
    
    /// Cross-platform method to set background color
    func setPlatformBackgroundColor(_ color: PlatformColor) {
        #if os(iOS)
        backgroundColor = color
        #elseif os(macOS)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        #endif
    }
    
    /// Cross-platform method to set corner radius
    func setPlatformCornerRadius(_ radius: CGFloat) {
        #if os(iOS)
        layer.cornerRadius = radius
        layer.masksToBounds = true
        #elseif os(macOS)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        #endif
    }
    
    /// Cross-platform method to set border
    func setPlatformBorder(width: CGFloat, color: PlatformColor) {
        #if os(iOS)
        layer.borderWidth = width
        layer.borderColor = color.cgColor
        #elseif os(macOS)
        wantsLayer = true
        layer?.borderWidth = width
        layer?.borderColor = color.cgColor
        #endif
    }
    
    /// Cross-platform method to set shadow
    func setPlatformShadow(color: PlatformColor, opacity: Float, offset: CGSize, radius: CGFloat) {
        #if os(iOS)
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = opacity
        layer.shadowOffset = offset
        layer.shadowRadius = radius
        layer.masksToBounds = false
        #elseif os(macOS)
        wantsLayer = true
        layer?.shadowColor = color.cgColor
        layer?.shadowOpacity = opacity
        layer?.shadowOffset = offset
        layer?.shadowRadius = radius
        layer?.masksToBounds = false
        #endif
    }
}

// MARK: - Cross-Platform Edge Insets

public extension PlatformEdgeInsets {
    
    static var platformZero: PlatformEdgeInsets {
        #if os(iOS)
        return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        #elseif os(macOS)
        return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        #endif
    }
    
    init(horizontal: CGFloat, vertical: CGFloat) {
        #if os(iOS)
        self = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        #elseif os(macOS)
        self = NSEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        #endif
    }
    
    init(all: CGFloat) {
        #if os(iOS)
        self = UIEdgeInsets(top: all, left: all, bottom: all, right: all)
        #elseif os(macOS)
        self = NSEdgeInsets(top: all, left: all, bottom: all, right: all)
        #endif
    }
}

// MARK: - Cross-Platform Font Extensions

public extension PlatformFont {
    
    /// Create a system font with the specified size and weight
    static func systemFont(ofSize size: CGFloat, weight: FontWeight = .regular) -> PlatformFont {
        #if os(iOS)
        return UIFont.systemFont(ofSize: size, weight: weight.uiKitWeight)
        #elseif os(macOS)
        return NSFont.systemFont(ofSize: size, weight: weight.appKitWeight)
        #endif
    }
    
    /// Create a monospaced system font
    static func monospacedSystemFont(ofSize size: CGFloat, weight: FontWeight = .regular) -> PlatformFont {
        #if os(iOS)
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight.uiKitWeight)
        #elseif os(macOS)
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight.appKitWeight)
        #endif
    }
    
    /// Create a preferred font for text style
    static func preferredFont(forTextStyle textStyle: PlatformTextStyle) -> PlatformFont {
        #if os(iOS)
        return UIFont.preferredFont(forTextStyle: textStyle.uiKitTextStyle)
        #elseif os(macOS)
        return NSFont.preferredFont(forTextStyle: textStyle.appKitTextStyle)
        #endif
    }
}

// MARK: - Font Weight Abstraction

public enum FontWeight {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black
    
    #if os(iOS)
    var uiKitWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
    #elseif os(macOS)
    var appKitWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
    #endif
}

// MARK: - Text Style Abstraction

public enum PlatformTextStyle {
    case largeTitle
    case title1
    case title2
    case title3
    case headline
    case body
    case callout
    case subheadline
    case footnote
    case caption1
    case caption2
    
    #if os(iOS)
    var uiKitTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title1: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption1: return .caption1
        case .caption2: return .caption2
        }
    }
    #elseif os(macOS)
    var appKitTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title1: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption1: return .caption1
        case .caption2: return .caption2
        }
    }
    #endif
}


// MARK: - Cross-Platform Screen Extensions

public extension PlatformScreen {
    
    
    /// Get the bounds of the screen
    var screenBounds: CGRect {
        #if os(iOS)
        return bounds
        #elseif os(macOS)
        return frame
        #endif
    }
    
    /// Get the scale factor of the screen
    var screenScale: CGFloat {
        #if os(iOS)
        return scale
        #elseif os(macOS)
        return backingScaleFactor
        #endif
    }
}


// MARK: - Cross-Platform Gesture Recognition

public extension PlatformView {
    
    /// Add a tap gesture recognizer
    func addTapGesture(target: Any?, action: Selector) -> PlatformTapGestureRecognizer {
        #if os(iOS)
        let tapGesture = UITapGestureRecognizer(target: target, action: action)
        addGestureRecognizer(tapGesture)
        return tapGesture
        #elseif os(macOS)
        let tapGesture = NSClickGestureRecognizer(target: target, action: action)
        addGestureRecognizer(tapGesture)
        return tapGesture
        #endif
    }
    
    /// Add a pan gesture recognizer
    func addPanGesture(target: Any?, action: Selector) -> PlatformPanGestureRecognizer {
        let panGesture = PlatformPanGestureRecognizer(target: target, action: action)
        addGestureRecognizer(panGesture)
        return panGesture
    }
}

// MARK: - Cross-Platform View Controller Extensions

public extension PlatformViewController {
    
    /// Present a view controller
    func presentPlatformViewController(_ viewController: PlatformViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        #if os(iOS)
        present(viewController, animated: animated, completion: completion)
        #elseif os(macOS)
        presentAsSheet(viewController)
        completion?()
        #endif
    }
    
    /// Dismiss the view controller
    func dismissPlatformViewController(animated: Bool = true, completion: (() -> Void)? = nil) {
        #if os(iOS)
        dismiss(animated: animated, completion: completion)
        #elseif os(macOS)
        dismiss(nil)
        completion?()
        #endif
    }
}
